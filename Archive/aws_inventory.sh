#!/usr/bin/env bash
# =============================================================================
# AWS Infrastructure Inventory Script
# Discovers resources across your AWS account and outputs:
#   1. CSV  → aws_inventory_<timestamp>.csv
#   2. Terraform HCL stubs → terraform_stubs/
# =============================================================================
# REQUIREMENTS: aws-cli v2, jq
# USAGE:
#   chmod +x aws_inventory.sh
#   ./aws_inventory.sh                        # default profile + configured region
#   ./aws_inventory.sh --profile myprofile    # named profile
#   ./aws_inventory.sh --region eu-west-1     # explicit region
#   ./aws_inventory.sh --all-regions          # scan every enabled region
# =============================================================================

# No set -e — we handle errors per-command so one failure never kills the run
set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
PROFILE="default"
REGIONS=()
ALL_REGIONS=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="aws_inventory_${TIMESTAMP}"
CSV_FILE="${OUT_DIR}/aws_inventory_${TIMESTAMP}.csv"
TF_DIR="${OUT_DIR}/terraform_stubs"
SUMMARY_FILE="${OUT_DIR}/summary_${TIMESTAMP}.txt"
TOTAL_RESOURCES=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)    PROFILE="$2";     shift 2 ;;
    --region)     REGIONS+=("$2");  shift 2 ;;
    --all-regions) ALL_REGIONS=true; shift ;;
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
  # Usage: aws_safe [aws args...]
  aws --profile "${PROFILE}" --output json "$@" 2>/dev/null || echo "null"
}

aws_region() {
  # Usage: aws_region REGION [aws args...]
  local region="$1"; shift
  aws --profile "${PROFILE}" --output json --region "$region" "$@" 2>/dev/null || echo "null"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
log_section() { echo -e "\n${BOLD}${YELLOW}▶ $1${NC}"; }

add_csv() {
  local type="$1" id="$2" name="$3" region="$4" arn="$5" state="$6" attrs="$7"
  attrs="${attrs//\"/\'}"
  echo "\"${type}\",\"${id}\",\"${name}\",\"${region}\",\"${arn}\",\"${state}\",\"${attrs}\"" >> "${CSV_FILE}"
  ((TOTAL_RESOURCES++)) || true
}

get_name_tag() {
  echo "$1" | jq -r '(.[] | select(.Key=="Name") | .Value) // ""' 2>/dev/null || echo ""
}

sanitise_label() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | sed 's/^[0-9]/_&/' | cut -c1-60
}

write_tf_stub() {
  local service="$1" resource="$2" id="$3" label="$4" region="$5" attrs="${6:-}"
  local tf_file="${TF_DIR}/${service}.tf"
  if [[ ! -f "$tf_file" ]]; then
    cat >> "$tf_file" <<EOF
# Auto-generated Terraform import stubs — Account: ${ACCOUNT_ID} — ${TIMESTAMP}
# Run: terraform import <resource>.<label> <id>

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

EOF
  fi
  printf '# terraform import %s.%s %s\nresource "%s" "%s" {\n  # region = "%s"\n%s\n  lifecycle { prevent_destroy = true }\n}\n\n' \
    "$resource" "$label" "$id" "$resource" "$label" "$region" "$attrs" >> "$tf_file"
}

# ── Auth check ────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│       AWS Infrastructure Inventory Tool         │${NC}"
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
  mapfile -t REGIONS < <(aws_safe ec2 describe-regions --query 'Regions[].RegionName' | jq -r '.[]' | sort)
elif [[ ${#REGIONS[@]} -eq 0 ]]; then
  DEFAULT_REGION=$(aws --profile "${PROFILE}" configure get region 2>/dev/null || echo "us-east-1")
  REGIONS=("${DEFAULT_REGION}")
fi

echo -e "Scanning ${BOLD}${#REGIONS[@]}${NC} region(s): ${REGIONS[*]}"
echo ""

# ── Setup output ──────────────────────────────────────────────────────────────
mkdir -p "${TF_DIR}"
echo "ResourceType,ResourceID,Name,Region,ARN,State,AdditionalAttributes" > "${CSV_FILE}"

# =============================================================================
# GLOBAL RESOURCES
# =============================================================================

# ── IAM Users ─────────────────────────────────────────────────────────────────
log_section "IAM Users"
COUNT=0
while IFS= read -r user; do
  [[ -z "$user" || "$user" == "null" ]] && continue
  id=$(echo "$user"      | jq -r '.UserName // ""'); [[ -z "$id" ]] && continue
  arn=$(echo "$user"     | jq -r '.Arn // ""')
  created=$(echo "$user" | jq -r '.CreateDate // ""')
  add_csv "IAM User" "$id" "$id" "global" "$arn" "active" "Created=${created}"
  write_tf_stub "iam" "aws_iam_user" "$id" "$(sanitise_label "user_${id}")" "global" \
    "  name = \"${id}\""
  ((COUNT++)) || true
done < <(aws_safe iam list-users | jq -c '.Users[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} IAM users"

# ── IAM Roles ─────────────────────────────────────────────────────────────────
log_section "IAM Roles"
COUNT=0
while IFS= read -r role; do
  [[ -z "$role" || "$role" == "null" ]] && continue
  id=$(echo "$role"   | jq -r '.RoleName // ""'); [[ -z "$id" ]] && continue
  arn=$(echo "$role"  | jq -r '.Arn // ""')
  path=$(echo "$role" | jq -r '.Path // "/"')
  add_csv "IAM Role" "$id" "$id" "global" "$arn" "active" "Path=${path}"
  write_tf_stub "iam" "aws_iam_role" "$id" "$(sanitise_label "role_${id}")" "global" \
    "  name = \"${id}\"\n  path = \"${path}\""
  ((COUNT++)) || true
done < <(aws_safe iam list-roles | jq -c '.Roles[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} IAM roles"

# ── S3 Buckets ────────────────────────────────────────────────────────────────
log_section "S3 Buckets"
COUNT=0
while IFS= read -r bucket; do
  [[ -z "$bucket" || "$bucket" == "null" ]] && continue
  name=$(echo "$bucket"    | jq -r '.Name // ""'); [[ -z "$name" ]] && continue
  created=$(echo "$bucket" | jq -r '.CreationDate // ""')
  bucket_region=$(aws_safe s3api get-bucket-location --bucket "$name" \
    | jq -r '.LocationConstraint // "us-east-1"')
  [[ "$bucket_region" == "null" || -z "$bucket_region" ]] && bucket_region="us-east-1"
  arn="arn:aws:s3:::${name}"
  add_csv "S3 Bucket" "$name" "$name" "$bucket_region" "$arn" "active" "Created=${created}"
  write_tf_stub "s3" "aws_s3_bucket" "$name" "$(sanitise_label "bucket_${name}")" "$bucket_region" \
    "  bucket = \"${name}\""
  ((COUNT++)) || true
done < <(aws_safe s3api list-buckets | jq -c '.Buckets[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} S3 buckets"

# ── Route53 ───────────────────────────────────────────────────────────────────
log_section "Route53 Hosted Zones"
COUNT=0
while IFS= read -r zone; do
  [[ -z "$zone" || "$zone" == "null" ]] && continue
  id=$(echo "$zone"      | jq -r '.Id // ""' | sed 's|/hostedzone/||'); [[ -z "$id" ]] && continue
  name=$(echo "$zone"    | jq -r '.Name // ""')
  private=$(echo "$zone" | jq -r '.Config.PrivateZone // false')
  add_csv "Route53 Zone" "$id" "$name" "global" "arn:aws:route53:::hostedzone/${id}" "active" \
    "Private=${private}"
  write_tf_stub "route53" "aws_route53_zone" "$id" "$(sanitise_label "zone_${name}")" "global" \
    "  name = \"${name}\""
  ((COUNT++)) || true
done < <(aws_safe route53 list-hosted-zones | jq -c '.HostedZones[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} hosted zones"

# ── ACM (us-east-1 for CloudFront certs) ─────────────────────────────────────
log_section "ACM Certificates (us-east-1)"
COUNT=0
while IFS= read -r cert; do
  [[ -z "$cert" || "$cert" == "null" ]] && continue
  arn=$(echo "$cert"    | jq -r '.CertificateArn // ""'); [[ -z "$arn" ]] && continue
  domain=$(echo "$cert" | jq -r '.DomainName // ""')
  status=$(echo "$cert" | jq -r '.Status // ""')
  add_csv "ACM Certificate" "$arn" "$domain" "us-east-1" "$arn" "$status" ""
  write_tf_stub "acm" "aws_acm_certificate" "$arn" "$(sanitise_label "cert_${domain}")" "us-east-1" \
    "  domain_name = \"${domain}\""
  ((COUNT++)) || true
done < <(aws_region us-east-1 acm list-certificates | jq -c '.CertificateSummaryList[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} ACM certificates"

# ── CloudFront ────────────────────────────────────────────────────────────────
log_section "CloudFront Distributions"
COUNT=0
while IFS= read -r dist; do
  [[ -z "$dist" || "$dist" == "null" ]] && continue
  id=$(echo "$dist"     | jq -r '.Id // ""'); [[ -z "$id" ]] && continue
  arn=$(echo "$dist"    | jq -r '.ARN // ""')
  domain=$(echo "$dist" | jq -r '.DomainName // ""')
  status=$(echo "$dist" | jq -r '.Status // ""')
  add_csv "CloudFront" "$id" "$domain" "global" "$arn" "$status" ""
  write_tf_stub "cloudfront" "aws_cloudfront_distribution" "$id" \
    "$(sanitise_label "cf_${id}")" "global" \
    "  # Configure origins, cache behaviors after import"
  ((COUNT++)) || true
done < <(aws_safe cloudfront list-distributions | jq -c '.DistributionList.Items[]?' 2>/dev/null || true)
echo -e "  ${GREEN}✓${NC} ${COUNT} CloudFront distributions"

# =============================================================================
# REGIONAL RESOURCES
# =============================================================================

for REGION in "${REGIONS[@]}"; do
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  Region: ${REGION}${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # ── VPCs ──────────────────────────────────────────────────────────────────
  log_section "VPCs"
  COUNT=0
  while IFS= read -r vpc; do
    [[ -z "$vpc" || "$vpc" == "null" ]] && continue
    id=$(echo "$vpc"      | jq -r '.VpcId // ""'); [[ -z "$id" ]] && continue
    cidr=$(echo "$vpc"    | jq -r '.CidrBlock // ""')
    state=$(echo "$vpc"   | jq -r '.State // ""')
    default=$(echo "$vpc" | jq -r '.IsDefault // false')
    tags=$(echo "$vpc"    | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:vpc/${id}"
    add_csv "VPC" "$id" "$name" "$REGION" "$arn" "$state" "CIDR=${cidr},Default=${default}"
    write_tf_stub "vpc" "aws_vpc" "$id" "$(sanitise_label "${name:-$id}")" "$REGION" \
      "  cidr_block = \"${cidr}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-vpcs | jq -c '.Vpcs[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} VPCs"

  # ── Subnets ───────────────────────────────────────────────────────────────
  log_section "Subnets"
  COUNT=0
  while IFS= read -r subnet; do
    [[ -z "$subnet" || "$subnet" == "null" ]] && continue
    id=$(echo "$subnet"     | jq -r '.SubnetId // ""'); [[ -z "$id" ]] && continue
    cidr=$(echo "$subnet"   | jq -r '.CidrBlock // ""')
    vpc=$(echo "$subnet"    | jq -r '.VpcId // ""')
    az=$(echo "$subnet"     | jq -r '.AvailabilityZone // ""')
    public=$(echo "$subnet" | jq -r '.MapPublicIpOnLaunch // false')
    tags=$(echo "$subnet"   | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:subnet/${id}"
    add_csv "Subnet" "$id" "$name" "$REGION" "$arn" "available" \
      "CIDR=${cidr},VPC=${vpc},AZ=${az},PublicIP=${public}"
    write_tf_stub "vpc" "aws_subnet" "$id" "$(sanitise_label "${name:-$id}")" "$REGION" \
      "  vpc_id            = \"${vpc}\"\n  cidr_block        = \"${cidr}\"\n  availability_zone = \"${az}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-subnets | jq -c '.Subnets[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} subnets"

  # ── Security Groups ───────────────────────────────────────────────────────
  log_section "Security Groups"
  COUNT=0
  while IFS= read -r sg; do
    [[ -z "$sg" || "$sg" == "null" ]] && continue
    id=$(echo "$sg"    | jq -r '.GroupId // ""'); [[ -z "$id" ]] && continue
    name=$(echo "$sg"  | jq -r '.GroupName // ""')
    vpc=$(echo "$sg"   | jq -r '.VpcId // "none"')
    desc=$(echo "$sg"  | jq -r '.Description // ""')
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:security-group/${id}"
    add_csv "Security Group" "$id" "$name" "$REGION" "$arn" "active" \
      "VPC=${vpc},Description=${desc}"
    write_tf_stub "vpc" "aws_security_group" "$id" \
      "$(sanitise_label "sg_${name}_${id}")" "$REGION" \
      "  name   = \"${name}\"\n  vpc_id = \"${vpc}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-security-groups | jq -c '.SecurityGroups[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} security groups"

  # ── Internet Gateways ─────────────────────────────────────────────────────
  log_section "Internet Gateways"
  COUNT=0
  while IFS= read -r igw; do
    [[ -z "$igw" || "$igw" == "null" ]] && continue
    id=$(echo "$igw"   | jq -r '.InternetGatewayId // ""'); [[ -z "$id" ]] && continue
    vpc=$(echo "$igw"  | jq -r '.Attachments[0].VpcId // "detached"')
    tags=$(echo "$igw" | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:internet-gateway/${id}"
    add_csv "Internet Gateway" "$id" "$name" "$REGION" "$arn" "attached" "VPC=${vpc}"
    write_tf_stub "vpc" "aws_internet_gateway" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" \
      "  vpc_id = \"${vpc}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-internet-gateways | jq -c '.InternetGateways[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} internet gateways"

  # ── Route Tables ──────────────────────────────────────────────────────────
  log_section "Route Tables"
  COUNT=0
  while IFS= read -r rt; do
    [[ -z "$rt" || "$rt" == "null" ]] && continue
    id=$(echo "$rt"   | jq -r '.RouteTableId // ""'); [[ -z "$id" ]] && continue
    vpc=$(echo "$rt"  | jq -r '.VpcId // ""')
    tags=$(echo "$rt" | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:route-table/${id}"
    add_csv "Route Table" "$id" "$name" "$REGION" "$arn" "active" "VPC=${vpc}"
    write_tf_stub "vpc" "aws_route_table" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" \
      "  vpc_id = \"${vpc}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-route-tables | jq -c '.RouteTables[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} route tables"

  # ── EC2 Instances ─────────────────────────────────────────────────────────
  log_section "EC2 Instances"
  COUNT=0
  while IFS= read -r inst; do
    [[ -z "$inst" || "$inst" == "null" ]] && continue
    id=$(echo "$inst"     | jq -r '.InstanceId // ""'); [[ -z "$id" ]] && continue
    state=$(echo "$inst"  | jq -r '.State.Name // ""')
    type=$(echo "$inst"   | jq -r '.InstanceType // ""')
    ami=$(echo "$inst"    | jq -r '.ImageId // ""')
    az=$(echo "$inst"     | jq -r '.Placement.AvailabilityZone // ""')
    subnet=$(echo "$inst" | jq -r '.SubnetId // "none"')
    vpc=$(echo "$inst"    | jq -r '.VpcId // "none"')
    tags=$(echo "$inst"   | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${id}"
    add_csv "EC2 Instance" "$id" "$name" "$REGION" "$arn" "$state" \
      "Type=${type},AMI=${ami},AZ=${az},VPC=${vpc},Subnet=${subnet}"
    write_tf_stub "ec2" "aws_instance" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" \
      "  # instance_type = \"${type}\"\n  # ami           = \"${ami}\"\n  # subnet_id     = \"${subnet}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-instances | jq -c '.Reservations[].Instances[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} EC2 instances"

  # ── EBS Volumes ───────────────────────────────────────────────────────────
  log_section "EBS Volumes"
  COUNT=0
  while IFS= read -r vol; do
    [[ -z "$vol" || "$vol" == "null" ]] && continue
    id=$(echo "$vol"    | jq -r '.VolumeId // ""'); [[ -z "$id" ]] && continue
    state=$(echo "$vol" | jq -r '.State // ""')
    size=$(echo "$vol"  | jq -r '.Size // 0')
    type=$(echo "$vol"  | jq -r '.VolumeType // ""')
    az=$(echo "$vol"    | jq -r '.AvailabilityZone // ""')
    tags=$(echo "$vol"  | jq -c '.Tags // []')
    name=$(get_name_tag "$tags")
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:volume/${id}"
    add_csv "EBS Volume" "$id" "$name" "$REGION" "$arn" "$state" \
      "Size=${size}GB,Type=${type},AZ=${az}"
    write_tf_stub "ec2" "aws_ebs_volume" "$id" \
      "$(sanitise_label "${name:-$id}")" "$REGION" \
      "  availability_zone = \"${az}\"\n  size              = ${size}\n  type              = \"${type}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-volumes | jq -c '.Volumes[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} EBS volumes"

  # ── Elastic IPs ───────────────────────────────────────────────────────────
  log_section "Elastic IPs"
  COUNT=0
  while IFS= read -r eip; do
    [[ -z "$eip" || "$eip" == "null" ]] && continue
    alloc=$(echo "$eip" | jq -r '.AllocationId // "N/A"')
    ip=$(echo "$eip"    | jq -r '.PublicIp // ""'); [[ -z "$ip" ]] && continue
    assoc=$(echo "$eip" | jq -r '.AssociationId // "unassociated"')
    arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:elastic-ip/${alloc}"
    add_csv "Elastic IP" "$alloc" "$ip" "$REGION" "$arn" "$assoc" "PublicIP=${ip}"
    write_tf_stub "vpc" "aws_eip" "$alloc" \
      "$(sanitise_label "eip_${ip//./_}")" "$REGION" \
      "  domain = \"vpc\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ec2 describe-addresses | jq -c '.Addresses[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} Elastic IPs"

  # ── RDS Instances ─────────────────────────────────────────────────────────
  log_section "RDS Instances"
  COUNT=0
  while IFS= read -r db; do
    [[ -z "$db" || "$db" == "null" ]] && continue
    id=$(echo "$db"       | jq -r '.DBInstanceIdentifier // ""'); [[ -z "$id" ]] && continue
    engine=$(echo "$db"   | jq -r '.Engine // ""')
    version=$(echo "$db"  | jq -r '.EngineVersion // ""')
    class=$(echo "$db"    | jq -r '.DBInstanceClass // ""')
    status=$(echo "$db"   | jq -r '.DBInstanceStatus // ""')
    storage=$(echo "$db"  | jq -r '.AllocatedStorage // 0')
    multi_az=$(echo "$db" | jq -r '.MultiAZ // false')
    arn=$(echo "$db"      | jq -r '.DBInstanceArn // ""')
    add_csv "RDS Instance" "$id" "$id" "$REGION" "$arn" "$status" \
      "Engine=${engine} ${version},Class=${class},Storage=${storage}GB,MultiAZ=${multi_az}"
    write_tf_stub "rds" "aws_db_instance" "$id" \
      "$(sanitise_label "rds_${id}")" "$REGION" \
      "  identifier        = \"${id}\"\n  engine            = \"${engine}\"\n  engine_version    = \"${version}\"\n  instance_class    = \"${class}\"\n  allocated_storage = ${storage}"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" rds describe-db-instances | jq -c '.DBInstances[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} RDS instances"

  # ── Aurora Clusters ───────────────────────────────────────────────────────
  log_section "Aurora Clusters"
  COUNT=0
  while IFS= read -r cluster; do
    [[ -z "$cluster" || "$cluster" == "null" ]] && continue
    id=$(echo "$cluster"      | jq -r '.DBClusterIdentifier // ""'); [[ -z "$id" ]] && continue
    engine=$(echo "$cluster"  | jq -r '.Engine // ""')
    version=$(echo "$cluster" | jq -r '.EngineVersion // ""')
    status=$(echo "$cluster"  | jq -r '.Status // ""')
    arn=$(echo "$cluster"     | jq -r '.DBClusterArn // ""')
    add_csv "RDS Cluster" "$id" "$id" "$REGION" "$arn" "$status" \
      "Engine=${engine} ${version}"
    write_tf_stub "rds" "aws_rds_cluster" "$id" \
      "$(sanitise_label "cluster_${id}")" "$REGION" \
      "  cluster_identifier = \"${id}\"\n  engine             = \"${engine}\"\n  engine_version     = \"${version}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" rds describe-db-clusters | jq -c '.DBClusters[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} Aurora clusters"

  # ── Load Balancers ────────────────────────────────────────────────────────
  log_section "Load Balancers (ALB/NLB)"
  COUNT=0
  while IFS= read -r lb; do
    [[ -z "$lb" || "$lb" == "null" ]] && continue
    name=$(echo "$lb"   | jq -r '.LoadBalancerName // ""'); [[ -z "$name" ]] && continue
    arn=$(echo "$lb"    | jq -r '.LoadBalancerArn // ""')
    type=$(echo "$lb"   | jq -r '.Type // ""')
    scheme=$(echo "$lb" | jq -r '.Scheme // ""')
    state=$(echo "$lb"  | jq -r '.State.Code // ""')
    dns=$(echo "$lb"    | jq -r '.DNSName // ""')
    add_csv "Load Balancer" "$arn" "$name" "$REGION" "$arn" "$state" \
      "Type=${type},Scheme=${scheme},DNS=${dns}"
    write_tf_stub "alb" "aws_lb" "$arn" \
      "$(sanitise_label "${type}_${name}")" "$REGION" \
      "  name               = \"${name}\"\n  load_balancer_type = \"${type}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" elbv2 describe-load-balancers | jq -c '.LoadBalancers[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} load balancers"

  # ── Lambda Functions ──────────────────────────────────────────────────────
  log_section "Lambda Functions"
  COUNT=0
  while IFS= read -r fn; do
    [[ -z "$fn" || "$fn" == "null" ]] && continue
    name=$(echo "$fn"     | jq -r '.FunctionName // ""'); [[ -z "$name" ]] && continue
    arn=$(echo "$fn"      | jq -r '.FunctionArn // ""')
    runtime=$(echo "$fn"  | jq -r '.Runtime // "N/A"')
    handler=$(echo "$fn"  | jq -r '.Handler // "N/A"')
    memory=$(echo "$fn"   | jq -r '.MemorySize // 128')
    timeout=$(echo "$fn"  | jq -r '.Timeout // 3')
    add_csv "Lambda Function" "$name" "$name" "$REGION" "$arn" "active" \
      "Runtime=${runtime},Handler=${handler},Memory=${memory}MB,Timeout=${timeout}s"
    write_tf_stub "lambda" "aws_lambda_function" "$name" \
      "$(sanitise_label "lambda_${name}")" "$REGION" \
      "  function_name = \"${name}\"\n  runtime       = \"${runtime}\"\n  handler       = \"${handler}\"\n  memory_size   = ${memory}\n  timeout       = ${timeout}"
    ((COUNT++)) || true
  done < <(aws_region "$REGION" lambda list-functions | jq -c '.Functions[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} Lambda functions"

  # ── ECS Clusters ──────────────────────────────────────────────────────────
  log_section "ECS Clusters"
  COUNT=0
  ECS_ARNS=$(aws_region "$REGION" ecs list-clusters | jq -r '.clusterArns[]?' 2>/dev/null || true)
  if [[ -n "$ECS_ARNS" ]]; then
    while IFS= read -r cluster; do
      [[ -z "$cluster" || "$cluster" == "null" ]] && continue
      name=$(echo "$cluster"   | jq -r '.clusterName // ""'); [[ -z "$name" ]] && continue
      arn=$(echo "$cluster"    | jq -r '.clusterArn // ""')
      status=$(echo "$cluster" | jq -r '.status // ""')
      svcs=$(echo "$cluster"   | jq -r '.activeServicesCount // 0')
      add_csv "ECS Cluster" "$name" "$name" "$REGION" "$arn" "$status" \
        "ActiveServices=${svcs}"
      write_tf_stub "ecs" "aws_ecs_cluster" "$name" \
        "$(sanitise_label "ecs_${name}")" "$REGION" \
        "  name = \"${name}\""
      ((COUNT++)) || true
    done < <(aws_region "$REGION" ecs describe-clusters --clusters $ECS_ARNS \
      | jq -c '.clusters[]?' 2>/dev/null || true)
  fi
  echo -e "  ${GREEN}✓${NC} ${COUNT} ECS clusters"

  # ── EKS Clusters ──────────────────────────────────────────────────────────
  log_section "EKS Clusters"
  COUNT=0
  while IFS= read -r cluster_name; do
    [[ -z "$cluster_name" || "$cluster_name" == "null" ]] && continue
    DETAIL=$(aws_region "$REGION" eks describe-cluster --name "$cluster_name" \
      | jq -c '.cluster' 2>/dev/null || echo "null")
    [[ "$DETAIL" == "null" ]] && continue
    arn=$(echo "$DETAIL"     | jq -r '.arn // ""')
    status=$(echo "$DETAIL"  | jq -r '.status // ""')
    version=$(echo "$DETAIL" | jq -r '.version // ""')
    add_csv "EKS Cluster" "$cluster_name" "$cluster_name" "$REGION" "$arn" "$status" \
      "K8sVersion=${version}"
    write_tf_stub "eks" "aws_eks_cluster" "$cluster_name" \
      "$(sanitise_label "eks_${cluster_name}")" "$REGION" \
      "  name    = \"${cluster_name}\"\n  version = \"${version}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" eks list-clusters | jq -r '.clusters[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} EKS clusters"

  # ── ElastiCache ───────────────────────────────────────────────────────────
  log_section "ElastiCache Clusters"
  COUNT=0
  while IFS= read -r c; do
    [[ -z "$c" || "$c" == "null" ]] && continue
    id=$(echo "$c"      | jq -r '.CacheClusterId // ""'); [[ -z "$id" ]] && continue
    engine=$(echo "$c"  | jq -r '.Engine // ""')
    version=$(echo "$c" | jq -r '.EngineVersion // ""')
    node=$(echo "$c"    | jq -r '.CacheNodeType // ""')
    status=$(echo "$c"  | jq -r '.CacheClusterStatus // ""')
    arn=$(echo "$c"     | jq -r '.ARN // ""')
    add_csv "ElastiCache" "$id" "$id" "$REGION" "$arn" "$status" \
      "Engine=${engine} ${version},NodeType=${node}"
    write_tf_stub "elasticache" "aws_elasticache_cluster" "$id" \
      "$(sanitise_label "cache_${id}")" "$REGION" \
      "  cluster_id  = \"${id}\"\n  engine      = \"${engine}\"\n  node_type   = \"${node}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" elasticache describe-cache-clusters | jq -c '.CacheClusters[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} ElastiCache clusters"

  # ── DynamoDB Tables ───────────────────────────────────────────────────────
  log_section "DynamoDB Tables"
  COUNT=0
  while IFS= read -r table; do
    [[ -z "$table" || "$table" == "null" ]] && continue
    DETAIL=$(aws_region "$REGION" dynamodb describe-table --table-name "$table" \
      | jq -c '.Table' 2>/dev/null || echo "null")
    [[ "$DETAIL" == "null" ]] && continue
    status=$(echo "$DETAIL"  | jq -r '.TableStatus // ""')
    arn=$(echo "$DETAIL"     | jq -r '.TableArn // ""')
    billing=$(echo "$DETAIL" | jq -r '.BillingModeSummary.BillingMode // "PROVISIONED"')
    add_csv "DynamoDB Table" "$table" "$table" "$REGION" "$arn" "$status" \
      "Billing=${billing}"
    write_tf_stub "dynamodb" "aws_dynamodb_table" "$table" \
      "$(sanitise_label "ddb_${table}")" "$REGION" \
      "  name         = \"${table}\"\n  billing_mode = \"${billing}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" dynamodb list-tables | jq -r '.TableNames[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} DynamoDB tables"

  # ── SNS Topics ────────────────────────────────────────────────────────────
  log_section "SNS Topics"
  COUNT=0
  while IFS= read -r arn; do
    [[ -z "$arn" || "$arn" == "null" ]] && continue
    name=$(basename "$arn")
    add_csv "SNS Topic" "$arn" "$name" "$REGION" "$arn" "active" ""
    write_tf_stub "sns" "aws_sns_topic" "$arn" \
      "$(sanitise_label "sns_${name}")" "$REGION" \
      "  name = \"${name}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" sns list-topics | jq -r '.Topics[].TopicArn?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} SNS topics"

  # ── SQS Queues ────────────────────────────────────────────────────────────
  log_section "SQS Queues"
  COUNT=0
  while IFS= read -r url; do
    [[ -z "$url" || "$url" == "null" ]] && continue
    name=$(basename "$url")
    arn="arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${name}"
    add_csv "SQS Queue" "$url" "$name" "$REGION" "$arn" "active" ""
    write_tf_stub "sqs" "aws_sqs_queue" "$url" \
      "$(sanitise_label "sqs_${name}")" "$REGION" \
      "  name = \"${name}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" sqs list-queues | jq -r '.QueueUrls[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} SQS queues"

  # ── Secrets Manager ───────────────────────────────────────────────────────
  log_section "Secrets Manager"
  COUNT=0
  while IFS= read -r secret; do
    [[ -z "$secret" || "$secret" == "null" ]] && continue
    name=$(echo "$secret" | jq -r '.Name // ""'); [[ -z "$name" ]] && continue
    arn=$(echo "$secret"  | jq -r '.ARN // ""')
    add_csv "Secret" "$name" "$name" "$REGION" "$arn" "active" ""
    write_tf_stub "secretsmanager" "aws_secretsmanager_secret" "$name" \
      "$(sanitise_label "secret_${name}")" "$REGION" \
      "  name = \"${name}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" secretsmanager list-secrets | jq -c '.SecretList[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} secrets"

  # ── SSM Parameters ────────────────────────────────────────────────────────
  log_section "SSM Parameters"
  COUNT=0
  while IFS= read -r param; do
    [[ -z "$param" || "$param" == "null" ]] && continue
    name=$(echo "$param" | jq -r '.Name // ""'); [[ -z "$name" ]] && continue
    type=$(echo "$param" | jq -r '.Type // ""')
    arn="arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${name}"
    add_csv "SSM Parameter" "$name" "$name" "$REGION" "$arn" "active" "Type=${type}"
    write_tf_stub "ssm" "aws_ssm_parameter" "$name" \
      "$(sanitise_label "param_${name}")" "$REGION" \
      "  name = \"${name}\"\n  type = \"${type}\""
    ((COUNT++)) || true
  done < <(aws_region "$REGION" ssm describe-parameters | jq -c '.Parameters[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} SSM parameters"

done  # end regions loop

# =============================================================================
# SUMMARY
# =============================================================================

TF_FILE_COUNT=$(find "${TF_DIR}" -name "*.tf" 2>/dev/null | wc -l | tr -d ' ')

cat > "${SUMMARY_FILE}" <<SUMMARY
AWS Infrastructure Inventory Summary
=====================================
Account ID   : ${ACCOUNT_ID}
Generated    : ${TIMESTAMP}
Profile      : ${PROFILE}
Regions      : ${REGIONS[*]}
Total Resources: ${TOTAL_RESOURCES}

Outputs
-------
CSV  : ${CSV_FILE}
TF   : ${TF_DIR}/ (${TF_FILE_COUNT} .tf files)

Next Steps
----------
1. Review CSV to prioritise migration order
2. Per resource, run: terraform import <resource>.<label> <id>
3. Run: terraform plan  (to see drift)
4. Fill # TODO attributes in each stub
5. Commit to git and enable remote state (S3 + DynamoDB lock)
SUMMARY

echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}  ✓ Inventory complete! ${TOTAL_RESOURCES} resources found.${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  CSV             : ${CYAN}${CSV_FILE}${NC}"
echo -e "  Terraform stubs : ${CYAN}${TF_DIR}/${NC}"
echo -e "  Summary         : ${CYAN}${SUMMARY_FILE}${NC}"
echo ""
