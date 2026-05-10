#!/usr/bin/env bash
umask 022  # Ensure all created files/dirs are world-readable
# Capture the real invoking user now — $(whoami) changes if script is run via sudo
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_GROUP=$(id -gn "${REAL_USER}" 2>/dev/null || echo "${REAL_USER}")
# =============================================================================
# AWS Infrastructure Inventory Script  (v2 — full attrs + import blocks)
# Discovers resources across your AWS account and outputs:
#   1. CSV            → <out>/aws_inventory_<timestamp>.csv
#   2. Terraform HCL stubs (resource blocks) → <out>/terraform_stubs/
#   3. Terraform import blocks (HCL, TF ≥ 1.5) → <out>/terraform_stubs/imports.tf
# =============================================================================
# REQUIREMENTS: aws-cli v2, jq
# USAGE:
#   chmod +x aws_inventory_v2.sh
#   ./aws_inventory_v2.sh                          # default profile + configured region
#   ./aws_inventory_v2.sh --profile myprofile      # named profile
#   ./aws_inventory_v2.sh --region eu-west-1       # explicit region (repeatable)
#   ./aws_inventory_v2.sh --all-regions            # scan every enabled region
#   ./aws_inventory_v2.sh --concurrency 4          # parallel region workers (default 4)
#   ./aws_inventory_v2.sh --no-import-blocks       # skip imports.tf generation
# =============================================================================

set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
PROFILE="default"
REGIONS=()
ALL_REGIONS=false
IMPORT_BLOCKS=true
CONCURRENCY=4
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# OUT_DIR and dependent paths are set after auth so we can include account name + region
TOTAL_RESOURCES=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)          PROFILE="$2";          shift 2 ;;
    --region)           REGIONS+=("$2");       shift 2 ;;
    --all-regions)      ALL_REGIONS=true;      shift   ;;
    --concurrency)      CONCURRENCY="$2";      shift 2 ;;
    --no-import-blocks) IMPORT_BLOCKS=false;   shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Prerequisites ─────────────────────────────────────────────────────────────
for cmd in aws jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}ERROR: '$cmd' is required but not installed.${NC}"
    exit 1
  fi
done

# ── Helper: safe AWS call — never exits on error ──────────────────────────────
aws_safe() {
  aws --profile "${PROFILE}" --output json "$@" 2>/dev/null || echo "null"
}

aws_region() {
  local region="$1"; shift
  aws --profile "${PROFILE}" --output json --region "$region" "$@" 2>/dev/null || echo "null"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
log_section() { echo -e "\n${BOLD}${YELLOW}▶ $1${NC}"; }

add_csv() {
  local type="$1" id="$2" name="$3" region="$4" arn="$5" state="$6" attrs="$7"
  attrs="${attrs//\"/\'}"
  # Use a lock file to avoid interleaved writes from parallel workers
  (
    flock 9
    echo "\"${type}\",\"${id}\",\"${name}\",\"${region}\",\"${arn}\",\"${state}\",\"${attrs}\"" >> "${CSV_FILE}"
  ) 9>"${CSV_FILE}.lock"
  ((TOTAL_RESOURCES++)) || true
}

get_name_tag() {
  # $1 = JSON Tags array
  echo "$1" | jq -r '(.[] | select(.Key=="Name") | .Value) // ""' 2>/dev/null || echo ""
}

# Render a Tags JSON array as HCL tags = { ... }
render_tags_hcl() {
  local tags_json="$1"
  local out
  out=$(echo "$tags_json" | jq -r '
    if (. | length) > 0 then
      "  tags = {\n" +
      (map("    \(.Key) = \"\(.Value)\"") | join("\n")) +
      "\n  }"
    else ""
    end
  ' 2>/dev/null || true)
  echo "$out"
}

sanitise_label() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | sed 's/^[0-9]/_&/' | cut -c1-60
}

# Write resource stub to per-service .tf file
write_tf_stub() {
  local service="$1" resource="$2" id="$3" label="$4" region="$5" attrs="${6:-}"
  local tf_file="${TF_DIR}/${service}.tf"
  # Inject provider alias for regional resources so Terraform looks in the right region
  local provider_line="" NL=$'\n'
  if [[ "$region" != "global" ]]; then
    local alias; alias=$(echo "$region" | tr '-' '_')
    provider_line="  provider = aws.${alias}${NL}"  # real newline — printf %s does not interpret \n
  fi
  (
    umask 022
    flock 9
    if [[ ! -f "$tf_file" ]]; then
      cat >> "$tf_file" <<EOF
# Auto-generated Terraform stubs — Account: ${ACCOUNT_ID} — ${TIMESTAMP}

EOF
    fi
    printf 'resource "%s" "%s" {\n%s%s\n  lifecycle { prevent_destroy = true }\n}\n\n' \
      "$resource" "$label" "$provider_line" "$(printf '%b' "$attrs")" >> "$tf_file"
  ) 9>"${tf_file}.lock"
}

# Write a native HCL import block (Terraform >= 1.5)
write_import_block() {
  local resource="$1" label="$2" id="$3" region="${4:-global}"
  $IMPORT_BLOCKS || return 0
  local provider_line="" NL=$'\n'
  if [[ "$region" != "global" ]]; then
    local alias; alias=$(echo "$region" | tr '-' '_')
    provider_line="  provider = aws.${alias}${NL}"  # real newline
  fi
  (
    umask 022
    flock 9
    printf "import {\n%s  to = %s.%s\n  id = \"%s\"\n}\n\n" \
      "$provider_line" "$resource" "$label" "$id" >> "${IMPORTS_FILE}"
  ) 9>"${IMPORTS_FILE}.lock"
}

# Combined convenience: stub + import block
emit_resource() {
  # emit_resource SERVICE TF_RESOURCE ID LABEL REGION ATTRS
  write_tf_stub      "$1" "$2" "$3" "$4" "$5" "${6:-}"
  write_import_block "$2" "$4" "$3" "$5"   # pass region so import block gets correct provider alias
}

# ── Auth check ────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│   AWS Infrastructure Inventory Tool  (v2)       │${NC}"
echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────┘${NC}"
echo ""

IDENTITY=$(aws_safe sts get-caller-identity)
if [[ "$IDENTITY" == "null" ]]; then
  echo -e "${RED}ERROR: Could not authenticate. Check credentials/profile.${NC}"
  exit 1
fi

ACCOUNT_ID=$(echo "$IDENTITY" | jq -r '.Account')
CALLER_ARN=$(echo "$IDENTITY" | jq -r '.Arn')
echo -e "${GREEN}✓ Authenticated${NC}"
echo -e "  Account : ${BOLD}${ACCOUNT_ID}${NC}"
echo -e "  Identity: ${CALLER_ARN}"
echo ""

# ── Resolve regions ───────────────────────────────────────────────────────────
if $ALL_REGIONS; then
  mapfile -t REGIONS < <(aws_safe ec2 describe-regions --query 'Regions[].RegionName' \
    | jq -r '.[]' | sort)
elif [[ ${#REGIONS[@]} -eq 0 ]]; then
  DEFAULT_REGION=$(aws --profile "${PROFILE}" configure get region 2>/dev/null || echo "us-east-1")
  REGIONS=("${DEFAULT_REGION}")
fi

echo -e "Scanning ${BOLD}${#REGIONS[@]}${NC} region(s): ${REGIONS[*]}"
$IMPORT_BLOCKS && echo -e "Import blocks: ${GREEN}enabled${NC} (imports.tf)" \
               || echo -e "Import blocks: ${YELLOW}disabled${NC}"
echo ""

# ── Resolve output folder name: account_alias + region(s) + timestamp ─────────
ACCOUNT_ALIAS=$(aws --profile "${PROFILE}" iam list-account-aliases \
  --query 'AccountAliases[0]' --output text 2>/dev/null || true)
# Fall back to account ID if no alias is set
ACCOUNT_LABEL="${ACCOUNT_ALIAS:-${ACCOUNT_ID}}"
# Sanitise: lowercase, replace non-alphanumeric with hyphen
ACCOUNT_LABEL=$(echo "$ACCOUNT_LABEL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//')
# Build region suffix: single region name, or "multi-region" if scanning more than one
if [[ ${#REGIONS[@]} -eq 1 ]]; then
  REGION_LABEL="${REGIONS[0]}"
else
  REGION_LABEL="multi-region"
fi

OUT_DIR="$(pwd)/${ACCOUNT_LABEL}_${REGION_LABEL}_${TIMESTAMP}"
CSV_FILE="${OUT_DIR}/aws_network_inventory_${TIMESTAMP}.csv"
TF_DIR="${OUT_DIR}/terraform_stubs"
IMPORTS_FILE="${TF_DIR}/imports.tf"
SUMMARY_FILE="${OUT_DIR}/network_summary_${TIMESTAMP}.txt"

echo -e "  Output folder : ${CYAN}${OUT_DIR}${NC}"
echo ""

# ── Setup output ──────────────────────────────────────────────────────────────
mkdir -p "${TF_DIR}"
chmod 755 "${OUT_DIR}" "${TF_DIR}"
chown "${REAL_USER}":"${REAL_GROUP}" "${OUT_DIR}" "${TF_DIR}"
echo "ResourceType,ResourceID,Name,Region,ARN,State,AdditionalAttributes" > "${CSV_FILE}"
echo -e "  ${GREEN}✓${NC} Scanning network resources only: VPC, Subnet, IGW, NAT GW, TGW, VPN, DX, Route Tables, EC2, SGs, LBs, CGWs"

# u2500u2500 Generate single main.tf with terraform + provider blocks u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500
# Build main.tf dynamically — one provider alias per region being scanned
{
  cat <<HEADER
# Main Terraform configuration — Account: ${ACCOUNT_ID} — ${TIMESTAMP}
# This is the single entry point. All other .tf files contain only resource blocks.
#
# Usage:
#   terraform init
#   terraform plan -generate-config-out=generated.tf
#   terraform apply

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# Default provider — used for global resources (IAM, S3, Route53, CloudFront, ACM)
provider "aws" {
  profile = "${PROFILE}"
  region  = "${REGIONS[0]}"
}

HEADER

  # One aliased provider per region — regional resources reference these via provider = aws.<alias>
  for _REGION in "${REGIONS[@]}"; do
    _ALIAS=$(echo "$_REGION" | tr '-' '_')
    cat <<PROVIDERBLOCK
provider "aws" {
  alias   = "${_ALIAS}"
  profile = "${PROFILE}"
  region  = "${_REGION}"
}

PROVIDERBLOCK
  done
} > "${TF_DIR}/main.tf"
echo -e "  ${GREEN}✓${NC} main.tf written to ${TF_DIR}/main.tf (${#REGIONS[@]} region provider alias(es))"

if $IMPORT_BLOCKS; then
  cat > "${IMPORTS_FILE}" <<EOF
# Terraform import blocks — Account: ${ACCOUNT_ID} — ${TIMESTAMP}
# Requires Terraform >= 1.5
# Usage:
#   terraform init
#   terraform plan -generate-config-out=generated.tf
#   terraform apply

EOF
fi

# =============================================================================
# GLOBAL NETWORK RESOURCES (Direct Connect)
# =============================================================================

# ── Direct Connect Connections (global) ───────────────────────────────────────
log_section "Direct Connect Connections"
COUNT=0
while IFS= read -r conn; do
  [[ -z "$conn" || "$conn" == "null" ]] && continue
  id=$(echo "$conn"        | jq -r '.connectionId // ""');      [[ -z "$id" ]] && continue
  name=$(echo "$conn"      | jq -r '.connectionName // ""')
  state=$(echo "$conn"     | jq -r '.connectionState // ""')
  location=$(echo "$conn"  | jq -r '.location // ""')
  bandwidth=$(echo "$conn" | jq -r '.bandwidth // ""')
  region=$(echo "$conn"    | jq -r '.region // "global"')
  vlan=$(echo "$conn"      | jq -r '.vlan // 0')
  partner=$(echo "$conn"   | jq -r '.partnerName // ""')
  provider=$(echo "$conn"  | jq -r '.providerName // ""')
  lag_id=$(echo "$conn"    | jq -r '.lagId // ""')
  jumbo=$(echo "$conn"     | jq -r '.jumboFrameCapable // false')
  has_logical=$(echo "$conn" | jq -r '.hasLogicalRedundancy // "unknown"')
  arn="arn:aws:directconnect:${region}:${ACCOUNT_ID}:dxcon/${id}"

  tags_json=$(aws_safe directconnect describe-tags --resource-arns "$id" \
    | jq -c '.resourceTags[0].tags // []' \
    | jq -c '[.[] | {Key: .key, Value: .value}]' 2>/dev/null || echo "[]")
  tags_hcl=$(render_tags_hcl "$tags_json")

  add_csv "DX Connection" "$id" "$name" "$region" "$arn" "$state" \
    "Bandwidth=${bandwidth},Location=${location},VLAN=${vlan},Partner=${partner},LAG=${lag_id},JumboFrames=${jumbo},LogicalRedundancy=${has_logical}"

  attrs="  name      = \"${name}\"\n  bandwidth = \"${bandwidth}\"\n  location  = \"${location}\""
  [[ -n "$provider" ]]   && attrs="${attrs}\n  provider_name = \"${provider}\""
  [[ -n "$lag_id" ]]     && attrs="${attrs}\n  # lag_id   = \"${lag_id}\""
  [[ -n "$tags_hcl" ]]   && attrs="${attrs}\n${tags_hcl}"

  emit_resource "directconnect" "aws_dx_connection" "$id" \
    "$(sanitise_label "dxcon_${name}")" "$region" "$(printf '%b' "$attrs")"
  ((COUNT++)) || true
done < <(aws_safe directconnect describe-connections | jq -c '.connections[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} Direct Connect connections"

# ── Direct Connect Gateways (global) ─────────────────────────────────────────
log_section "Direct Connect Gateways"
COUNT=0
while IFS= read -r gw; do
  [[ -z "$gw" || "$gw" == "null" ]] && continue
  id=$(echo "$gw"    | jq -r '.directConnectGatewayId // ""');   [[ -z "$id" ]] && continue
  name=$(echo "$gw"  | jq -r '.directConnectGatewayName // ""')
  state=$(echo "$gw" | jq -r '.directConnectGatewayState // ""')
  asn=$(echo "$gw"   | jq -r '.amazonSideAsn // ""')
  owner=$(echo "$gw" | jq -r '.ownerAccount // ""')
  arn="arn:aws:directconnect::${ACCOUNT_ID}:dx-gateway/${id}"

  add_csv "DX Gateway" "$id" "$name" "global" "$arn" "$state" \
    "AmazonASN=${asn},OwnerAccount=${owner}"

  attrs="  name             = \"${name}\"\n  amazon_side_asn  = ${asn}"

  emit_resource "directconnect" "aws_dx_gateway" "$id" \
    "$(sanitise_label "dxgw_${name}")" "global" "$(printf '%b' "$attrs")"
  ((COUNT++)) || true
done < <(aws_safe directconnect describe-direct-connect-gateways \
  | jq -c '.directConnectGateways[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} Direct Connect gateways"

# =============================================================================
# REGIONAL NETWORK RESOURCES — scan regions in parallel (up to $CONCURRENCY workers)
# =============================================================================

scan_region() {
  local REGION="$1"
  umask 022  # Re-apply in background job — subshells and & jobs do not inherit umask reliably
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  Region: ${REGION}${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # ── VPCs ──────────────────────────────────────────────────────────────────
  log_section "VPCs [${REGION}]"
  COUNT=0
  while IFS= read -r vpc; do
    [[ -z "$vpc" || "$vpc" == "null" ]] && continue
    id=$(echo "$vpc"        | jq -r '.VpcId // ""');    [[ -z "$id" ]] && continue
    cidr=$(echo "$vpc"      | jq -r '.CidrBlock // ""')
    state=$(echo "$vpc"     | jq -r '.State // ""')
    default=$(echo "$vpc"   | jq -r '.IsDefault // false')
    tenancy=$(echo "$vpc"   | jq -r '.InstanceTenancy // "default"')
    tags=$(echo "$vpc"      | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:vpc/${id}"

    # Additional CIDRs
    extra_cidrs=$(echo "$vpc" | jq -r '[.CidrBlockAssociationSet[]?.CidrBlock] | join(",")' 2>/dev/null || true)
    tags_hcl=$(render_tags_hcl "$tags")

    add_csv "VPC" "$id" "$name" "$REGION" "$arn" "$state" \
      "CIDR=${cidr},Default=${default},Tenancy=${tenancy},ExtraCIDRs=${extra_cidrs}"

    attrs="  cidr_block           = \"${cidr}\"\n  instance_tenancy     = \"${tenancy}\"\n  enable_dns_support   = true\n  enable_dns_hostnames = true"
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpc" "aws_vpc" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-vpcs | jq -c '.Vpcs[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} VPCs"

  # ── Subnets ───────────────────────────────────────────────────────────────
  log_section "Subnets [${REGION}]"
  COUNT=0
  while IFS= read -r subnet; do
    [[ -z "$subnet" || "$subnet" == "null" ]] && continue
    id=$(echo "$subnet"           | jq -r '.SubnetId // ""');  [[ -z "$id" ]] && continue
    cidr=$(echo "$subnet"         | jq -r '.CidrBlock // ""')
    vpc=$(echo "$subnet"          | jq -r '.VpcId // ""')
    az=$(echo "$subnet"           | jq -r '.AvailabilityZone // ""')
    public=$(echo "$subnet"       | jq -r '.MapPublicIpOnLaunch // false')
    ipv6_cidr=$(echo "$subnet"    | jq -r '.Ipv6CidrBlockAssociationSet[0].Ipv6CidrBlock // ""')
    assign_ipv6=$(echo "$subnet"  | jq -r '.AssignIpv6AddressOnCreation // false')
    tags=$(echo "$subnet"         | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:subnet/${id}"
    tags_hcl=$(render_tags_hcl "$tags")

    add_csv "Subnet" "$id" "$name" "$REGION" "$arn" "available" \
      "CIDR=${cidr},VPC=${vpc},AZ=${az},PublicIP=${public},IPv6=${ipv6_cidr}"

    attrs="  vpc_id                  = \"${vpc}\"\n  cidr_block              = \"${cidr}\"\n  availability_zone       = \"${az}\"\n  map_public_ip_on_launch = ${public}"
    [[ -n "$ipv6_cidr" ]] && attrs="${attrs}\n  ipv6_cidr_block         = \"${ipv6_cidr}\"\n  assign_ipv6_address_on_creation = ${assign_ipv6}"
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpc" "aws_subnet" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-subnets | jq -c '.Subnets[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} subnets"

  # ── Security Groups ───────────────────────────────────────────────────────
  log_section "Security Groups [${REGION}]"
  COUNT=0
  while IFS= read -r sg; do
    [[ -z "$sg" || "$sg" == "null" ]] && continue
    id=$(echo "$sg"    | jq -r '.GroupId // ""');     [[ -z "$id" ]] && continue
    name=$(echo "$sg"  | jq -r '.GroupName // ""')
    vpc=$(echo "$sg"   | jq -r '.VpcId // "none"')
    desc=$(echo "$sg"  | jq -r '.Description // ""')
    tags=$(echo "$sg"  | jq -c '.Tags // []')
    tags_hcl=$(render_tags_hcl "$tags")

    # Summarise ingress/egress rule counts for CSV
    ingress_count=$(echo "$sg" | jq '.IpPermissions | length' 2>/dev/null || echo 0)
    egress_count=$(echo "$sg"  | jq '.IpPermissionsEgress | length' 2>/dev/null || echo 0)

    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:security-group/${id}"
    add_csv "Security Group" "$id" "$name" "$REGION" "$arn" "active" \
      "VPC=${vpc},IngressRules=${ingress_count},EgressRules=${egress_count},Description=${desc}"

    attrs="  name        = \"${name}\"\n  description = \"${desc}\"\n  vpc_id      = \"${vpc}\"\n\n  # NOTE: manage ingress/egress rules via aws_security_group_rule resources after import"
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpc" "aws_security_group" "$id" \
      "$(sanitise_label "sg_${name}_${id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-security-groups | jq -c '.SecurityGroups[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} security groups"

  # ── Internet Gateways ─────────────────────────────────────────────────────
  log_section "Internet Gateways [${REGION}]"
  COUNT=0
  while IFS= read -r igw; do
    [[ -z "$igw" || "$igw" == "null" ]] && continue
    id=$(echo "$igw"   | jq -r '.InternetGatewayId // ""');  [[ -z "$id" ]] && continue
    vpc=$(echo "$igw"  | jq -r '.Attachments[0].VpcId // "detached"')
    state=$(echo "$igw"| jq -r '.Attachments[0].State // "detached"')
    tags=$(echo "$igw" | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:internet-gateway/${id}"

    add_csv "Internet Gateway" "$id" "$name" "$REGION" "$arn" "$state" "VPC=${vpc}"

    attrs="  # attachment is managed via aws_internet_gateway_attachment"
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpc" "aws_internet_gateway" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-internet-gateways | jq -c '.InternetGateways[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} internet gateways"

  # ── Route Tables ──────────────────────────────────────────────────────────
  log_section "Route Tables [${REGION}]"
  COUNT=0
  while IFS= read -r rt; do
    [[ -z "$rt" || "$rt" == "null" ]] && continue
    id=$(echo "$rt"   | jq -r '.RouteTableId // ""');  [[ -z "$id" ]] && continue
    vpc=$(echo "$rt"  | jq -r '.VpcId // ""')
    main=$(echo "$rt" | jq -r '[.Associations[]? | select(.Main==true)] | length > 0' 2>/dev/null || echo false)
    route_count=$(echo "$rt" | jq '.Routes | length' 2>/dev/null || echo 0)
    assoc_count=$(echo "$rt" | jq '.Associations | length' 2>/dev/null || echo 0)
    tags=$(echo "$rt" | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:route-table/${id}"

    add_csv "Route Table" "$id" "$name" "$REGION" "$arn" "active" \
      "VPC=${vpc},Main=${main},Routes=${route_count},Associations=${assoc_count}"

    attrs="  vpc_id = \"${vpc}\"\n  # NOTE: individual routes managed via aws_route resources"
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpc" "aws_route_table" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-route-tables | jq -c '.RouteTables[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} route tables"

  # ── EC2 Instances ─────────────────────────────────────────────────────────
  log_section "EC2 Instances [${REGION}]"
  COUNT=0
  while IFS= read -r inst; do
    [[ -z "$inst" || "$inst" == "null" ]] && continue
    id=$(echo "$inst"            | jq -r '.InstanceId // ""');  [[ -z "$id" ]] && continue
    state=$(echo "$inst"         | jq -r '.State.Name // ""')
    type=$(echo "$inst"          | jq -r '.InstanceType // ""')
    ami=$(echo "$inst"           | jq -r '.ImageId // ""')
    az=$(echo "$inst"            | jq -r '.Placement.AvailabilityZone // ""')
    subnet=$(echo "$inst"        | jq -r '.SubnetId // "none"')
    vpc=$(echo "$inst"           | jq -r '.VpcId // "none"')
    key=$(echo "$inst"           | jq -r '.KeyName // ""')
    private_ip=$(echo "$inst"    | jq -r '.PrivateIpAddress // ""')
    public_ip=$(echo "$inst"     | jq -r '.PublicIpAddress // ""')
    iam_profile=$(echo "$inst"   | jq -r '.IamInstanceProfile.Arn // ""')
    ebs_opt=$(echo "$inst"       | jq -r '.EbsOptimized // false')
    monitoring=$(echo "$inst"    | jq -r '.Monitoring.State // "disabled"')
    tenancy=$(echo "$inst"       | jq -r '.Placement.Tenancy // "default"')
    user_data_b64=$(aws_region "$REGION" ec2 describe-instance-attribute \
      --instance-id "$id" --attribute userData \
      | jq -r '.UserData.Value // ""' 2>/dev/null || true)
    tags=$(echo "$inst"          | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${id}"

    sg_ids=$(echo "$inst" | jq -r '[.SecurityGroups[]?.GroupId] | join(",")' 2>/dev/null || true)

    add_csv "EC2 Instance" "$id" "$name" "$REGION" "$arn" "$state" \
      "Type=${type},AMI=${ami},AZ=${az},VPC=${vpc},Subnet=${subnet},PrivateIP=${private_ip},PublicIP=${public_ip},KeyPair=${key}"

    attrs="  ami                    = \"${ami}\"\n  instance_type          = \"${type}\"\n  subnet_id              = \"${subnet}\"\n  ebs_optimized          = ${ebs_opt}\n  monitoring             = $([ "$monitoring" == "enabled" ] && echo true || echo false)\n  tenancy                = \"${tenancy}\""
    [[ -n "$key" ]]        && attrs="${attrs}\n  key_name               = \"${key}\""
    [[ -n "$iam_profile" ]] && attrs="${attrs}\n  iam_instance_profile   = \"${iam_profile}\""
    [[ -n "$sg_ids" ]]     && attrs="${attrs}\n  vpc_security_group_ids = [\"${sg_ids//,/\",\"}\"]"
    [[ -n "$user_data_b64" ]] && attrs="${attrs}\n  # user_data_base64     = \"<redacted>\""
    [[ -n "$tags_hcl" ]]   && attrs="${attrs}\n${tags_hcl}"

    emit_resource "ec2" "aws_instance" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-instances \
    | jq -c '.Reservations[].Instances[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} EC2 instances"

  log_section "Load Balancers [${REGION}]"
  COUNT=0
  while IFS= read -r lb; do
    [[ -z "$lb" || "$lb" == "null" ]] && continue
    name=$(echo "$lb"          | jq -r '.LoadBalancerName // ""');  [[ -z "$name" ]] && continue
    arn=$(echo "$lb"           | jq -r '.LoadBalancerArn // ""')
    type=$(echo "$lb"          | jq -r '.Type // ""')
    scheme=$(echo "$lb"        | jq -r '.Scheme // ""')
    state=$(echo "$lb"         | jq -r '.State.Code // ""')
    dns=$(echo "$lb"           | jq -r '.DNSName // ""')
    ip_addr_type=$(echo "$lb"  | jq -r '.IpAddressType // "ipv4"')
    vpc=$(echo "$lb"           | jq -r '.VpcId // ""')
    subnets=$(echo "$lb"       | jq -r '[.AvailabilityZones[]?.SubnetId] | join(",")' 2>/dev/null || true)
    sg_ids=$(echo "$lb"        | jq -r '[.SecurityGroups[]?] | join(",")' 2>/dev/null || true)

    # Attributes (access logs, deletion protection, etc.)
    LB_ATTRS=$(aws_region "$REGION" elbv2 describe-load-balancer-attributes --load-balancer-arn "$arn" \
      | jq -r '.Attributes' 2>/dev/null || echo "[]")
    del_protect=$(echo "$LB_ATTRS" | jq -r '.[] | select(.Key=="deletion_protection.enabled") | .Value // "false"' 2>/dev/null || echo false)
    access_logs_bucket=$(echo "$LB_ATTRS" | jq -r '.[] | select(.Key=="access_logs.s3.bucket") | .Value // ""' 2>/dev/null || true)
    access_logs_enabled=$(echo "$LB_ATTRS" | jq -r '.[] | select(.Key=="access_logs.s3.enabled") | .Value // "false"' 2>/dev/null || echo false)

    tags_json=$(aws_region "$REGION" elbv2 describe-tags --resource-arns "$arn" \
      | jq -c '.TagDescriptions[0].Tags // []' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "Load Balancer" "$arn" "$name" "$REGION" "$arn" "$state" \
      "Type=${type},Scheme=${scheme},DNS=${dns},VPC=${vpc},DeletionProtection=${del_protect}"

    attrs="  name                       = \"${name}\"\n  internal                   = $([ "$scheme" == "internal" ] && echo true || echo false)\n  load_balancer_type         = \"${type}\"\n  ip_address_type            = \"${ip_addr_type}\"\n  enable_deletion_protection = ${del_protect}"
    [[ -n "$subnets" ]] && attrs="${attrs}\n  subnets                    = [\"${subnets//,/\",\"}\"]"
    [[ -n "$sg_ids" && "$type" == "application" ]] && attrs="${attrs}\n  security_groups            = [\"${sg_ids//,/\",\"}\"]"
    if [[ "$access_logs_enabled" == "true" && -n "$access_logs_bucket" ]]; then
      attrs="${attrs}\n\n  access_logs {\n    bucket  = \"${access_logs_bucket}\"\n    enabled = true\n  }"
    fi
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "alb" "aws_lb" "$arn" \
      "$(sanitise_label "${type}_${name}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" elbv2 describe-load-balancers | jq -c '.LoadBalancers[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} load balancers"

  # ── Lambda Functions ──────────────────────────────────────────────────────
  log_section "NAT Gateways [${REGION}]"
  COUNT=0
  while IFS= read -r nat; do
    [[ -z "$nat" || "$nat" == "null" ]] && continue
    id=$(echo "$nat"       | jq -r '.NatGatewayId // ""');      [[ -z "$id" ]] && continue
    state=$(echo "$nat"    | jq -r '.State // ""')
    subnet=$(echo "$nat"   | jq -r '.SubnetId // ""')
    vpc=$(echo "$nat"      | jq -r '.VpcId // ""')
    nat_type=$(echo "$nat" | jq -r '.ConnectivityType // "public"')
    alloc_id=$(echo "$nat" | jq -r '.NatGatewayAddresses[0].AllocationId // ""')
    public_ip=$(echo "$nat"| jq -r '.NatGatewayAddresses[0].PublicIp // ""')
    private_ip=$(echo "$nat"| jq -r '.NatGatewayAddresses[0].PrivateIp // ""')
    eni=$(echo "$nat"      | jq -r '.NatGatewayAddresses[0].NetworkInterfaceId // ""')
    created=$(echo "$nat"  | jq -r '.CreateTime // ""')
    tags=$(echo "$nat"     | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:natgateway/${id}"

    add_csv "NAT Gateway" "$id" "$name" "$REGION" "$arn" "$state" \
      "Type=${nat_type},VPC=${vpc},Subnet=${subnet},PublicIP=${public_ip},PrivateIP=${private_ip},AllocationId=${alloc_id}"

    attrs="  subnet_id         = \"${subnet}\"\n  connectivity_type = \"${nat_type}\""
    [[ "$nat_type" == "public" && -n "$alloc_id" ]] && attrs="${attrs}\n  allocation_id     = \"${alloc_id}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpc" "aws_nat_gateway" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-nat-gateways \
    | jq -c '.NatGateways[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} NAT gateways"

  # ── Transit Gateways ──────────────────────────────────────────────────────
  log_section "Transit Gateways [${REGION}]"
  COUNT=0
  while IFS= read -r tgw; do
    [[ -z "$tgw" || "$tgw" == "null" ]] && continue
    id=$(echo "$tgw"          | jq -r '.TransitGatewayId // ""');  [[ -z "$id" ]] && continue
    arn=$(echo "$tgw"         | jq -r '.TransitGatewayArn // ""')
    state=$(echo "$tgw"       | jq -r '.State // ""')
    owner=$(echo "$tgw"       | jq -r '.OwnerId // ""')
    asn=$(echo "$tgw"         | jq -r '.Options.AmazonSideAsn // ""')
    auto_accept=$(echo "$tgw" | jq -r '.Options.AutoAcceptSharedAttachments // "disable"')
    default_rtb=$(echo "$tgw" | jq -r '.Options.DefaultRouteTableAssociation // "enable"')
    default_prop=$(echo "$tgw"| jq -r '.Options.DefaultRouteTablePropagation // "enable"')
    dns_support=$(echo "$tgw" | jq -r '.Options.DnsSupport // "enable"')
    vpn_ecmp=$(echo "$tgw"    | jq -r '.Options.VpnEcmpSupport // "enable"')
    multicast=$(echo "$tgw"   | jq -r '.Options.MulticastSupport // "disable"')
    tags=$(echo "$tgw"        | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")

    add_csv "Transit Gateway" "$id" "$name" "$REGION" "$arn" "$state" \
      "ASN=${asn},AutoAccept=${auto_accept},DefaultRTBAssoc=${default_rtb},DefaultRTBProp=${default_prop},DNS=${dns_support},VPNEcmp=${vpn_ecmp}"

    attrs="  description                     = \"${name}\"\n  amazon_side_asn                 = ${asn}\n  auto_accept_shared_attachments  = \"${auto_accept}\"\n  default_route_table_association = \"${default_rtb}\"\n  default_route_table_propagation = \"${default_prop}\"\n  dns_support                     = \"${dns_support}\"\n  vpn_ecmp_support                = \"${vpn_ecmp}\"\n  multicast_support               = \"${multicast}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "tgw" "aws_ec2_transit_gateway" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-transit-gateways \
    | jq -c '.TransitGateways[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} transit gateways"

  # ── Transit Gateway Attachments ───────────────────────────────────────────
  log_section "Transit Gateway Attachments [${REGION}]"
  COUNT=0
  while IFS= read -r att; do
    [[ -z "$att" || "$att" == "null" ]] && continue
    id=$(echo "$att"          | jq -r '.TransitGatewayAttachmentId // ""');  [[ -z "$id" ]] && continue
    tgw_id=$(echo "$att"      | jq -r '.TransitGatewayId // ""')
    att_type=$(echo "$att"    | jq -r '.ResourceType // ""')
    resource_id=$(echo "$att" | jq -r '.ResourceId // ""')
    state=$(echo "$att"       | jq -r '.State // ""')
    owner=$(echo "$att"       | jq -r '.ResourceOwnerId // ""')
    assoc_rtb=$(echo "$att"   | jq -r '.Association.TransitGatewayRouteTableId // ""')
    tags=$(echo "$att"        | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:transit-gateway-attachment/${id}"

    add_csv "TGW Attachment" "$id" "$name" "$REGION" "$arn" "$state" \
      "TGW=${tgw_id},Type=${att_type},Resource=${resource_id},AssocRTB=${assoc_rtb}"

    # Resource block varies by type; emit the appropriate one
    case "$att_type" in
      vpc)
        vpc_id=$(echo "$att" | jq -r '.ResourceId // ""')
        subnets=$(aws_region "$REGION" ec2 describe-transit-gateway-vpc-attachments \
          --filters "Name=transit-gateway-attachment-id,Values=${id}" \
          | jq -r '[.TransitGatewayVpcAttachments[0].SubnetIds[]?] | join(",")' 2>/dev/null || true)
        attrs="  transit_gateway_id = \"${tgw_id}\"\n  vpc_id             = \"${vpc_id}\"\n  subnet_ids         = [\"${subnets//,/\",\"}\"]"
        [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"
        emit_resource "tgw" "aws_ec2_transit_gateway_vpc_attachment" "$id" \
          "$(sanitise_label "tgwatt_${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
        ;;
      vpn)
        attrs="  # VPN attachment — managed via aws_vpn_connection resource\n  # transit_gateway_id = \"${tgw_id}\"\n  # vpn_connection_id  = \"${resource_id}\""
        write_tf_stub "tgw" "aws_ec2_transit_gateway_vpn_attachment" "$id" \
          "$(sanitise_label "tgwatt_vpn_${id}")" "$REGION" "$(printf '%b' "$attrs")"
        write_import_block "aws_ec2_transit_gateway_vpn_attachment" \
          "$(sanitise_label "tgwatt_vpn_${id}")" "${tgw_id}_${id}"
        ;;
      direct-connect-gateway)
        attrs="  transit_gateway_id         = \"${tgw_id}\"\n  dx_gateway_id              = \"${resource_id}\""
        emit_resource "tgw" "aws_dx_gateway_association" "$id" \
          "$(sanitise_label "tgwatt_dx_${id}")" "$REGION" "$(printf '%b' "$attrs")"
        ;;
      *)
        attrs="  transit_gateway_id = \"${tgw_id}\"\n  resource_id        = \"${resource_id}\"\n  resource_type      = \"${att_type}\""
        [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"
        write_tf_stub "tgw" "# aws_ec2_transit_gateway_attachment_${att_type}" "$id" \
          "$(sanitise_label "tgwatt_${att_type}_${id}")" "$REGION" "$(printf '%b' "$attrs")"
        ;;
    esac
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-transit-gateway-attachments \
    | jq -c '.TransitGatewayAttachments[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} transit gateway attachments"

  # ── Transit Gateway Route Tables ──────────────────────────────────────────
  log_section "Transit Gateway Route Tables [${REGION}]"
  COUNT=0
  while IFS= read -r rtb; do
    [[ -z "$rtb" || "$rtb" == "null" ]] && continue
    id=$(echo "$rtb"          | jq -r '.TransitGatewayRouteTableId // ""');  [[ -z "$id" ]] && continue
    tgw_id=$(echo "$rtb"      | jq -r '.TransitGatewayId // ""')
    state=$(echo "$rtb"       | jq -r '.State // ""')
    default_assoc=$(echo "$rtb"| jq -r '.DefaultAssociationRouteTable // false')
    default_prop=$(echo "$rtb" | jq -r '.DefaultPropagationRouteTable // false')
    tags=$(echo "$rtb"        | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:transit-gateway-route-table/${id}"

    add_csv "TGW Route Table" "$id" "$name" "$REGION" "$arn" "$state" \
      "TGW=${tgw_id},DefaultAssoc=${default_assoc},DefaultProp=${default_prop}"

    attrs="  transit_gateway_id = \"${tgw_id}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "tgw" "aws_ec2_transit_gateway_route_table" "$id" \
      "$(sanitise_label "tgwrtb_${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-transit-gateway-route-tables \
    | jq -c '.TransitGatewayRouteTables[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} transit gateway route tables"

  # ── Customer Gateways ─────────────────────────────────────────────────────
  log_section "Customer Gateways [${REGION}]"
  COUNT=0
  while IFS= read -r cgw; do
    [[ -z "$cgw" || "$cgw" == "null" ]] && continue
    id=$(echo "$cgw"      | jq -r '.CustomerGatewayId // ""');  [[ -z "$id" ]] && continue
    state=$(echo "$cgw"   | jq -r '.State // ""')
    cgw_type=$(echo "$cgw"| jq -r '.Type // "ipsec.1"')
    bgp_asn=$(echo "$cgw" | jq -r '.BgpAsn // ""')
    ip_addr=$(echo "$cgw" | jq -r '.IpAddress // ""')
    cert_arn=$(echo "$cgw"| jq -r '.CertificateArn // ""')
    device=$(echo "$cgw"  | jq -r '.DeviceName // ""')
    tags=$(echo "$cgw"    | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:customer-gateway/${id}"

    add_csv "Customer Gateway" "$id" "$name" "$REGION" "$arn" "$state" \
      "Type=${cgw_type},BGP_ASN=${bgp_asn},IP=${ip_addr},Device=${device}"

    attrs="  type       = \"${cgw_type}\"\n  bgp_asn    = ${bgp_asn}\n  ip_address = \"${ip_addr}\""
    [[ -n "$cert_arn" ]] && attrs="${attrs}\n  certificate_arn = \"${cert_arn}\""
    [[ -n "$device" ]]   && attrs="${attrs}\n  device_name     = \"${device}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpn" "aws_customer_gateway" "$id" \
      "$(sanitise_label "cgw_${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-customer-gateways \
    | jq -c '.CustomerGateways[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} customer gateways"

  # ── Virtual Private Gateways ──────────────────────────────────────────────
  log_section "VPN Connections [${REGION}]"
  COUNT=0
  while IFS= read -r vpn; do
    [[ -z "$vpn" || "$vpn" == "null" ]] && continue
    id=$(echo "$vpn"          | jq -r '.VpnConnectionId // ""');  [[ -z "$id" ]] && continue
    state=$(echo "$vpn"       | jq -r '.State // ""')
    vpn_type=$(echo "$vpn"    | jq -r '.Type // "ipsec.1"')
    cgw_id=$(echo "$vpn"      | jq -r '.CustomerGatewayId // ""')
    vgw_id=$(echo "$vpn"      | jq -r '.VpnGatewayId // ""')
    tgw_id=$(echo "$vpn"      | jq -r '.TransitGatewayId // ""')
    cat_id=$(echo "$vpn"      | jq -r '.Category // "VPN"')
    static_routes=$(echo "$vpn"| jq -r '.Options.StaticRoutesOnly // false')
    local_ipv4=$(echo "$vpn"  | jq -r '.Options.LocalIpv4NetworkCidr // ""')
    remote_ipv4=$(echo "$vpn" | jq -r '.Options.RemoteIpv4NetworkCidr // ""')
    accel=$(echo "$vpn"       | jq -r '.Options.EnableAcceleration // false')
    tunnel1_ip=$(echo "$vpn"  | jq -r '.VgwTelemetry[0].OutsideIpAddress // ""')
    tunnel2_ip=$(echo "$vpn"  | jq -r '.VgwTelemetry[1].OutsideIpAddress // ""')
    tunnel1_status=$(echo "$vpn" | jq -r '.VgwTelemetry[0].Status // ""')
    tunnel2_status=$(echo "$vpn" | jq -r '.VgwTelemetry[1].Status // ""')
    tags=$(echo "$vpn"        | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:vpn-connection/${id}"

    add_csv "VPN Connection" "$id" "$name" "$REGION" "$arn" "$state" \
      "Type=${vpn_type},CGW=${cgw_id},VGW=${vgw_id},TGW=${tgw_id},StaticRoutes=${static_routes},Accel=${accel},T1=${tunnel1_ip}(${tunnel1_status}),T2=${tunnel2_ip}(${tunnel2_status})"

    attrs="  vpn_connection_id   = \"${id}\"\n  type                = \"${vpn_type}\"\n  customer_gateway_id = \"${cgw_id}\"\n  static_routes_only  = ${static_routes}\n  enable_acceleration = ${accel}"
    [[ -n "$vgw_id" ]]   && attrs="${attrs}\n  vpn_gateway_id      = \"${vgw_id}\""
    [[ -n "$tgw_id" ]]   && attrs="${attrs}\n  transit_gateway_id  = \"${tgw_id}\""
    [[ -n "$local_ipv4" ]]  && attrs="${attrs}\n  local_ipv4_network_cidr  = \"${local_ipv4}\""
    [[ -n "$remote_ipv4" ]] && attrs="${attrs}\n  remote_ipv4_network_cidr = \"${remote_ipv4}\""
    attrs="${attrs}\n  # tunnel1/tunnel2 preshared keys are sensitive — do not store in state plaintext"
    [[ -n "$tunnel1_ip" ]] && attrs="${attrs}\n  # tunnel1_address = \"${tunnel1_ip}\""
    [[ -n "$tunnel2_ip" ]] && attrs="${attrs}\n  # tunnel2_address = \"${tunnel2_ip}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpn" "aws_vpn_connection" "$id" \
      "$(sanitise_label "vpn_${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-vpn-connections \
    | jq -c '.VpnConnections[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} VPN connections"

  # ── Direct Connect Virtual Interfaces ─────────────────────────────────────
  log_section "DX Virtual Interfaces [${REGION}]"
  COUNT=0
  while IFS= read -r vif; do
    [[ -z "$vif" || "$vif" == "null" ]] && continue
    id=$(echo "$vif"         | jq -r '.virtualInterfaceId // ""');  [[ -z "$id" ]] && continue
    name=$(echo "$vif"       | jq -r '.virtualInterfaceName // ""')
    state=$(echo "$vif"      | jq -r '.virtualInterfaceState // ""')
    vif_type=$(echo "$vif"   | jq -r '.virtualInterfaceType // ""')
    conn_id=$(echo "$vif"    | jq -r '.connectionId // ""')
    vlan=$(echo "$vif"       | jq -r '.vlan // 0')
    bgp_asn=$(echo "$vif"    | jq -r '.asn // ""')
    amazon_asn=$(echo "$vif" | jq -r '.amazonSideAsn // ""')
    auth_key=$(echo "$vif"   | jq -r '.authKey // ""')
    addr_family=$(echo "$vif"| jq -r '.addressFamily // "ipv4"')
    amazon_addr=$(echo "$vif"| jq -r '.amazonAddress // ""')
    customer_addr=$(echo "$vif"| jq -r '.customerAddress // ""')
    mtu=$(echo "$vif"        | jq -r '.mtu // 1500')
    jumbo=$(echo "$vif"      | jq -r '.jumboFrameCapable // false')
    dx_gw=$(echo "$vif"      | jq -r '.directConnectGatewayId // ""')
    vgw=$(echo "$vif"        | jq -r '.virtualGatewayId // ""')
    owner=$(echo "$vif"      | jq -r '.ownerAccount // ""')
    arn="arn:aws:directconnect:${REGION}:${ACCOUNT_ID}:dxvif/${id}"

    tags_json=$(aws_safe directconnect describe-tags --resource-arns "$id" \
      | jq -c '.resourceTags[0].tags // []' \
      | jq -c '[.[] | {Key: .key, Value: .value}]' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "DX Virtual Interface" "$id" "$name" "$REGION" "$arn" "$state" \
      "Type=${vif_type},Connection=${conn_id},VLAN=${vlan},BGP_ASN=${bgp_asn},AddrFamily=${addr_family},MTU=${mtu},DXGateway=${dx_gw}"

    # Pick the correct Terraform resource type
    case "$vif_type" in
      private) tf_resource="aws_dx_private_virtual_interface" ;;
      public)  tf_resource="aws_dx_public_virtual_interface"  ;;
      transit) tf_resource="aws_dx_transit_virtual_interface" ;;
      *)       tf_resource="aws_dx_private_virtual_interface" ;;
    esac

    attrs="  connection_id    = \"${conn_id}\"\n  name             = \"${name}\"\n  vlan             = ${vlan}\n  address_family   = \"${addr_family}\"\n  bgp_asn          = ${bgp_asn}\n  mtu              = ${mtu}"
    [[ -n "$amazon_addr" ]]   && attrs="${attrs}\n  amazon_address   = \"${amazon_addr}\""
    [[ -n "$customer_addr" ]] && attrs="${attrs}\n  customer_address = \"${customer_addr}\""
    [[ -n "$auth_key" ]]      && attrs="${attrs}\n  # bgp_auth_key   = \"<redacted>\""
    [[ -n "$dx_gw" ]]         && attrs="${attrs}\n  dx_gateway_id   = \"${dx_gw}\""
    [[ -n "$vgw" ]]           && attrs="${attrs}\n  vpn_gateway_id  = \"${vgw}\""
    [[ -n "$tags_hcl" ]]      && attrs="${attrs}\n${tags_hcl}"

    emit_resource "directconnect" "$tf_resource" "$id" \
      "$(sanitise_label "dxvif_${name}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" directconnect describe-virtual-interfaces \
    | jq -c '.virtualInterfaces[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} DX virtual interfaces"
}

# ── Run scans (parallel with concurrency cap) ─────────────────────────────────
PIDS=()
for REGION in "${REGIONS[@]}"; do
  scan_region "$REGION" &
  PIDS+=($!)
  # Throttle to $CONCURRENCY parallel workers
  while [[ ${#PIDS[@]} -ge $CONCURRENCY ]]; do
    wait "${PIDS[0]}" 2>/dev/null || true
    PIDS=("${PIDS[@]:1}")
  done
done
# Wait for remaining workers
for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# =============================================================================
# SUMMARY
# =============================================================================
TF_FILE_COUNT=$(find "${TF_DIR}" -name "*.tf" ! -name "imports.tf" 2>/dev/null | wc -l | tr -d ' ')
IMPORT_BLOCK_COUNT=0
if $IMPORT_BLOCKS && [[ -f "$IMPORTS_FILE" ]]; then
  IMPORT_BLOCK_COUNT=$(grep -c '^import {' "$IMPORTS_FILE" 2>/dev/null || true)
fi

cat > "${SUMMARY_FILE}" <<SUMMARY
AWS Infrastructure Inventory Summary  (v2)
==========================================
Account ID      : ${ACCOUNT_ID}
Generated       : ${TIMESTAMP}
Profile         : ${PROFILE}
Regions         : ${REGIONS[*]}
Total Resources : ${TOTAL_RESOURCES}

Outputs
-------
CSV             : ${CSV_FILE}
TF Stubs        : ${TF_DIR}/ (${TF_FILE_COUNT} .tf files)
Import Blocks   : ${IMPORTS_FILE} (${IMPORT_BLOCK_COUNT} blocks)

Next Steps — Import-block workflow (Terraform >= 1.5)
-----------------------------------------------------
1. cd into your Terraform working directory
2. Copy ${TF_DIR}/*.tf and ${IMPORTS_FILE} into it
3. terraform init
4. terraform plan -generate-config-out=generated.tf
   (Terraform reads the import{} blocks and generates HCL for you)
5. Merge generated.tf into your module structure
6. terraform apply   → performs the import
7. terraform plan    → should show zero drift once done

Legacy workflow (any Terraform version)
----------------------------------------
Run the commented command above each resource block:
  terraform import <resource>.<label> <id>

Tips
----
- SecureString SSM / Secrets Manager values are NOT exported (security)
- Review # TODO comments in stubs before applying
- Set up remote state (S3 + DynamoDB lock) before importing at scale
- Use -parallelism=1 for large imports to avoid API throttling
SUMMARY

echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}  ✓ Inventory complete!  ${TOTAL_RESOURCES} resources found.${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  CSV             : ${CYAN}${CSV_FILE}${NC}"
echo -e "  Terraform stubs : ${CYAN}${TF_DIR}/${NC}  (${TF_FILE_COUNT} files)"
$IMPORT_BLOCKS && echo -e "  Import blocks   : ${CYAN}${IMPORTS_FILE}${NC}  (${IMPORT_BLOCK_COUNT} blocks)"
echo -e "  Summary         : ${CYAN}${SUMMARY_FILE}${NC}"
echo ""
# ── Fix output folder permissions ─────────────────────────────────────────────
# Clean up lock files left by flock — not needed after script completes
find "${OUT_DIR}" -name "*.lock" -delete 2>/dev/null || true
chmod -R 755 "${OUT_DIR}"
chown -R "${REAL_USER}":"${REAL_GROUP}" "${OUT_DIR}"
echo -e "  ${GREEN}✓${NC} Permissions fixed on ${OUT_DIR}"
