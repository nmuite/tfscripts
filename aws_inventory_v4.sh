#!/usr/bin/env bash
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
OUT_DIR="aws_inventory_${TIMESTAMP}"
CSV_FILE="${OUT_DIR}/aws_inventory_${TIMESTAMP}.csv"
TF_DIR="${OUT_DIR}/terraform_stubs"
IMPORTS_FILE="${TF_DIR}/imports.tf"
SUMMARY_FILE="${OUT_DIR}/summary_${TIMESTAMP}.txt"
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
  (
    flock 9
    if [[ ! -f "$tf_file" ]]; then
      cat >> "$tf_file" <<EOF
# Auto-generated Terraform stubs — Account: ${ACCOUNT_ID} — ${TIMESTAMP}

EOF
    fi
    printf 'resource "%s" "%s" {\n%s\n  lifecycle { prevent_destroy = true }\n}\n\n' \
      "$resource" "$label" "$attrs" >> "$tf_file"
  ) 9>"${tf_file}.lock"
}

# Write a native HCL import block (Terraform >= 1.5)
write_import_block() {
  local resource="$1" label="$2" id="$3"
  $IMPORT_BLOCKS || return 0
  (
    flock 9
    printf 'import {\n  to = %s.%s\n  id = "%s"\n}\n\n' \
      "$resource" "$label" "$id" >> "${IMPORTS_FILE}"
  ) 9>"${IMPORTS_FILE}.lock"
}

# Combined convenience: stub + import block
emit_resource() {
  # emit_resource SERVICE TF_RESOURCE ID LABEL REGION ATTRS
  write_tf_stub   "$1" "$2" "$3" "$4" "$5" "${6:-}"
  write_import_block "$2" "$4" "$3"
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

# ── Setup output ──────────────────────────────────────────────────────────────
mkdir -p "${TF_DIR}"
echo "ResourceType,ResourceID,Name,Region,ARN,State,AdditionalAttributes" > "${CSV_FILE}"

# u2500u2500 Generate single main.tf with terraform + provider blocks u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500
cat > "${TF_DIR}/main.tf" <<MAINTF
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

provider "aws" {
  profile = "${PROFILE}"
  # region is set per-resource via aws_region(); add alias blocks if needed
}
MAINTF
echo -e "  ${GREEN}✓${NC} main.tf written to ${TF_DIR}/main.tf"

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
# GLOBAL RESOURCES
# =============================================================================

# ── IAM Users ─────────────────────────────────────────────────────────────────
log_section "IAM Users"
COUNT=0
while IFS= read -r user; do
  [[ -z "$user" || "$user" == "null" ]] && continue
  id=$(echo "$user"      | jq -r '.UserName // ""');    [[ -z "$id" ]] && continue
  arn=$(echo "$user"     | jq -r '.Arn // ""')
  path=$(echo "$user"    | jq -r '.Path // "/"')
  created=$(echo "$user" | jq -r '.CreateDate // ""')

  # Fetch full detail: groups, policies, tags
  DETAIL=$(aws_safe iam get-user --user-name "$id")
  tags_json=$(echo "$DETAIL" | jq -c '.User.Tags // []')
  tags_hcl=$(render_tags_hcl "$tags_json")

  GROUPS=$(aws_safe iam list-groups-for-user --user-name "$id" \
    | jq -r '[.Groups[].GroupName] | join(",")' 2>/dev/null || true)
  POLICIES=$(aws_safe iam list-attached-user-policies --user-name "$id" \
    | jq -r '[.AttachedPolicies[].PolicyName] | join(",")' 2>/dev/null || true)

  add_csv "IAM User" "$id" "$id" "global" "$arn" "active" \
    "Created=${created},Path=${path},Groups=${GROUPS},AttachedPolicies=${POLICIES}"

  attrs="  name = \"${id}\"\n  path = \"${path}\""
  [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"
  emit_resource "iam" "aws_iam_user" "$id" "$(sanitise_label "user_${id}")" "global" \
    "$(printf '%b' "$attrs")"
  ((COUNT++)) || true
done < <(aws_safe iam list-users | jq -c '.Users[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} IAM users"

# ── IAM Roles ─────────────────────────────────────────────────────────────────
#log_section "IAM Roles"
#COUNT=0
#while IFS= read -r role; do
#  [[ -z "$role" || "$role" == "null" ]] && continue
#  id=$(echo "$role"       | jq -r '.RoleName // ""');   [[ -z "$id" ]] && continue
#  arn=$(echo "$role"      | jq -r '.Arn // ""')
#  path=$(echo "$role"     | jq -r '.Path // "/"')
#  desc=$(echo "$role"     | jq -r '.Description // ""')
#
#  DETAIL=$(aws_safe iam get-role --role-name "$id")
#  tags_json=$(echo "$DETAIL" | jq -c '.Role.Tags // []')
#  tags_hcl=$(render_tags_hcl "$tags_json")
#
#  # Inline the assume-role policy document
#  assume_policy=$(echo "$DETAIL" | jq -r '.Role.AssumeRolePolicyDocument | @json' 2>/dev/null \
#    | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" \
#    2>/dev/null || echo "")
#
#  POLICIES=$(aws_safe iam list-attached-role-policies --role-name "$id" \
#    | jq -r '[.AttachedPolicies[].PolicyName] | join(",")' 2>/dev/null || true)
#
#  add_csv "IAM Role" "$id" "$id" "global" "$arn" "active" \
#    "Path=${path},AttachedPolicies=${POLICIES}"
###  [[ -n "$desc" ]] && attrs="${attrs}\n  description = \"${desc}\""
##  [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"
#
#  emit_resource "iam" "aws_iam_role" "$id" "$(sanitise_label "role_${id}")" "global" \
#    "$(printf '%b' "$attrs")"
#  ((COUNT++)) || true
#done < <(aws_safe iam list-roles | jq -c '.Roles[]?' 2>/dev/null || true)
#echo -e "  ${GREEN}✓${NC} ${COUNT} IAM roles"
#

# ── S3 Buckets ────────────────────────────────────────────────────────────────
log_section "S3 Buckets"
COUNT=0
while IFS= read -r bucket; do
  [[ -z "$bucket" || "$bucket" == "null" ]] && continue
  name=$(echo "$bucket"    | jq -r '.Name // ""');      [[ -z "$name" ]] && continue
  created=$(echo "$bucket" | jq -r '.CreationDate // ""')

  bucket_region=$(aws_safe s3api get-bucket-location --bucket "$name" \
    | jq -r '.LocationConstraint // "us-east-1"')
  [[ "$bucket_region" == "null" || -z "$bucket_region" ]] && bucket_region="us-east-1"
  arn="arn:aws:s3:::${name}"

  # Versioning
  versioning=$(aws_safe s3api get-bucket-versioning --bucket "$name" \
    | jq -r '.Status // "Disabled"')

  # Encryption
  encryption=$(aws_safe s3api get-bucket-encryption --bucket "$name" \
    | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // "none"' 2>/dev/null || echo "none")

  # Lifecycle
  lc_count=$(aws_safe s3api get-bucket-lifecycle-configuration --bucket "$name" \
    | jq '.Rules | length' 2>/dev/null || echo "0")

  # Tags
  tags_json=$(aws_safe s3api get-bucket-tagging --bucket "$name" \
    | jq -c '.TagSet // []' 2>/dev/null || echo "[]")
  tags_hcl=$(render_tags_hcl "$tags_json")

  add_csv "S3 Bucket" "$name" "$name" "$bucket_region" "$arn" "active" \
    "Created=${created},Versioning=${versioning},Encryption=${encryption},LifecycleRules=${lc_count}"

  attrs="  bucket = \"${name}\"\n  # region is managed via provider alias\n"
  [[ "$versioning" == "Enabled" ]] && attrs="${attrs}\n  # versioning { enabled = true }"
  [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

  emit_resource "s3" "aws_s3_bucket" "$name" "$(sanitise_label "bucket_${name}")" \
    "$bucket_region" "$(printf '%b' "$attrs")"
  ((COUNT++)) || true
done < <(aws_safe s3api list-buckets | jq -c '.Buckets[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} S3 buckets"

# ── Route53 Hosted Zones ──────────────────────────────────────────────────────
log_section "Route53 Hosted Zones"
COUNT=0
while IFS= read -r zone; do
  [[ -z "$zone" || "$zone" == "null" ]] && continue
  id=$(echo "$zone"      | jq -r '.Id // ""' | sed 's|/hostedzone/||'); [[ -z "$id" ]] && continue
  name=$(echo "$zone"    | jq -r '.Name // ""')
  private=$(echo "$zone" | jq -r '.Config.PrivateZone // false')
  comment=$(echo "$zone" | jq -r '.Config.Comment // ""')
  record_count=$(echo "$zone" | jq -r '.ResourceRecordSetCount // 0')

  # Tags on hosted zones use a different API
  tags_json=$(aws_safe route53 list-tags-for-resource \
    --resource-type hostedzone --resource-id "$id" \
    | jq -c '.ResourceTagSet.Tags // []' 2>/dev/null || echo "[]")
  tags_hcl=$(render_tags_hcl "$tags_json")

  add_csv "Route53 Zone" "$id" "$name" "global" \
    "arn:aws:route53:::hostedzone/${id}" "active" \
    "Private=${private},RecordCount=${record_count}"

  attrs="  name          = \"${name}\"\n"
  [[ "$private" == "true" ]] && attrs="${attrs}  # vpc { vpc_id = \"\" }\n"
  [[ -n "$comment" ]] && attrs="${attrs}  comment = \"${comment}\"\n"
  [[ -n "$tags_hcl" ]] && attrs="${attrs}${tags_hcl}"

  emit_resource "route53" "aws_route53_zone" "$id" \
    "$(sanitise_label "zone_${name}")" "global" "$(printf '%b' "$attrs")"
  ((COUNT++)) || true
done < <(aws_safe route53 list-hosted-zones | jq -c '.HostedZones[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} hosted zones"

# ── ACM Certificates (us-east-1) ──────────────────────────────────────────────
log_section "ACM Certificates (us-east-1)"
COUNT=0
while IFS= read -r cert; do
  [[ -z "$cert" || "$cert" == "null" ]] && continue
  arn=$(echo "$cert"    | jq -r '.CertificateArn // ""');  [[ -z "$arn" ]] && continue
  domain=$(echo "$cert" | jq -r '.DomainName // ""')
  status=$(echo "$cert" | jq -r '.Status // ""')

  DETAIL=$(aws_region us-east-1 acm describe-certificate --certificate-arn "$arn" \
    | jq -c '.Certificate' 2>/dev/null || echo "null")
  [[ "$DETAIL" == "null" ]] && DETAIL="{}"

  validation=$(echo "$DETAIL" | jq -r '.DomainValidationOptions[0].ValidationMethod // "DNS"')
  sans=$(echo "$DETAIL"       | jq -r '[.SubjectAlternativeNames[]?] | join(",")' 2>/dev/null || true)
  key_algo=$(echo "$DETAIL"   | jq -r '.KeyAlgorithm // ""')
  renewal=$(echo "$DETAIL"    | jq -r '.RenewalEligibility // ""')
  tags_json=$(aws_region us-east-1 acm list-tags-for-certificate --certificate-arn "$arn" \
    | jq -c '.Tags // []' 2>/dev/null || echo "[]")
  tags_hcl=$(render_tags_hcl "$tags_json")

  add_csv "ACM Certificate" "$arn" "$domain" "us-east-1" "$arn" "$status" \
    "Validation=${validation},SANs=${sans},KeyAlgo=${key_algo},Renewal=${renewal}"

  attrs="  domain_name               = \"${domain}\"\n  validation_method         = \"${validation}\""
  [[ -n "$sans" ]] && attrs="${attrs}\n  # subject_alternative_names = [${sans}]"
  [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

  emit_resource "acm" "aws_acm_certificate" "$arn" \
    "$(sanitise_label "cert_${domain}")" "us-east-1" "$(printf '%b' "$attrs")"
  ((COUNT++)) || true
done < <(aws_region us-east-1 acm list-certificates | jq -c '.CertificateSummaryList[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} ACM certificates"

# ── CloudFront Distributions ──────────────────────────────────────────────────
log_section "CloudFront Distributions"
COUNT=0
while IFS= read -r dist; do
  [[ -z "$dist" || "$dist" == "null" ]] && continue
  id=$(echo "$dist"          | jq -r '.Id // ""');  [[ -z "$id" ]] && continue
  arn=$(echo "$dist"         | jq -r '.ARN // ""')
  domain=$(echo "$dist"      | jq -r '.DomainName // ""')
  status=$(echo "$dist"      | jq -r '.Status // ""')
  comment=$(echo "$dist"     | jq -r '.Comment // ""')
  price_class=$(echo "$dist" | jq -r '.PriceClass // ""')
  http_version=$(echo "$dist"| jq -r '.HttpVersion // ""')
  enabled=$(echo "$dist"     | jq -r '.Enabled // true')
  aliases=$(echo "$dist"     | jq -r '[.Aliases.Items[]?] | join(",")' 2>/dev/null || true)

  # Origins
  origins=$(echo "$dist" | jq -r '[.Origins.Items[]?.DomainName] | join(",")' 2>/dev/null || true)

  # Tags (CloudFront tags are on the ARN)
  tags_json=$(aws_safe cloudfront list-tags-for-resource --resource "$arn" \
    | jq -c '.Tags.Items // []' | jq -c '[.[] | {Key: .Key, Value: .Value}]' 2>/dev/null || echo "[]")
  tags_hcl=$(render_tags_hcl "$tags_json")

  add_csv "CloudFront" "$id" "${aliases:-$domain}" "global" "$arn" "$status" \
    "Domain=${domain},Origins=${origins},PriceClass=${price_class},Enabled=${enabled}"

  attrs="  enabled         = ${enabled}\n  price_class     = \"${price_class}\"\n  http_version    = \"${http_version}\""
  [[ -n "$comment" ]]    && attrs="${attrs}\n  comment         = \"${comment}\""
  [[ -n "$aliases" ]]    && attrs="${attrs}\n  # aliases       = [\"${aliases}\"]"
  attrs="${attrs}\n\n  # TODO: define origin, default_cache_behavior after import"
  [[ -n "$tags_hcl" ]]   && attrs="${attrs}\n${tags_hcl}"

  emit_resource "cloudfront" "aws_cloudfront_distribution" "$id" \
    "$(sanitise_label "cf_${id}")" "global" "$(printf '%b' "$attrs")"
  ((COUNT++)) || true
done < <(aws_safe cloudfront list-distributions | jq -c '.DistributionList.Items[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} CloudFront distributions"

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
# REGIONAL RESOURCES — scan regions in parallel (up to $CONCURRENCY workers)
# =============================================================================

scan_region() {
  local REGION="$1"
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

  # ── EBS Volumes ───────────────────────────────────────────────────────────
  log_section "EBS Volumes [${REGION}]"
  COUNT=0
  while IFS= read -r vol; do
    [[ -z "$vol" || "$vol" == "null" ]] && continue
    id=$(echo "$vol"      | jq -r '.VolumeId // ""');  [[ -z "$id" ]] && continue
    state=$(echo "$vol"   | jq -r '.State // ""')
    size=$(echo "$vol"    | jq -r '.Size // 0')
    type=$(echo "$vol"    | jq -r '.VolumeType // ""')
    az=$(echo "$vol"      | jq -r '.AvailabilityZone // ""')
    iops=$(echo "$vol"    | jq -r '.Iops // 0')
    throughput=$(echo "$vol" | jq -r '.Throughput // 0')
    encrypted=$(echo "$vol"  | jq -r '.Encrypted // false')
    kms_key=$(echo "$vol"    | jq -r '.KmsKeyId // ""')
    snapshot=$(echo "$vol"   | jq -r '.SnapshotId // ""')
    multi_attach=$(echo "$vol" | jq -r '.MultiAttachEnabled // false')
    tags=$(echo "$vol"    | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:volume/${id}"

    add_csv "EBS Volume" "$id" "$name" "$REGION" "$arn" "$state" \
      "Size=${size}GB,Type=${type},AZ=${az},IOPS=${iops},Encrypted=${encrypted}"

    attrs="  availability_zone    = \"${az}\"\n  size                 = ${size}\n  type                 = \"${type}\"\n  encrypted            = ${encrypted}"
    [[ "$iops" -gt 0 ]]      2>/dev/null && attrs="${attrs}\n  iops                 = ${iops}"
    [[ "$throughput" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n  throughput           = ${throughput}"
    [[ -n "$kms_key" ]]      && attrs="${attrs}\n  kms_key_id           = \"${kms_key}\""
    [[ -n "$snapshot" ]]     && attrs="${attrs}\n  snapshot_id          = \"${snapshot}\""
    [[ "$multi_attach" == "true" ]] && attrs="${attrs}\n  multi_attach_enabled = true"
    [[ -n "$tags_hcl" ]]     && attrs="${attrs}\n${tags_hcl}"

    emit_resource "ec2" "aws_ebs_volume" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-volumes | jq -c '.Volumes[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} EBS volumes"

  # ── Elastic IPs ───────────────────────────────────────────────────────────
  log_section "Elastic IPs [${REGION}]"
  COUNT=0
  while IFS= read -r eip; do
    [[ -z "$eip" || "$eip" == "null" ]] && continue
    alloc=$(echo "$eip"      | jq -r '.AllocationId // "N/A"')
    ip=$(echo "$eip"         | jq -r '.PublicIp // ""');   [[ -z "$ip" ]] && continue
    assoc=$(echo "$eip"      | jq -r '.AssociationId // "unassociated"')
    instance=$(echo "$eip"   | jq -r '.InstanceId // ""')
    eni=$(echo "$eip"        | jq -r '.NetworkInterfaceId // ""')
    private_ip=$(echo "$eip" | jq -r '.PrivateIpAddress // ""')
    tags=$(echo "$eip"       | jq -c '.Tags // []')
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:elastic-ip/${alloc}"

    add_csv "Elastic IP" "$alloc" "$ip" "$REGION" "$arn" "$assoc" \
      "PublicIP=${ip},Instance=${instance},ENI=${eni},PrivateIP=${private_ip}"

    attrs="  domain = \"vpc\""
    [[ -n "$instance" ]] && attrs="${attrs}\n  # instance  = \"${instance}\""
    [[ -n "$eni" ]]      && attrs="${attrs}\n  # network_interface = \"${eni}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpc" "aws_eip" "$alloc" \
      "$(sanitise_label "eip_${ip//./_}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-addresses | jq -c '.Addresses[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} Elastic IPs"

  # ── RDS Instances ─────────────────────────────────────────────────────────
  log_section "RDS Instances [${REGION}]"
  COUNT=0
  while IFS= read -r db; do
    [[ -z "$db" || "$db" == "null" ]] && continue
    id=$(echo "$db"           | jq -r '.DBInstanceIdentifier // ""');  [[ -z "$id" ]] && continue
    engine=$(echo "$db"       | jq -r '.Engine // ""')
    version=$(echo "$db"      | jq -r '.EngineVersion // ""')
    class=$(echo "$db"        | jq -r '.DBInstanceClass // ""')
    status=$(echo "$db"       | jq -r '.DBInstanceStatus // ""')
    storage=$(echo "$db"      | jq -r '.AllocatedStorage // 0')
    max_storage=$(echo "$db"  | jq -r '.MaxAllocatedStorage // 0')
    storage_type=$(echo "$db" | jq -r '.StorageType // "gp2"')
    iops=$(echo "$db"         | jq -r '.Iops // 0')
    multi_az=$(echo "$db"     | jq -r '.MultiAZ // false')
    public=$(echo "$db"       | jq -r '.PubliclyAccessible // false')
    encrypted=$(echo "$db"    | jq -r '.StorageEncrypted // false')
    kms_key=$(echo "$db"      | jq -r '.KmsKeyId // ""')
    db_name=$(echo "$db"      | jq -r '.DBName // ""')
    port=$(echo "$db"         | jq -r '.Endpoint.Port // 5432')
    backup_retention=$(echo "$db" | jq -r '.BackupRetentionPeriod // 0')
    backup_window=$(echo "$db"    | jq -r '.PreferredBackupWindow // ""')
    maint_window=$(echo "$db"     | jq -r '.PreferredMaintenanceWindow // ""')
    deletion_protection=$(echo "$db" | jq -r '.DeletionProtection // false')
    ca_cert=$(echo "$db"      | jq -r '.CACertificateIdentifier // ""')
    param_group=$(echo "$db"  | jq -r '.DBParameterGroups[0].DBParameterGroupName // ""')
    option_group=$(echo "$db" | jq -r '.OptionGroupMemberships[0].OptionGroupName // ""')
    subnet_group=$(echo "$db" | jq -r '.DBSubnetGroup.DBSubnetGroupName // ""')
    sg_ids=$(echo "$db"       | jq -r '[.VpcSecurityGroups[]?.VpcSecurityGroupId] | join(",")' 2>/dev/null || true)
    arn=$(echo "$db"          | jq -r '.DBInstanceArn // ""')

    tags_json=$(aws_region "$REGION" rds list-tags-for-resource --resource-name "$arn" \
      | jq -c '.TagList // []' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "RDS Instance" "$id" "$id" "$REGION" "$arn" "$status" \
      "Engine=${engine} ${version},Class=${class},Storage=${storage}GB,StorageType=${storage_type},MultiAZ=${multi_az},Encrypted=${encrypted},DeletionProtection=${deletion_protection}"

    attrs="  identifier              = \"${id}\"\n  engine                  = \"${engine}\"\n  engine_version          = \"${version}\"\n  instance_class          = \"${class}\"\n  allocated_storage       = ${storage}\n  storage_type            = \"${storage_type}\"\n  storage_encrypted       = ${encrypted}\n  multi_az                = ${multi_az}\n  publicly_accessible     = ${public}\n  deletion_protection     = ${deletion_protection}\n  backup_retention_period = ${backup_retention}\n  skip_final_snapshot     = false"
    [[ "$max_storage" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n  max_allocated_storage   = ${max_storage}"
    [[ "$iops" -gt 0 ]]        2>/dev/null && attrs="${attrs}\n  iops                   = ${iops}"
    [[ -n "$db_name" ]]        && attrs="${attrs}\n  db_name                 = \"${db_name}\""
    [[ -n "$port" ]]           && attrs="${attrs}\n  port                    = ${port}"
    [[ -n "$kms_key" ]]        && attrs="${attrs}\n  kms_key_id              = \"${kms_key}\""
    [[ -n "$ca_cert" ]]        && attrs="${attrs}\n  ca_cert_identifier      = \"${ca_cert}\""
    [[ -n "$param_group" ]]    && attrs="${attrs}\n  parameter_group_name    = \"${param_group}\""
    [[ -n "$option_group" ]]   && attrs="${attrs}\n  option_group_name       = \"${option_group}\""
    [[ -n "$subnet_group" ]]   && attrs="${attrs}\n  db_subnet_group_name    = \"${subnet_group}\""
    [[ -n "$sg_ids" ]]         && attrs="${attrs}\n  vpc_security_group_ids  = [\"${sg_ids//,/\",\"}\"]"
    [[ -n "$backup_window" ]]  && attrs="${attrs}\n  backup_window           = \"${backup_window}\""
    [[ -n "$maint_window" ]]   && attrs="${attrs}\n  maintenance_window      = \"${maint_window}\""
    attrs="${attrs}\n  # username / password must be set separately (use aws_ssm_parameter or Secrets Manager)"
    [[ -n "$tags_hcl" ]]       && attrs="${attrs}\n${tags_hcl}"

    emit_resource "rds" "aws_db_instance" "$id" \
      "$(sanitise_label "rds_${id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" rds describe-db-instances | jq -c '.DBInstances[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} RDS instances"

  # ── Aurora Clusters ───────────────────────────────────────────────────────
  log_section "Aurora Clusters [${REGION}]"
  COUNT=0
  while IFS= read -r cluster; do
    [[ -z "$cluster" || "$cluster" == "null" ]] && continue
    id=$(echo "$cluster"             | jq -r '.DBClusterIdentifier // ""');  [[ -z "$id" ]] && continue
    engine=$(echo "$cluster"         | jq -r '.Engine // ""')
    version=$(echo "$cluster"        | jq -r '.EngineVersion // ""')
    engine_mode=$(echo "$cluster"    | jq -r '.EngineMode // "provisioned"')
    status=$(echo "$cluster"         | jq -r '.Status // ""')
    port=$(echo "$cluster"           | jq -r '.Port // 3306')
    db_name=$(echo "$cluster"        | jq -r '.DatabaseName // ""')
    subnet_group=$(echo "$cluster"   | jq -r '.DBSubnetGroup // ""')
    backup_retention=$(echo "$cluster" | jq -r '.BackupRetentionPeriod // 1')
    backup_window=$(echo "$cluster"  | jq -r '.PreferredBackupWindow // ""')
    maint_window=$(echo "$cluster"   | jq -r '.PreferredMaintenanceWindow // ""')
    encrypted=$(echo "$cluster"      | jq -r '.StorageEncrypted // false')
    kms_key=$(echo "$cluster"        | jq -r '.KmsKeyId // ""')
    deletion_protection=$(echo "$cluster" | jq -r '.DeletionProtection // false')
    iam_auth=$(echo "$cluster"       | jq -r '.IAMDatabaseAuthenticationEnabled // false')
    sg_ids=$(echo "$cluster"         | jq -r '[.VpcSecurityGroups[]?.VpcSecurityGroupId] | join(",")' 2>/dev/null || true)
    arn=$(echo "$cluster"            | jq -r '.DBClusterArn // ""')

    tags_json=$(aws_region "$REGION" rds list-tags-for-resource --resource-name "$arn" \
      | jq -c '.TagList // []' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "RDS Cluster" "$id" "$id" "$REGION" "$arn" "$status" \
      "Engine=${engine} ${version},Mode=${engine_mode},Encrypted=${encrypted},DeletionProtection=${deletion_protection}"

    attrs="  cluster_identifier              = \"${id}\"\n  engine                          = \"${engine}\"\n  engine_version                  = \"${version}\"\n  engine_mode                     = \"${engine_mode}\"\n  storage_encrypted               = ${encrypted}\n  deletion_protection             = ${deletion_protection}\n  iam_database_authentication_enabled = ${iam_auth}\n  backup_retention_period         = ${backup_retention}\n  skip_final_snapshot             = false"
    [[ -n "$db_name" ]]     && attrs="${attrs}\n  database_name                   = \"${db_name}\""
    [[ -n "$port" ]]        && attrs="${attrs}\n  port                            = ${port}"
    [[ -n "$kms_key" ]]     && attrs="${attrs}\n  kms_key_id                      = \"${kms_key}\""
    [[ -n "$subnet_group" ]] && attrs="${attrs}\n  db_subnet_group_name            = \"${subnet_group}\""
    [[ -n "$sg_ids" ]]      && attrs="${attrs}\n  vpc_security_group_ids          = [\"${sg_ids//,/\",\"}\"]"
    [[ -n "$backup_window" ]] && attrs="${attrs}\n  preferred_backup_window         = \"${backup_window}\""
    [[ -n "$maint_window" ]] && attrs="${attrs}\n  preferred_maintenance_window    = \"${maint_window}\""
    attrs="${attrs}\n  # master_username / master_password — set via Secrets Manager reference"
    [[ -n "$tags_hcl" ]]    && attrs="${attrs}\n${tags_hcl}"

    emit_resource "rds" "aws_rds_cluster" "$id" \
      "$(sanitise_label "cluster_${id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" rds describe-db-clusters | jq -c '.DBClusters[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} Aurora clusters"

  # ── Load Balancers (ALB/NLB) ──────────────────────────────────────────────
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
  log_section "Lambda Functions [${REGION}]"
  COUNT=0
  while IFS= read -r fn; do
    [[ -z "$fn" || "$fn" == "null" ]] && continue
    name=$(echo "$fn"         | jq -r '.FunctionName // ""');  [[ -z "$name" ]] && continue
    arn=$(echo "$fn"          | jq -r '.FunctionArn // ""')
    runtime=$(echo "$fn"      | jq -r '.Runtime // "N/A"')
    handler=$(echo "$fn"      | jq -r '.Handler // "N/A"')
    memory=$(echo "$fn"       | jq -r '.MemorySize // 128')
    timeout=$(echo "$fn"      | jq -r '.Timeout // 3')
    role=$(echo "$fn"         | jq -r '.Role // ""')
    description=$(echo "$fn"  | jq -r '.Description // ""')
    arch=$(echo "$fn"         | jq -r '.Architectures[0] // "x86_64"')
    ephemeral=$(echo "$fn"    | jq -r '.EphemeralStorage.Size // 512')
    package_type=$(echo "$fn" | jq -r '.PackageType // "Zip"')
    kms_key=$(echo "$fn"      | jq -r '.KMSKeyArn // ""')

    # VPC config
    vpc_id=$(echo "$fn"       | jq -r '.VpcConfig.VpcId // ""')
    vpc_subnets=$(echo "$fn"  | jq -r '[.VpcConfig.SubnetIds[]?] | join(",")' 2>/dev/null || true)
    vpc_sgs=$(echo "$fn"      | jq -r '[.VpcConfig.SecurityGroupIds[]?] | join(",")' 2>/dev/null || true)

    # Environment variables (keys only — values may be sensitive)
    env_keys=$(echo "$fn" | jq -r '[.Environment.Variables // {} | keys[]] | join(",")' 2>/dev/null || true)

    tags_json=$(aws_region "$REGION" lambda list-tags --resource "$arn" \
      | jq -c '[to_entries[] | {Key: .key, Value: .value}]' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "Lambda Function" "$name" "$name" "$REGION" "$arn" "active" \
      "Runtime=${runtime},Handler=${handler},Memory=${memory}MB,Timeout=${timeout}s,Arch=${arch},EnvKeys=${env_keys}"

    attrs="  function_name                  = \"${name}\"\n  runtime                        = \"${runtime}\"\n  handler                        = \"${handler}\"\n  memory_size                    = ${memory}\n  timeout                        = ${timeout}\n  role                           = \"${role}\"\n  architectures                  = [\"${arch}\"]\n  package_type                   = \"${package_type}\""
    [[ -n "$description" ]]  && attrs="${attrs}\n  description                    = \"${description}\""
    [[ "$ephemeral" -ne 512 ]] 2>/dev/null && attrs="${attrs}\n  ephemeral_storage { size = ${ephemeral} }"
    [[ -n "$kms_key" ]]      && attrs="${attrs}\n  kms_key_arn                    = \"${kms_key}\""
    if [[ -n "$vpc_id" ]]; then
      attrs="${attrs}\n\n  vpc_config {\n    subnet_ids         = [\"${vpc_subnets//,/\",\"}\"]\n    security_group_ids = [\"${vpc_sgs//,/\",\"}\"]\n  }"
    fi
    [[ -n "$env_keys" ]] && attrs="${attrs}\n\n  environment {\n    variables = {\n      # Keys: ${env_keys}\n      # TODO: fill values (use sensitive() or SSM references)\n    }\n  }"
    attrs="${attrs}\n\n  # source_code_hash / filename — set after import"
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "lambda" "aws_lambda_function" "$name" \
      "$(sanitise_label "lambda_${name}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" lambda list-functions | jq -c '.Functions[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} Lambda functions"

  # ── ECS Clusters ──────────────────────────────────────────────────────────
  log_section "ECS Clusters [${REGION}]"
  COUNT=0
  ECS_ARNS=$(aws_region "$REGION" ecs list-clusters | jq -r '.clusterArns[]?' 2>/dev/null || true)
  if [[ -n "$ECS_ARNS" ]]; then
    while IFS= read -r cluster; do
      [[ -z "$cluster" || "$cluster" == "null" ]] && continue
      name=$(echo "$cluster"              | jq -r '.clusterName // ""');  [[ -z "$name" ]] && continue
      arn=$(echo "$cluster"               | jq -r '.clusterArn // ""')
      status=$(echo "$cluster"            | jq -r '.status // ""')
      svcs=$(echo "$cluster"              | jq -r '.activeServicesCount // 0')
      tasks=$(echo "$cluster"             | jq -r '.runningTasksCount // 0')
      capacity_providers=$(echo "$cluster"| jq -r '[.capacityProviders[]?] | join(",")' 2>/dev/null || true)
      container_insights=$(echo "$cluster"| jq -r '.settings[] | select(.name=="containerInsights") | .value // "disabled"' 2>/dev/null || echo "disabled")

      tags_json=$(echo "$cluster" | jq -c '.tags // []' \
        | jq -c '[.[] | {Key: .key, Value: .value}]' 2>/dev/null || echo "[]")
      tags_hcl=$(render_tags_hcl "$tags_json")

      add_csv "ECS Cluster" "$name" "$name" "$REGION" "$arn" "$status" \
        "ActiveServices=${svcs},RunningTasks=${tasks},ContainerInsights=${container_insights}"

      attrs="  name = \"${name}\"\n\n  setting {\n    name  = \"containerInsights\"\n    value = \"${container_insights}\"\n  }"
      [[ -n "$capacity_providers" ]] && attrs="${attrs}\n\n  # capacity_providers = [\"${capacity_providers//,/\",\"}\"]"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "ecs" "aws_ecs_cluster" "$name" \
        "$(sanitise_label "ecs_${name}")" "$REGION" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(aws_region "$REGION" ecs describe-clusters \
      --clusters $ECS_ARNS --include TAGS SETTINGS \
      | jq -c '.clusters[]?' 2>/dev/null || true)
  fi
  echo -e "  ${GREEN}✓${NC} ${COUNT} ECS clusters"

  # ── EKS Clusters ──────────────────────────────────────────────────────────
  log_section "EKS Clusters [${REGION}]"
  COUNT=0
  while IFS= read -r cluster_name; do
    [[ -z "$cluster_name" || "$cluster_name" == "null" ]] && continue
    DETAIL=$(aws_region "$REGION" eks describe-cluster --name "$cluster_name" \
      | jq -c '.cluster' 2>/dev/null || echo "null")
    [[ "$DETAIL" == "null" ]] && continue

    arn=$(echo "$DETAIL"             | jq -r '.arn // ""')
    status=$(echo "$DETAIL"          | jq -r '.status // ""')
    version=$(echo "$DETAIL"         | jq -r '.version // ""')
    endpoint=$(echo "$DETAIL"        | jq -r '.endpoint // ""')
    role_arn=$(echo "$DETAIL"        | jq -r '.roleArn // ""')
    vpc_id=$(echo "$DETAIL"          | jq -r '.resourcesVpcConfig.vpcId // ""')
    subnets=$(echo "$DETAIL"         | jq -r '[.resourcesVpcConfig.subnetIds[]?] | join(",")' 2>/dev/null || true)
    sg_ids=$(echo "$DETAIL"          | jq -r '[.resourcesVpcConfig.securityGroupIds[]?] | join(",")' 2>/dev/null || true)
    public_access=$(echo "$DETAIL"   | jq -r '.resourcesVpcConfig.endpointPublicAccess // true')
    private_access=$(echo "$DETAIL"  | jq -r '.resourcesVpcConfig.endpointPrivateAccess // false')
    public_cidrs=$(echo "$DETAIL"    | jq -r '[.resourcesVpcConfig.publicAccessCidrs[]?] | join(",")' 2>/dev/null || true)
    logging=$(echo "$DETAIL"         | jq -r '[.logging.clusterLogging[]? | select(.enabled==true) | .types[]?] | join(",")' 2>/dev/null || true)
    encryption_key=$(echo "$DETAIL"  | jq -r '.encryptionConfig[0].provider.keyArn // ""')
    tags=$(echo "$DETAIL"            | jq -c 'if .tags then [.tags | to_entries[] | {Key: .key, Value: .value}] else [] end' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags")

    add_csv "EKS Cluster" "$cluster_name" "$cluster_name" "$REGION" "$arn" "$status" \
      "K8sVersion=${version},PublicAccess=${public_access},PrivateAccess=${private_access},Logging=${logging}"

    attrs="  name     = \"${cluster_name}\"\n  version  = \"${version}\"\n  role_arn = \"${role_arn}\"\n\n  vpc_config {\n    subnet_ids              = [\"${subnets//,/\",\"}\"]\n    endpoint_public_access  = ${public_access}\n    endpoint_private_access = ${private_access}"
    [[ -n "$sg_ids" ]]      && attrs="${attrs}\n    security_group_ids      = [\"${sg_ids//,/\",\"}\"]\n  }"    || attrs="${attrs}\n  }"
    [[ -n "$public_cidrs" ]] && attrs="${attrs}\n    public_access_cidrs     = [\"${public_cidrs//,/\",\"}\"]"
    if [[ -n "$logging" ]]; then
      types=$(echo "$logging" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
      attrs="${attrs}\n\n  enabled_cluster_log_types = [${types}]"
    fi
    [[ -n "$encryption_key" ]] && attrs="${attrs}\n\n  encryption_config {\n    resources = [\"secrets\"]\n    provider { key_arn = \"${encryption_key}\" }\n  }"
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "eks" "aws_eks_cluster" "$cluster_name" \
      "$(sanitise_label "eks_${cluster_name}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" eks list-clusters | jq -r '.clusters[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} EKS clusters"

  # ── ElastiCache Clusters ──────────────────────────────────────────────────
  log_section "ElastiCache Clusters [${REGION}]"
  COUNT=0
  while IFS= read -r c; do
    [[ -z "$c" || "$c" == "null" ]] && continue
    id=$(echo "$c"           | jq -r '.CacheClusterId // ""');  [[ -z "$id" ]] && continue
    engine=$(echo "$c"       | jq -r '.Engine // ""')
    version=$(echo "$c"      | jq -r '.EngineVersion // ""')
    node=$(echo "$c"         | jq -r '.CacheNodeType // ""')
    status=$(echo "$c"       | jq -r '.CacheClusterStatus // ""')
    arn=$(echo "$c"          | jq -r '.ARN // ""')
    num_nodes=$(echo "$c"    | jq -r '.NumCacheNodes // 1')
    az=$(echo "$c"           | jq -r '.PreferredAvailabilityZone // ""')
    subnet_group=$(echo "$c" | jq -r '.CacheSubnetGroupName // ""')
    param_group=$(echo "$c"  | jq -r '.CacheParameterGroup.CacheParameterGroupName // ""')
    sg_ids=$(echo "$c"       | jq -r '[.SecurityGroups[]?.SecurityGroupId] | join(",")' 2>/dev/null || true)
    maintenance=$(echo "$c"  | jq -r '.PreferredMaintenanceWindow // ""')
    snapshot_ret=$(echo "$c" | jq -r '.SnapshotRetentionLimit // 0')
    snapshot_win=$(echo "$c" | jq -r '.SnapshotWindow // ""')
    port=$(echo "$c"         | jq -r '.ConfigurationEndpoint.Port // .CacheNodes[0].Endpoint.Port // 6379')
    auto_upgrade=$(echo "$c" | jq -r '.AutoMinorVersionUpgrade // true')

    tags_json=$(aws_region "$REGION" elasticache list-tags-for-resource --resource-name "$arn" \
      | jq -c '.TagList // []' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "ElastiCache" "$id" "$id" "$REGION" "$arn" "$status" \
      "Engine=${engine} ${version},NodeType=${node},Nodes=${num_nodes},AZ=${az}"

    attrs="  cluster_id               = \"${id}\"\n  engine                   = \"${engine}\"\n  engine_version           = \"${version}\"\n  node_type                = \"${node}\"\n  num_cache_nodes          = ${num_nodes}\n  port                     = ${port}\n  auto_minor_version_upgrade = ${auto_upgrade}"
    [[ -n "$az" ]]          && attrs="${attrs}\n  availability_zone        = \"${az}\""
    [[ -n "$subnet_group" ]] && attrs="${attrs}\n  subnet_group_name        = \"${subnet_group}\""
    [[ -n "$param_group" ]] && attrs="${attrs}\n  parameter_group_name     = \"${param_group}\""
    [[ -n "$sg_ids" ]]      && attrs="${attrs}\n  security_group_ids       = [\"${sg_ids//,/\",\"}\"]"
    [[ -n "$maintenance" ]] && attrs="${attrs}\n  maintenance_window       = \"${maintenance}\""
    [[ "$snapshot_ret" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n  snapshot_retention_limit = ${snapshot_ret}"
    [[ -n "$snapshot_win" ]] && attrs="${attrs}\n  snapshot_window          = \"${snapshot_win}\""
    [[ -n "$tags_hcl" ]]    && attrs="${attrs}\n${tags_hcl}"

    emit_resource "elasticache" "aws_elasticache_cluster" "$id" \
      "$(sanitise_label "cache_${id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" elasticache describe-cache-clusters --show-cache-node-info \
    | jq -c '.CacheClusters[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} ElastiCache clusters"

  # ── DynamoDB Tables ───────────────────────────────────────────────────────
  log_section "DynamoDB Tables [${REGION}]"
  COUNT=0
  while IFS= read -r table; do
    [[ -z "$table" || "$table" == "null" ]] && continue
    DETAIL=$(aws_region "$REGION" dynamodb describe-table --table-name "$table" \
      | jq -c '.Table' 2>/dev/null || echo "null")
    [[ "$DETAIL" == "null" ]] && continue

    status=$(echo "$DETAIL"          | jq -r '.TableStatus // ""')
    arn=$(echo "$DETAIL"             | jq -r '.TableArn // ""')
    billing=$(echo "$DETAIL"         | jq -r '.BillingModeSummary.BillingMode // "PROVISIONED"')
    rcu=$(echo "$DETAIL"             | jq -r '.ProvisionedThroughput.ReadCapacityUnits // 0')
    wcu=$(echo "$DETAIL"             | jq -r '.ProvisionedThroughput.WriteCapacityUnits // 0')
    stream_enabled=$(echo "$DETAIL"  | jq -r '.StreamSpecification.StreamEnabled // false')
    stream_view=$(echo "$DETAIL"     | jq -r '.StreamSpecification.StreamViewType // ""')
    ttl_attr=$(aws_region "$REGION" dynamodb describe-time-to-live --table-name "$table" \
      | jq -r 'if .TimeToLiveDescription.TimeToLiveStatus=="ENABLED" then .TimeToLiveDescription.AttributeName else "" end' 2>/dev/null || true)
    pitr=$(aws_region "$REGION" dynamodb describe-continuous-backups --table-name "$table" \
      | jq -r '.ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus // "DISABLED"' 2>/dev/null || true)
    kms_key=$(echo "$DETAIL"         | jq -r '.SSEDescription.KMSMasterKeyArn // ""')
    sse_type=$(echo "$DETAIL"        | jq -r '.SSEDescription.SSEType // ""')

    # Hash / range keys
    hash_key=$(echo "$DETAIL" | jq -r '.KeySchema[] | select(.KeyType=="HASH") | .AttributeName' 2>/dev/null || true)
    range_key=$(echo "$DETAIL"| jq -r '.KeySchema[] | select(.KeyType=="RANGE") | .AttributeName' 2>/dev/null || true)

    # Attribute definitions
    attr_defs=$(echo "$DETAIL" | jq -r '.AttributeDefinitions[] | "  attribute {\n    name = \"\(.AttributeName)\"\n    type = \"\(.AttributeType)\"\n  }"' 2>/dev/null || true)

    # GSIs
    gsi_count=$(echo "$DETAIL" | jq '.GlobalSecondaryIndexes | length' 2>/dev/null || echo 0)

    tags_json=$(aws_region "$REGION" dynamodb list-tags-of-resource --resource-arn "$arn" \
      | jq -c '.Tags // []' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "DynamoDB Table" "$table" "$table" "$REGION" "$arn" "$status" \
      "Billing=${billing},RCU=${rcu},WCU=${wcu},Streams=${stream_enabled},PITR=${pitr},GSIs=${gsi_count}"

    attrs="  name         = \"${table}\"\n  billing_mode = \"${billing}\"\n  hash_key     = \"${hash_key}\""
    [[ -n "$range_key" ]] && attrs="${attrs}\n  range_key    = \"${range_key}\""
    [[ "$billing" == "PROVISIONED" ]] && attrs="${attrs}\n  read_capacity  = ${rcu}\n  write_capacity = ${wcu}"
    attrs="${attrs}\n\n${attr_defs}"
    if [[ "$stream_enabled" == "true" ]]; then
      attrs="${attrs}\n\n  stream_enabled   = true\n  stream_view_type = \"${stream_view}\""
    fi
    if [[ "$pitr" == "ENABLED" ]]; then
      attrs="${attrs}\n\n  point_in_time_recovery { enabled = true }"
    fi
    if [[ -n "$ttl_attr" ]]; then
      attrs="${attrs}\n\n  ttl {\n    attribute_name = \"${ttl_attr}\"\n    enabled        = true\n  }"
    fi
    if [[ -n "$sse_type" ]]; then
      attrs="${attrs}\n\n  server_side_encryption {\n    enabled     = true"
      [[ -n "$kms_key" ]] && attrs="${attrs}\n    kms_key_arn = \"${kms_key}\""
      attrs="${attrs}\n  }"
    fi
    [[ "$gsi_count" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n\n  # TODO: add ${gsi_count} global_secondary_index block(s)"
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "dynamodb" "aws_dynamodb_table" "$table" \
      "$(sanitise_label "ddb_${table}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" dynamodb list-tables | jq -r '.TableNames[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} DynamoDB tables"

  # ── SNS Topics ────────────────────────────────────────────────────────────
  log_section "SNS Topics [${REGION}]"
  COUNT=0
  while IFS= read -r arn; do
    [[ -z "$arn" || "$arn" == "null" ]] && continue
    name=$(basename "$arn")

    ATTRS=$(aws_region "$REGION" sns get-topic-attributes --topic-arn "$arn" \
      | jq -r '.Attributes' 2>/dev/null || echo "{}")
    display_name=$(echo "$ATTRS"    | jq -r '.DisplayName // ""')
    fifo=$(echo "$ATTRS"            | jq -r '.FifoTopic // "false"')
    content_dedup=$(echo "$ATTRS"   | jq -r '.ContentBasedDeduplication // "false"')
    kms_key=$(echo "$ATTRS"         | jq -r '.KmsMasterKeyId // ""')
    delivery_policy=$(echo "$ATTRS" | jq -r '.DeliveryPolicy // ""')

    tags_json=$(aws_region "$REGION" sns list-tags-for-resource --resource-arn "$arn" \
      | jq -c '.Tags // []' | jq -c '[.[] | {Key: .Key, Value: .Value}]' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "SNS Topic" "$arn" "$name" "$REGION" "$arn" "active" \
      "FIFO=${fifo},KMSKey=${kms_key},ContentDedup=${content_dedup}"

    attrs="  name                        = \"${name}\"\n  fifo_topic                  = ${fifo}\n  content_based_deduplication = ${content_dedup}"
    [[ -n "$display_name" ]] && attrs="${attrs}\n  display_name                = \"${display_name}\""
    [[ -n "$kms_key" ]]      && attrs="${attrs}\n  kms_master_key_id           = \"${kms_key}\""
    [[ -n "$delivery_policy" ]] && attrs="${attrs}\n  # delivery_policy (see AWS console)"
    [[ -n "$tags_hcl" ]]     && attrs="${attrs}\n${tags_hcl}"

    emit_resource "sns" "aws_sns_topic" "$arn" \
      "$(sanitise_label "sns_${name}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" sns list-topics | jq -r '.Topics[].TopicArn?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} SNS topics"

  # ── SQS Queues ────────────────────────────────────────────────────────────
  log_section "SQS Queues [${REGION}]"
  COUNT=0
  while IFS= read -r url; do
    [[ -z "$url" || "$url" == "null" ]] && continue
    name=$(basename "$url")
    arn="arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${name}"

    ATTRS=$(aws_region "$REGION" sqs get-queue-attributes --queue-url "$url" \
      --attribute-names All | jq -r '.Attributes' 2>/dev/null || echo "{}")
    fifo=$(echo "$ATTRS"           | jq -r '.FifoQueue // "false"')
    content_dedup=$(echo "$ATTRS"  | jq -r '.ContentBasedDeduplication // "false"')
    visibility=$(echo "$ATTRS"     | jq -r '.VisibilityTimeout // "30"')
    retention=$(echo "$ATTRS"      | jq -r '.MessageRetentionPeriod // "345600"')
    max_size=$(echo "$ATTRS"       | jq -r '.MaximumMessageSize // "262144"')
    delay=$(echo "$ATTRS"          | jq -r '.DelaySeconds // "0"')
    wait_time=$(echo "$ATTRS"      | jq -r '.ReceiveMessageWaitTimeSeconds // "0"')
    kms_key=$(echo "$ATTRS"        | jq -r '.KmsMasterKeyId // ""')
    dlq_arn=$(echo "$ATTRS"        | jq -r '.RedrivePolicy | if . then (. | fromjson | .deadLetterTargetArn) else "" end' 2>/dev/null || true)
    max_receive=$(echo "$ATTRS"    | jq -r '.RedrivePolicy | if . then (. | fromjson | .maxReceiveCount) else "" end' 2>/dev/null || true)

    tags_json=$(aws_region "$REGION" sqs list-queue-tags --queue-url "$url" \
      | jq -c '[to_entries[] | {Key: .key, Value: .value}]' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "SQS Queue" "$url" "$name" "$REGION" "$arn" "active" \
      "FIFO=${fifo},Visibility=${visibility}s,Retention=${retention}s,KMSKey=${kms_key}"

    attrs="  name                        = \"${name}\"\n  fifo_queue                  = ${fifo}\n  content_based_deduplication = ${content_dedup}\n  visibility_timeout_seconds  = ${visibility}\n  message_retention_seconds   = ${retention}\n  max_message_size            = ${max_size}\n  delay_seconds               = ${delay}\n  receive_wait_time_seconds   = ${wait_time}"
    [[ -n "$kms_key" ]] && attrs="${attrs}\n  kms_master_key_id           = \"${kms_key}\""
    if [[ -n "$dlq_arn" ]]; then
      attrs="${attrs}\n\n  redrive_policy = jsonencode({\n    deadLetterTargetArn = \"${dlq_arn}\"\n    maxReceiveCount     = ${max_receive}\n  })"
    fi
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "sqs" "aws_sqs_queue" "$url" \
      "$(sanitise_label "sqs_${name}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" sqs list-queues | jq -r '.QueueUrls[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} SQS queues"

  # ── Secrets Manager ───────────────────────────────────────────────────────
  log_section "Secrets Manager [${REGION}]"
  COUNT=0
  while IFS= read -r secret; do
    [[ -z "$secret" || "$secret" == "null" ]] && continue
    name=$(echo "$secret"        | jq -r '.Name // ""');  [[ -z "$name" ]] && continue
    arn=$(echo "$secret"         | jq -r '.ARN // ""')
    desc=$(echo "$secret"        | jq -r '.Description // ""')
    kms_key=$(echo "$secret"     | jq -r '.KmsKeyId // ""')
    rotation=$(echo "$secret"    | jq -r '.RotationEnabled // false')
    rotation_days=$(echo "$secret" | jq -r '.RotationRules.AutomaticallyAfterDays // ""')
    last_changed=$(echo "$secret"| jq -r '.LastChangedDate // ""')
    tags=$(echo "$secret"        | jq -c '.Tags // []')
    tags_hcl=$(render_tags_hcl "$tags")

    add_csv "Secret" "$name" "$name" "$REGION" "$arn" "active" \
      "Rotation=${rotation},RotationDays=${rotation_days},KMSKey=${kms_key}"

    attrs="  name                    = \"${name}\"\n  recovery_window_in_days = 30"
    [[ -n "$desc" ]]     && attrs="${attrs}\n  description             = \"${desc}\""
    [[ -n "$kms_key" ]]  && attrs="${attrs}\n  kms_key_id              = \"${kms_key}\""
    if [[ "$rotation" == "true" && -n "$rotation_days" ]]; then
      attrs="${attrs}\n\n  rotation_rules {\n    automatically_after_days = ${rotation_days}\n  }"
    fi
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "secretsmanager" "aws_secretsmanager_secret" "$arn" \
      "$(sanitise_label "secret_${name}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" secretsmanager list-secrets | jq -c '.SecretList[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} secrets"

  # ── SSM Parameters ────────────────────────────────────────────────────────
  log_section "SSM Parameters [${REGION}]"
  COUNT=0
  while IFS= read -r param; do
    [[ -z "$param" || "$param" == "null" ]] && continue
    name=$(echo "$param"    | jq -r '.Name // ""');  [[ -z "$name" ]] && continue
    type=$(echo "$param"    | jq -r '.Type // ""')
    tier=$(echo "$param"    | jq -r '.Tier // "Standard"')
    version=$(echo "$param" | jq -r '.Version // 0')
    modified=$(echo "$param"| jq -r '.LastModifiedDate // ""')
    data_type=$(echo "$param"| jq -r '.DataType // "text"')
    kms_key=$(echo "$param" | jq -r '.KeyId // ""')
    arn="arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${name}"

    # Tags require a separate call
    tags_json=$(aws_region "$REGION" ssm list-tags-for-resource \
      --resource-type Parameter --resource-id "$name" \
      | jq -c '.TagList // []' 2>/dev/null || echo "[]")
    tags_hcl=$(render_tags_hcl "$tags_json")

    add_csv "SSM Parameter" "$name" "$name" "$REGION" "$arn" "active" \
      "Type=${type},Tier=${tier},Version=${version},DataType=${data_type}"

    attrs="  name      = \"${name}\"\n  type      = \"${type}\"\n  tier      = \"${tier}\"\n  data_type = \"${data_type}\"\n  # value   = \"\" # fetch separately; SecureString values are encrypted"
    [[ -n "$kms_key" && "$type" == "SecureString" ]] && attrs="${attrs}\n  key_id    = \"${kms_key}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "ssm" "aws_ssm_parameter" "$name" \
      "$(sanitise_label "param_${name}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ssm describe-parameters \
    --parameter-filters "Key=Path,Option=Recursive,Values=/" \
    | jq -c '.Parameters[]?' 2>/dev/null \
    || aws_region "$REGION" ssm describe-parameters | jq -c '.Parameters[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} SSM parameters"

  # ── NAT Gateways ──────────────────────────────────────────────────────────
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
  log_section "Virtual Private Gateways [${REGION}]"
  COUNT=0
  while IFS= read -r vgw; do
    [[ -z "$vgw" || "$vgw" == "null" ]] && continue
    id=$(echo "$vgw"      | jq -r '.VpnGatewayId // ""');  [[ -z "$id" ]] && continue
    state=$(echo "$vgw"   | jq -r '.State // ""')
    vgw_type=$(echo "$vgw"| jq -r '.Type // "ipsec.1"')
    asn=$(echo "$vgw"     | jq -r '.AmazonSideAsn // ""')
    vpc_att=$(echo "$vgw" | jq -r '.VpcAttachments[0].VpcId // "detached"')
    az=$(echo "$vgw"      | jq -r '.AvailabilityZone // ""')
    tags=$(echo "$vgw"    | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    tags_hcl=$(render_tags_hcl "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:vpn-gateway/${id}"

    add_csv "Virtual Private Gateway" "$id" "$name" "$REGION" "$arn" "$state" \
      "Type=${vgw_type},ASN=${asn},VPC=${vpc_att},AZ=${az}"

    attrs="  type            = \"${vgw_type}\""
    [[ -n "$asn" ]] && attrs="${attrs}\n  amazon_side_asn = ${asn}"
    [[ "$vpc_att" != "detached" ]] && attrs="${attrs}\n  # vpc_id        = \"${vpc_att}\"  # manage via aws_vpn_gateway_attachment"
    [[ -n "$az" ]]  && attrs="${attrs}\n  availability_zone = \"${az}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "vpn" "aws_vpn_gateway" "$id" \
      "$(sanitise_label "vgw_${name:-$id}")" "$REGION" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-vpn-gateways \
    | jq -c '.VpnGateways[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} virtual private gateways"

  # ── VPN Connections ───────────────────────────────────────────────────────
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
chmod -R 755 "${OUT_DIR}"
chown -R "$(whoami)":"$(whoami)" "${OUT_DIR}"
echo -e "  ${GREEN}✓${NC} Permissions fixed on ${OUT_DIR}"
