#!/usr/bin/env bash
umask 022  # Ensure all created files/dirs are world-readable
# =============================================================================
# Azure Infrastructure Inventory Script  (v2 — full attrs + import blocks)
# Discovers resources across your Azure subscription and outputs:
#   1. CSV            → <out>/azure_inventory_<timestamp>.csv
#   2. Terraform HCL stubs (resource blocks) → <out>/terraform_stubs/
#   3. Terraform import blocks (HCL, TF ≥ 1.5) → <out>/terraform_stubs/imports.tf
# =============================================================================
# REQUIREMENTS: azure-cli (az), jq
# USAGE:
#   chmod +x azure_inventory.sh
#   ./azure_inventory.sh                                    # current subscription
#   ./azure_inventory.sh --subscription <id-or-name>        # named subscription
#   ./azure_inventory.sh --resource-group <rg>              # limit to one RG
#   ./azure_inventory.sh --all-subscriptions                # scan every subscription
#   ./azure_inventory.sh --no-import-blocks                 # skip imports.tf
# =============================================================================

set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
SUBSCRIPTION=""
RESOURCE_GROUP=""
ALL_SUBSCRIPTIONS=false
IMPORT_BLOCKS=true
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="$(pwd)/azure_inventory_${TIMESTAMP}"
CSV_FILE="${OUT_DIR}/azure_inventory_${TIMESTAMP}.csv"
TF_DIR="${OUT_DIR}/terraform_stubs"
IMPORTS_FILE="${TF_DIR}/imports.tf"
SUMMARY_FILE="${OUT_DIR}/summary_${TIMESTAMP}.txt"
TOTAL_RESOURCES=0
SUBSCRIPTION_IDS=()

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --subscription)      SUBSCRIPTION="$2";      shift 2 ;;
    --resource-group)    RESOURCE_GROUP="$2";    shift 2 ;;
    --all-subscriptions) ALL_SUBSCRIPTIONS=true; shift   ;;
    --no-import-blocks)  IMPORT_BLOCKS=false;    shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Prerequisites ─────────────────────────────────────────────────────────────
for cmd in az jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}ERROR: '$cmd' is required but not installed.${NC}"
    exit 1
  fi
done

# ── Helper: safe az calls — never exit on error ───────────────────────────────
az_safe() {
  az "$@" --output json 2>/dev/null || echo "null"
}

az_sub() {
  local sub="$1"; shift
  az "$@" --subscription "$sub" --output json 2>/dev/null || echo "null"
}

az_sub_rg() {
  local sub="$1" rg="$2"; shift 2
  if [[ -n "$rg" ]]; then
    az "$@" --subscription "$sub" --resource-group "$rg" --output json 2>/dev/null || echo "null"
  else
    az "$@" --subscription "$sub" --output json 2>/dev/null || echo "null"
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────
log_section() { echo -e "\n${BOLD}${YELLOW}▶ $1${NC}"; }

add_csv() {
  local type="$1" id="$2" name="$3" location="$4" resource_id="$5" state="$6" attrs="$7"
  attrs="${attrs//\"/\'}"
  (
    flock 9
    echo "\"${type}\",\"${id}\",\"${name}\",\"${location}\",\"${resource_id}\",\"${state}\",\"${attrs}\"" >> "${CSV_FILE}"
  ) 9>"${CSV_FILE}.lock"
  ((TOTAL_RESOURCES++)) || true
}

sanitise_label() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | sed 's/^[0-9]/_&/' | cut -c1-60
}

# Render a JSON tags object {Key:Value,...} as HCL tags = { key = "value" }
render_tags_hcl() {
  local tags_json="$1"
  local out
  out=$(echo "$tags_json" | jq -r '
    if . != null and (. | length) > 0 then
      "  tags = {\n" +
      (to_entries | map("    \(.key) = \"\(.value)\"") | join("\n")) +
      "\n  }"
    else ""
    end
  ' 2>/dev/null || true)
  echo "$out"
}

# Write resource stub to per-service .tf file (flock-safe for parallel use)
write_tf_stub() {
  local service="$1" resource="$2" id="$3" label="$4" location="$5" attrs="${6:-}"
  local tf_file="${TF_DIR}/${service}.tf"
  (
    flock 9
    if [[ ! -f "$tf_file" ]]; then
      cat >> "$tf_file" <<EOF
# Auto-generated Terraform stubs — Subscription: ${SUBSCRIPTION_ID} — ${TIMESTAMP}

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

# Combined: stub + import block
emit_resource() {
  # emit_resource SERVICE TF_RESOURCE AZURE_ID LABEL LOCATION ATTRS
  write_tf_stub      "$1" "$2" "$3" "$4" "$5" "${6:-}"
  write_import_block "$2" "$4" "$3"
}

# ── Auth check ────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│   Azure Infrastructure Inventory Tool  (v2)     │${NC}"
echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────┘${NC}"
echo ""

IDENTITY=$(az_safe account show)
if [[ "$IDENTITY" == "null" ]]; then
  echo -e "${RED}ERROR: Could not authenticate. Run 'az login' first.${NC}"
  exit 1
fi

TENANT_ID=$(echo "$IDENTITY"  | jq -r '.tenantId')
CALLER_USER=$(echo "$IDENTITY" | jq -r '.user.name // .user.type')
echo -e "${GREEN}✓ Authenticated${NC}"
echo -e "  Tenant  : ${BOLD}${TENANT_ID}${NC}"
echo -e "  Identity: ${CALLER_USER}"
echo ""

# ── Resolve subscriptions ─────────────────────────────────────────────────────
if $ALL_SUBSCRIPTIONS; then
  mapfile -t SUBSCRIPTION_IDS < <(az_safe account list --query '[].id' | jq -r '.[]' | sort)
elif [[ -n "$SUBSCRIPTION" ]]; then
  SUBSCRIPTION_IDS=("$SUBSCRIPTION")
else
  DEFAULT_SUB=$(echo "$IDENTITY" | jq -r '.id')
  SUBSCRIPTION_IDS=("${DEFAULT_SUB}")
fi

echo -e "Scanning ${BOLD}${#SUBSCRIPTION_IDS[@]}${NC} subscription(s)"
$IMPORT_BLOCKS && echo -e "Import blocks : ${GREEN}enabled${NC} (imports.tf)" \
               || echo -e "Import blocks : ${YELLOW}disabled${NC}"
echo ""

# ── Setup output ──────────────────────────────────────────────────────────────
mkdir -p "${TF_DIR}"
echo "ResourceType,ResourceID,Name,Location,AzureResourceID,State,AdditionalAttributes" > "${CSV_FILE}"

# Generate single main.tf with terraform + provider blocks
# This runs once per subscription; if scanning multiple subscriptions the last one wins —
# adjust manually if you need a multi-subscription setup.
cat > "${TF_DIR}/main.tf" <<MAINTF
# Main Terraform configuration — Tenant: ${TENANT_ID} — ${TIMESTAMP}
# This is the single entry point. All other .tf files contain only resource blocks.
#
# Usage:
#   terraform init
#   terraform plan -generate-config-out=generated.tf
#   terraform apply

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.0" }
    azuread = { source = "hashicorp/azuread", version = "~> 2.0" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "${SUBSCRIPTION_ID}"
}

provider "azuread" {
  tenant_id = "${TENANT_ID}"
}
MAINTF
echo -e "  ${GREEN}✓${NC} main.tf written to ${TF_DIR}/main.tf"

if $IMPORT_BLOCKS; then
  cat > "${IMPORTS_FILE}" <<EOF
# Terraform import blocks — Tenant: ${TENANT_ID} — ${TIMESTAMP}
# Requires Terraform >= 1.5
# Usage:
#   terraform init
#   terraform plan -generate-config-out=generated.tf
#   terraform apply

EOF
fi

# =============================================================================
# PER-SUBSCRIPTION LOOP
# =============================================================================

for SUB_ID in "${SUBSCRIPTION_IDS[@]}"; do

  SUBSCRIPTION_ID="$SUB_ID"
  SUB_DETAIL=$(az_sub "$SUB_ID" account show)
  SUB_NAME=$(echo "$SUB_DETAIL" | jq -r '.name // "unknown"')
  SUB_STATE=$(echo "$SUB_DETAIL" | jq -r '.state // ""')

  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  Subscription: ${SUB_NAME} (${SUB_ID})${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # ── Resource Groups ────────────────────────────────────────────────────────
  log_section "Resource Groups"
  COUNT=0
  RG_FILTER_ARGS=()
  [[ -n "$RESOURCE_GROUP" ]] && RG_FILTER_ARGS=(--name "$RESOURCE_GROUP")
  while IFS= read -r rg; do
    [[ -z "$rg" || "$rg" == "null" ]] && continue
    name=$(echo "$rg"  | jq -r '.name // ""');      [[ -z "$name" ]] && continue
    loc=$(echo "$rg"   | jq -r '.location // ""')
    state=$(echo "$rg" | jq -r '.properties.provisioningState // ""')
    rid=$(echo "$rg"   | jq -r '.id // ""')
    tags=$(echo "$rg"  | jq -c '.tags // {}')
    tags_hcl=$(render_tags_hcl "$tags")
    managed_by=$(echo "$rg" | jq -r '.managedBy // ""')

    add_csv "Resource Group" "$name" "$name" "$loc" "$rid" "$state" \
      "ManagedBy=${managed_by}"

    attrs="  name     = \"${name}\"\n  location = \"${loc}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "resource_groups" "azurerm_resource_group" "$rid" \
      "$(sanitise_label "rg_${name}")" "$loc" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" group list "${RG_FILTER_ARGS[@]}" | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} resource groups"

  # Determine which RGs to iterate over
  if [[ -n "$RESOURCE_GROUP" ]]; then
    RESOURCE_GROUPS=("$RESOURCE_GROUP")
  else
    mapfile -t RESOURCE_GROUPS < <(az_sub "$SUB_ID" group list --query '[].name' \
      | jq -r '.[]' 2>/dev/null | sort || true)
  fi

  # =============================================================================
  # GLOBAL / SUBSCRIPTION-LEVEL RESOURCES
  # =============================================================================

  # ── Entra ID (AAD) Users ────────────────────────────────────────────────────
  log_section "Entra ID Users"
  COUNT=0
  while IFS= read -r user; do
    [[ -z "$user" || "$user" == "null" ]] && continue
    upn=$(echo "$user"         | jq -r '.userPrincipalName // ""'); [[ -z "$upn" ]] && continue
    oid=$(echo "$user"         | jq -r '.id // ""')
    display=$(echo "$user"     | jq -r '.displayName // ""')
    given=$(echo "$user"       | jq -r '.givenName // ""')
    surname=$(echo "$user"     | jq -r '.surname // ""')
    mail=$(echo "$user"        | jq -r '.mail // ""')
    account_enabled=$(echo "$user" | jq -r '.accountEnabled // true')
    user_type=$(echo "$user"   | jq -r '.userType // "Member"')

    add_csv "Entra ID User" "$oid" "$display" "global" "/users/${oid}" "active" \
      "UPN=${upn},Type=${user_type},AccountEnabled=${account_enabled},Mail=${mail}"

    attrs="  user_principal_name = \"${upn}\"\n  display_name        = \"${display}\"\n\n  password_profile {\n    password                      = \"# TODO: set via sensitive tfvar — never hardcode\"\n    force_password_change_on_next_login = false\n  }"
    [[ -n "$given" ]]   && attrs="${attrs}\n  given_name          = \"${given}\""
    [[ -n "$surname" ]] && attrs="${attrs}\n  surname             = \"${surname}\""
    [[ -n "$mail" ]]    && attrs="${attrs}\n  mail                = \"${mail}\""
    attrs="${attrs}\n  account_enabled     = ${account_enabled}"

    emit_resource "entra_users" "azuread_user" "$oid" \
      "$(sanitise_label "user_${display}")" "global" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(az_safe ad user list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} Entra ID users"

  # ── Entra ID Service Principals ─────────────────────────────────────────────
  log_section "Entra ID Service Principals"
  COUNT=0
  while IFS= read -r sp; do
    [[ -z "$sp" || "$sp" == "null" ]] && continue
    oid=$(echo "$sp"          | jq -r '.id // ""');      [[ -z "$oid" ]] && continue
    name=$(echo "$sp"         | jq -r '.displayName // ""')
    sp_type=$(echo "$sp"      | jq -r '.servicePrincipalType // ""')
    app_id=$(echo "$sp"       | jq -r '.appId // ""')
    enabled=$(echo "$sp"      | jq -r '.accountEnabled // true')
    sign_in=$(echo "$sp"      | jq -r '.signInAudience // ""')
    homepage=$(echo "$sp"     | jq -r '.homepage // ""')

    add_csv "Service Principal" "$oid" "$name" "global" "/servicePrincipals/${oid}" "active" \
      "Type=${sp_type},AppId=${app_id},Enabled=${enabled}"

    attrs="  display_name = \"${name}\"\n  client_id    = \"${app_id}\"  # application (client) ID of the associated app registration"
    [[ -n "$homepage" ]] && attrs="${attrs}\n  # homepage_url = \"${homepage}\""

    emit_resource "entra_service_principals" "azuread_service_principal" "$oid" \
      "$(sanitise_label "sp_${name}")" "global" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(az_safe ad sp list --all | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} service principals"

  # ── Role Assignments ────────────────────────────────────────────────────────
  log_section "Role Assignments (subscription scope)"
  COUNT=0
  while IFS= read -r ra; do
    [[ -z "$ra" || "$ra" == "null" ]] && continue
    id=$(echo "$ra"           | jq -r '.id // ""');         [[ -z "$id" ]] && continue
    principal_id=$(echo "$ra" | jq -r '.principalId // ""')
    principal=$(echo "$ra"    | jq -r '.principalName // .principalId // ""')
    role=$(echo "$ra"         | jq -r '.roleDefinitionName // ""')
    role_def_id=$(echo "$ra"  | jq -r '.roleDefinitionId // ""')
    scope=$(echo "$ra"        | jq -r '.scope // ""')
    principal_type=$(echo "$ra" | jq -r '.principalType // ""')
    condition=$(echo "$ra"    | jq -r '.condition // ""')

    add_csv "Role Assignment" "$id" "${role} → ${principal}" "global" "$id" "active" \
      "Role=${role},Principal=${principal},PrincipalType=${principal_type},Scope=${scope}"

    attrs="  role_definition_name = \"${role}\"\n  principal_id         = \"${principal_id}\"\n  scope                = \"${scope}\""
    [[ -n "$condition" ]] && attrs="${attrs}\n  condition            = \"${condition}\"\n  condition_version    = \"2.0\""

    emit_resource "role_assignments" "azurerm_role_assignment" "$id" \
      "$(sanitise_label "ra_${role}_${principal}")" "global" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" role assignment list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} role assignments"

  # ── DNS Zones ───────────────────────────────────────────────────────────────
  log_section "DNS Zones"
  COUNT=0
  while IFS= read -r zone; do
    [[ -z "$zone" || "$zone" == "null" ]] && continue
    name=$(echo "$zone"    | jq -r '.name // ""');  [[ -z "$name" ]] && continue
    rid=$(echo "$zone"     | jq -r '.id // ""')
    rg=$(echo "$zone"      | jq -r '.resourceGroup // ""')
    rcount=$(echo "$zone"  | jq -r '.numberOfRecordSets // 0')
    ns=$(echo "$zone"      | jq -r '[.nameServers[]?] | join(",")' 2>/dev/null || true)
    tags=$(echo "$zone"    | jq -c '.tags // {}')
    tags_hcl=$(render_tags_hcl "$tags")
    zone_type=$(echo "$zone" | jq -r '.zoneType // "Public"')

    add_csv "DNS Zone" "$name" "$name" "global" "$rid" "active" \
      "ResourceGroup=${rg},RecordSets=${rcount},NameServers=${ns},ZoneType=${zone_type}"

    attrs="  name                = \"${name}\"\n  resource_group_name = \"${rg}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "dns" "azurerm_dns_zone" "$rid" \
      "$(sanitise_label "dns_${name}")" "global" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" network dns zone list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} DNS zones"

  # ── CDN Profiles ────────────────────────────────────────────────────────────
  log_section "CDN Profiles"
  COUNT=0
  while IFS= read -r cdn; do
    [[ -z "$cdn" || "$cdn" == "null" ]] && continue
    name=$(echo "$cdn"   | jq -r '.name // ""');  [[ -z "$name" ]] && continue
    rid=$(echo "$cdn"    | jq -r '.id // ""')
    rg=$(echo "$cdn"     | jq -r '.resourceGroup // ""')
    sku=$(echo "$cdn"    | jq -r '.sku.name // ""')
    state=$(echo "$cdn"  | jq -r '.resourceState // ""')
    origin_groups=$(echo "$cdn" | jq -r '.originGroups | length' 2>/dev/null || echo "0")
    tags=$(echo "$cdn"   | jq -c '.tags // {}')
    tags_hcl=$(render_tags_hcl "$tags")

    add_csv "CDN Profile" "$name" "$name" "global" "$rid" "$state" \
      "SKU=${sku},ResourceGroup=${rg},OriginGroups=${origin_groups}"

    attrs="  name                = \"${name}\"\n  resource_group_name = \"${rg}\"\n  location            = \"global\"\n  sku                 = \"${sku}\""
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "cdn" "azurerm_cdn_profile" "$rid" \
      "$(sanitise_label "cdn_${name}")" "global" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" cdn profile list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} CDN profiles"

  # ── Key Vaults (subscription-wide) ─────────────────────────────────────────
  log_section "Key Vaults"
  COUNT=0
  while IFS= read -r kv; do
    [[ -z "$kv" || "$kv" == "null" ]] && continue
    name=$(echo "$kv"   | jq -r '.name // ""');  [[ -z "$name" ]] && continue
    rid=$(echo "$kv"    | jq -r '.id // ""')
    rg=$(echo "$kv"     | jq -r '.resourceGroup // ""')
    loc=$(echo "$kv"    | jq -r '.location // ""')

    # Fetch full properties
    DETAIL=$(az_sub "$SUB_ID" keyvault show --name "$name" --resource-group "$rg" 2>/dev/null || echo "null")
    [[ "$DETAIL" == "null" ]] && DETAIL="{}"

    sku=$(echo "$DETAIL"            | jq -r '.properties.sku.name // "standard"')
    soft_delete=$(echo "$DETAIL"    | jq -r '.properties.enableSoftDelete // true')
    purge_protect=$(echo "$DETAIL"  | jq -r '.properties.enablePurgeProtection // false')
    rbac_auth=$(echo "$DETAIL"      | jq -r '.properties.enableRbacAuthorization // false')
    retention=$(echo "$DETAIL"      | jq -r '.properties.softDeleteRetentionInDays // 90')
    public_net=$(echo "$DETAIL"     | jq -r '.properties.publicNetworkAccess // "Enabled"')
    default_action=$(echo "$DETAIL" | jq -r '.properties.networkAcls.defaultAction // "Allow"')
    tags=$(echo "$DETAIL"           | jq -c '.tags // {}')
    tags_hcl=$(render_tags_hcl "$tags")

    add_csv "Key Vault" "$name" "$name" "$loc" "$rid" "active" \
      "ResourceGroup=${rg},SKU=${sku},SoftDelete=${soft_delete},PurgeProtection=${purge_protect},RBAC=${rbac_auth}"

    attrs="  name                            = \"${name}\"\n  resource_group_name             = \"${rg}\"\n  location                        = \"${loc}\"\n  tenant_id                       = \"${TENANT_ID}\"\n  sku_name                        = \"${sku}\"\n  soft_delete_retention_days      = ${retention}\n  enable_rbac_authorization       = ${rbac_auth}\n  purge_protection_enabled        = ${purge_protect}\n  public_network_access_enabled   = $([ "$public_net" == "Enabled" ] && echo true || echo false)"
    [[ "$default_action" != "Allow" ]] && \
      attrs="${attrs}\n\n  network_acls {\n    default_action = \"${default_action}\"\n    bypass         = \"AzureServices\"\n  }"
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "keyvault" "azurerm_key_vault" "$rid" \
      "$(sanitise_label "kv_${name}")" "$loc" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" keyvault list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} key vaults"

  # ── Storage Accounts (subscription-wide) ────────────────────────────────────
  log_section "Storage Accounts"
  COUNT=0
  while IFS= read -r sa; do
    [[ -z "$sa" || "$sa" == "null" ]] && continue
    name=$(echo "$sa"   | jq -r '.name // ""');   [[ -z "$name" ]] && continue
    rid=$(echo "$sa"    | jq -r '.id // ""')
    rg=$(echo "$sa"     | jq -r '.resourceGroup // ""')
    loc=$(echo "$sa"    | jq -r '.location // ""')
    kind=$(echo "$sa"   | jq -r '.kind // ""')
    sku=$(echo "$sa"    | jq -r '.sku.name // ""')
    state=$(echo "$sa"  | jq -r '.provisioningState // ""')
    access_tier=$(echo "$sa"       | jq -r '.accessTier // "Hot"')
    https_only=$(echo "$sa"        | jq -r '.enableHttpsTrafficOnly // true')
    hns=$(echo "$sa"               | jq -r '.isHnsEnabled // false')
    min_tls=$(echo "$sa"           | jq -r '.minimumTlsVersion // "TLS1_2"')
    public_access=$(echo "$sa"     | jq -r '.allowBlobPublicAccess // false')
    shared_key=$(echo "$sa"        | jq -r '.allowSharedKeyAccess // true')
    default_action=$(echo "$sa"    | jq -r '.networkRuleSet.defaultAction // "Allow"')
    large_file=$(echo "$sa"        | jq -r '.largeFileSharesState // ""')
    blob_versioning=$(echo "$sa"   | jq -r '.blobServiceProperties.isVersioningEnabled // false' 2>/dev/null || echo "false")
    tags=$(echo "$sa"              | jq -c '.tags // {}')
    tags_hcl=$(render_tags_hcl "$tags")

    # Parse SKU into tier + replication
    acct_tier=$(echo "$sku" | sed 's/_.*//')                    # Standard / Premium
    replication=$(echo "$sku" | sed 's/^[^_]*_//')              # LRS / GRS / ZRS / etc.

    add_csv "Storage Account" "$name" "$name" "$loc" "$rid" "$state" \
      "Kind=${kind},SKU=${sku},AccessTier=${access_tier},HNS=${hns},HttpsOnly=${https_only},MinTLS=${min_tls},PublicAccess=${public_access}"

    attrs="  name                              = \"${name}\"\n  resource_group_name               = \"${rg}\"\n  location                          = \"${loc}\"\n  account_kind                      = \"${kind}\"\n  account_tier                      = \"${acct_tier}\"\n  account_replication_type          = \"${replication}\"\n  access_tier                       = \"${access_tier}\"\n  https_traffic_only_enabled        = ${https_only}\n  is_hns_enabled                    = ${hns}\n  min_tls_version                   = \"${min_tls}\"\n  allow_nested_items_to_be_public   = ${public_access}\n  shared_access_key_enabled         = ${shared_key}"
    [[ -n "$large_file" && "$large_file" != "null" ]] && \
      attrs="${attrs}\n  large_file_share_enabled          = $([ "$large_file" == "Enabled" ] && echo true || echo false)"
    if [[ "$default_action" == "Deny" ]]; then
      attrs="${attrs}\n\n  network_rules {\n    default_action = \"Deny\"\n    bypass         = [\"AzureServices\"]\n  }"
    fi
    [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

    emit_resource "storage" "azurerm_storage_account" "$rid" \
      "$(sanitise_label "sa_${name}")" "$loc" "$(printf '%b' "$attrs")"
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" storage account list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} storage accounts"

  # =============================================================================
  # PER-RESOURCE-GROUP RESOURCES
  # =============================================================================

  for RG in "${RESOURCE_GROUPS[@]}"; do
    echo ""
    echo -e "${BOLD}${CYAN}  ─── Resource Group: ${RG} ───${NC}"

    # ── Virtual Networks ───────────────────────────────────────────────────────
    log_section "Virtual Networks [${RG}]"
    COUNT=0
    while IFS= read -r vnet; do
      [[ -z "$vnet" || "$vnet" == "null" ]] && continue
      name=$(echo "$vnet"    | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$vnet"     | jq -r '.id // ""')
      loc=$(echo "$vnet"     | jq -r '.location // ""')
      state=$(echo "$vnet"   | jq -r '.provisioningState // ""')
      prefixes=$(echo "$vnet" | jq -r '[.addressSpace.addressPrefixes[]?] | join(",")' 2>/dev/null || true)
      dns_servers=$(echo "$vnet" | jq -r '[.dhcpOptions.dnsServers[]?] | join(",")' 2>/dev/null || true)
      ddos_plan=$(echo "$vnet"   | jq -r '.ddosProtectionPlan.id // ""')
      ddos_enabled=$(echo "$vnet" | jq -r '.enableDdosProtection // false')
      vm_protection=$(echo "$vnet" | jq -r '.enableVmProtection // false')
      peering_count=$(echo "$vnet" | jq '.virtualNetworkPeerings | length' 2>/dev/null || echo 0)
      tags=$(echo "$vnet"    | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Virtual Network" "$name" "$name" "$loc" "$rid" "$state" \
        "AddressSpace=${prefixes},DNSServers=${dns_servers},DDosEnabled=${ddos_enabled},Peerings=${peering_count},ResourceGroup=${RG}"

      # Format address_space as HCL list
      addr_list=$(echo "$prefixes" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
      attrs="  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  address_space       = [${addr_list}]"
      if [[ -n "$dns_servers" ]]; then
        dns_list=$(echo "$dns_servers" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        attrs="${attrs}\n  dns_servers         = [${dns_list}]"
      fi
      [[ "$ddos_enabled" == "true" && -n "$ddos_plan" ]] && \
        attrs="${attrs}\n\n  ddos_protection_plan {\n    id     = \"${ddos_plan}\"\n    enable = true\n  }"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "networking" "azurerm_virtual_network" "$rid" \
        "$(sanitise_label "vnet_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network vnet list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} virtual networks"

    # ── Subnets ────────────────────────────────────────────────────────────────
    log_section "Subnets [${RG}]"
    COUNT=0
    VNETS_IN_RG=$(az_sub_rg "$SUB_ID" "$RG" network vnet list \
      | jq -r '.[].name' 2>/dev/null || true)
    while IFS= read -r vnet_name; do
      [[ -z "$vnet_name" ]] && continue
      while IFS= read -r subnet; do
        [[ -z "$subnet" || "$subnet" == "null" ]] && continue
        sname=$(echo "$subnet"       | jq -r '.name // ""');      [[ -z "$sname" ]] && continue
        rid=$(echo "$subnet"         | jq -r '.id // ""')
        prefix=$(echo "$subnet"      | jq -r '.addressPrefix // ""')
        prefixes=$(echo "$subnet"    | jq -r '[.addressPrefixes[]?] | join(",")' 2>/dev/null || echo "$prefix")
        nsg_id=$(echo "$subnet"      | jq -r '.networkSecurityGroup.id // ""')
        rt_id=$(echo "$subnet"       | jq -r '.routeTable.id // ""')
        delegations=$(echo "$subnet" | jq -r '[.delegations[]?.properties.serviceName] | join(",")' 2>/dev/null || true)
        private_ep=$(echo "$subnet"  | jq -r '.privateEndpointNetworkPolicies // "Enabled"')
        private_lnk=$(echo "$subnet" | jq -r '.privateLinkServiceNetworkPolicies // "Enabled"')
        service_eps=$(echo "$subnet" | jq -r '[.serviceEndpoints[]?.service] | join(",")' 2>/dev/null || true)

        add_csv "Subnet" "${vnet_name}/${sname}" "$sname" "regional" "$rid" "active" \
          "VNet=${vnet_name},Prefix=${prefixes},NSG=${nsg_id},RouteTable=${rt_id},Delegations=${delegations},ServiceEndpoints=${service_eps},ResourceGroup=${RG}"

        addr_list=$(echo "${prefixes:-$prefix}" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        attrs="  name                                          = \"${sname}\"\n  resource_group_name                           = \"${RG}\"\n  virtual_network_name                          = \"${vnet_name}\"\n  address_prefixes                              = [${addr_list}]\n  private_endpoint_network_policies             = \"${private_ep}\"\n  private_link_service_network_policies_enabled = $([ "$private_lnk" == "Disabled" ] && echo false || echo true)"
        [[ -n "$nsg_id" ]]    && attrs="${attrs}\n  # network_security_group_id via azurerm_subnet_network_security_group_association"
        [[ -n "$rt_id" ]]     && attrs="${attrs}\n  # route_table_id via azurerm_subnet_route_table_association"
        if [[ -n "$service_eps" ]]; then
          ep_list=$(echo "$service_eps" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
          attrs="${attrs}\n  service_endpoints = [${ep_list}]"
        fi
        if [[ -n "$delegations" ]]; then
          attrs="${attrs}\n\n  delegation {\n    name = \"delegation\"\n    service_delegation {\n      name = \"${delegations%%,*}\"\n    }\n  }"
        fi

        emit_resource "networking" "azurerm_subnet" "$rid" \
          "$(sanitise_label "subnet_${vnet_name}_${sname}")" "regional" "$(printf '%b' "$attrs")"
        ((COUNT++)) || true
      done < <(az_sub "$SUB_ID" network vnet subnet list \
          --vnet-name "$vnet_name" --resource-group "$RG" \
          --output json 2>/dev/null | jq -c '.[]?' || true)
    done <<< "$VNETS_IN_RG"
    echo -e "  ${GREEN}✓${NC} ${COUNT} subnets"

    # ── Network Security Groups ────────────────────────────────────────────────
    log_section "Network Security Groups [${RG}]"
    COUNT=0
    while IFS= read -r nsg; do
      [[ -z "$nsg" || "$nsg" == "null" ]] && continue
      name=$(echo "$nsg"   | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$nsg"    | jq -r '.id // ""')
      loc=$(echo "$nsg"    | jq -r '.location // ""')
      state=$(echo "$nsg"  | jq -r '.provisioningState // ""')
      tags=$(echo "$nsg"   | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      # Summarise security rules
      custom_rules=$(echo "$nsg"  | jq '.securityRules | length' 2>/dev/null || echo 0)
      default_rules=$(echo "$nsg" | jq '.defaultSecurityRules | length' 2>/dev/null || echo 0)

      # Emit individual security rules
      echo "$nsg" | jq -c '.securityRules[]?' 2>/dev/null | while IFS= read -r rule; do
        rname=$(echo "$rule"       | jq -r '.name // ""')
        priority=$(echo "$rule"    | jq -r '.properties.priority // 100')
        direction=$(echo "$rule"   | jq -r '.properties.direction // "Inbound"')
        access=$(echo "$rule"      | jq -r '.properties.access // "Allow"')
        protocol=$(echo "$rule"    | jq -r '.properties.protocol // "*"')
        src_port=$(echo "$rule"    | jq -r '.properties.sourcePortRange // "*"')
        dst_port=$(echo "$rule"    | jq -r '.properties.destinationPortRange // "*"')
        src_addr=$(echo "$rule"    | jq -r '.properties.sourceAddressPrefix // "*"')
        dst_addr=$(echo "$rule"    | jq -r '.properties.destinationAddressPrefix // "*"')
        rule_rid=$(echo "$rule"    | jq -r '.id // ""')
        rule_label=$(sanitise_label "nsgrule_${name}_${rname}")

        rule_attrs="  name                        = \"${rname}\"\n  resource_group_name         = \"${RG}\"\n  network_security_group_name = \"${name}\"\n  priority                    = ${priority}\n  direction                   = \"${direction}\"\n  access                      = \"${access}\"\n  protocol                    = \"${protocol}\"\n  source_port_range           = \"${src_port}\"\n  destination_port_range      = \"${dst_port}\"\n  source_address_prefix       = \"${src_addr}\"\n  destination_address_prefix  = \"${dst_addr}\""

        write_tf_stub "networking" "azurerm_network_security_rule" "$rule_rid" \
          "$rule_label" "$loc" "$(printf '%b' "$rule_attrs")"
        write_import_block "azurerm_network_security_rule" "$rule_label" "$rule_rid"
      done

      add_csv "Network Security Group" "$name" "$name" "$loc" "$rid" "$state" \
        "ResourceGroup=${RG},CustomRules=${custom_rules},DefaultRules=${default_rules}"

      attrs="  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n\n  # NOTE: security rules managed as azurerm_network_security_rule resources"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "networking" "azurerm_network_security_group" "$rid" \
        "$(sanitise_label "nsg_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network nsg list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} NSGs"

    # ── Public IP Addresses ────────────────────────────────────────────────────
    log_section "Public IP Addresses [${RG}]"
    COUNT=0
    while IFS= read -r pip; do
      [[ -z "$pip" || "$pip" == "null" ]] && continue
      name=$(echo "$pip"     | jq -r '.name // ""');  [[ -z "$name" ]] && continue
      rid=$(echo "$pip"      | jq -r '.id // ""')
      loc=$(echo "$pip"      | jq -r '.location // ""')
      ip=$(echo "$pip"       | jq -r '.ipAddress // "unassigned"')
      sku=$(echo "$pip"      | jq -r '.sku.name // "Basic"')
      sku_tier=$(echo "$pip" | jq -r '.sku.tier // "Regional"')
      alloc=$(echo "$pip"    | jq -r '.publicIPAllocationMethod // "Dynamic"')
      state=$(echo "$pip"    | jq -r '.provisioningState // ""')
      ip_version=$(echo "$pip"   | jq -r '.publicIPAddressVersion // "IPv4"')
      idle_timeout=$(echo "$pip" | jq -r '.idleTimeoutInMinutes // 4')
      dns_label=$(echo "$pip"    | jq -r '.dnsSettings.domainNameLabel // ""')
      zones=$(echo "$pip"        | jq -r '[.zones[]?] | join(",")' 2>/dev/null || true)
      tags=$(echo "$pip"         | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Public IP" "$name" "$name" "$loc" "$rid" "$state" \
        "IP=${ip},SKU=${sku},Allocation=${alloc},Version=${ip_version},Zones=${zones},ResourceGroup=${RG}"

      attrs="  name                    = \"${name}\"\n  resource_group_name     = \"${RG}\"\n  location                = \"${loc}\"\n  allocation_method       = \"${alloc}\"\n  sku                     = \"${sku}\"\n  sku_tier                = \"${sku_tier}\"\n  ip_version              = \"${ip_version}\"\n  idle_timeout_in_minutes = ${idle_timeout}"
      [[ -n "$dns_label" ]] && attrs="${attrs}\n  domain_name_label       = \"${dns_label}\""
      if [[ -n "$zones" ]]; then
        zone_list=$(echo "$zones" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        attrs="${attrs}\n  zones                   = [${zone_list}]"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "networking" "azurerm_public_ip" "$rid" \
        "$(sanitise_label "pip_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network public-ip list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} public IPs"

    # ── Route Tables ──────────────────────────────────────────────────────────
    log_section "Route Tables [${RG}]"
    COUNT=0
    while IFS= read -r rt; do
      [[ -z "$rt" || "$rt" == "null" ]] && continue
      name=$(echo "$rt"   | jq -r '.name // ""');  [[ -z "$name" ]] && continue
      rid=$(echo "$rt"    | jq -r '.id // ""')
      loc=$(echo "$rt"    | jq -r '.location // ""')
      state=$(echo "$rt"  | jq -r '.provisioningState // ""')
      disable_bgp=$(echo "$rt" | jq -r '.disableBgpRoutePropagation // false')
      route_count=$(echo "$rt" | jq '.routes | length' 2>/dev/null || echo 0)
      tags=$(echo "$rt"   | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      # Emit individual static routes
      echo "$rt" | jq -c '.routes[]?' 2>/dev/null | while IFS= read -r route; do
        rname=$(echo "$route"    | jq -r '.name // ""')
        addr_prefix=$(echo "$route"  | jq -r '.properties.addressPrefix // ""')
        next_hop_type=$(echo "$route" | jq -r '.properties.nextHopType // ""')
        next_hop_ip=$(echo "$route"  | jq -r '.properties.nextHopIpAddress // ""')
        route_rid=$(echo "$route"    | jq -r '.id // ""')
        route_label=$(sanitise_label "route_${name}_${rname}")

        route_attrs="  name                   = \"${rname}\"\n  resource_group_name    = \"${RG}\"\n  route_table_name       = \"${name}\"\n  address_prefix         = \"${addr_prefix}\"\n  next_hop_type          = \"${next_hop_type}\""
        [[ -n "$next_hop_ip" ]] && route_attrs="${route_attrs}\n  next_hop_in_ip_address = \"${next_hop_ip}\""

        write_tf_stub "networking" "azurerm_route" "$route_rid" \
          "$route_label" "$loc" "$(printf '%b' "$route_attrs")"
        write_import_block "azurerm_route" "$route_label" "$route_rid"
      done

      add_csv "Route Table" "$name" "$name" "$loc" "$rid" "$state" \
        "ResourceGroup=${RG},Routes=${route_count},DisableBGP=${disable_bgp}"

      attrs="  name                          = \"${name}\"\n  resource_group_name           = \"${RG}\"\n  location                      = \"${loc}\"\n  bgp_route_propagation_enabled = $([ "$disable_bgp" == "true" ] && echo false || echo true)"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "networking" "azurerm_route_table" "$rid" \
        "$(sanitise_label "rt_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network route-table list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} route tables"

    # ── Network Interfaces ─────────────────────────────────────────────────────
    log_section "Network Interfaces [${RG}]"
    COUNT=0
    while IFS= read -r nic; do
      [[ -z "$nic" || "$nic" == "null" ]] && continue
      name=$(echo "$nic"         | jq -r '.name // ""');  [[ -z "$name" ]] && continue
      rid=$(echo "$nic"          | jq -r '.id // ""')
      loc=$(echo "$nic"          | jq -r '.location // ""')
      state=$(echo "$nic"        | jq -r '.provisioningState // ""')
      enable_acc=$(echo "$nic"   | jq -r '.enableAcceleratedNetworking // false')
      enable_ip_fwd=$(echo "$nic" | jq -r '.enableIPForwarding // false')
      dns_servers=$(echo "$nic"  | jq -r '[.dnsSettings.dnsServers[]?] | join(",")' 2>/dev/null || true)
      nsg_id=$(echo "$nic"       | jq -r '.networkSecurityGroup.id // ""')
      vm_id=$(echo "$nic"        | jq -r '.virtualMachine.id // ""')
      primary_ip=$(echo "$nic"   | jq -r '.ipConfigurations[0].privateIPAddress // ""')
      subnet_id=$(echo "$nic"    | jq -r '.ipConfigurations[0].subnet.id // ""')
      ip_alloc=$(echo "$nic"     | jq -r '.ipConfigurations[0].privateIPAllocationMethod // "Dynamic"')
      tags=$(echo "$nic"         | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Network Interface" "$name" "$name" "$loc" "$rid" "$state" \
        "ResourceGroup=${RG},PrimaryIP=${primary_ip},AcceleratedNetworking=${enable_acc},IPForwarding=${enable_ip_fwd},AttachedVM=${vm_id}"

      attrs="  name                          = \"${name}\"\n  resource_group_name           = \"${RG}\"\n  location                      = \"${loc}\"\n  enable_accelerated_networking = ${enable_acc}\n  enable_ip_forwarding          = ${enable_ip_fwd}"
      attrs="${attrs}\n\n  ip_configuration {\n    name                          = \"internal\"\n    subnet_id                     = \"${subnet_id}\"\n    private_ip_address_allocation = \"${ip_alloc}\""
      [[ "$ip_alloc" == "Static" ]] && attrs="${attrs}\n    private_ip_address            = \"${primary_ip}\""
      attrs="${attrs}\n  }"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "networking" "azurerm_network_interface" "$rid" \
        "$(sanitise_label "nic_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network nic list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} network interfaces"

    # ── Virtual Machines ───────────────────────────────────────────────────────
    log_section "Virtual Machines [${RG}]"
    COUNT=0
    while IFS= read -r vm; do
      [[ -z "$vm" || "$vm" == "null" ]] && continue
      name=$(echo "$vm"   | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$vm"    | jq -r '.id // ""')
      loc=$(echo "$vm"    | jq -r '.location // ""')
      size=$(echo "$vm"   | jq -r '.hardwareProfile.vmSize // ""')
      os=$(echo "$vm"     | jq -r '.storageProfile.osDisk.osType // ""')
      state=$(echo "$vm"  | jq -r '.provisioningState // ""')
      zones=$(echo "$vm"  | jq -r '[.zones[]?] | join(",")' 2>/dev/null || true)

      # OS disk details
      os_disk_name=$(echo "$vm"  | jq -r '.storageProfile.osDisk.name // ""')
      os_disk_type=$(echo "$vm"  | jq -r '.storageProfile.osDisk.managedDisk.storageAccountType // "Premium_LRS"')
      os_disk_size=$(echo "$vm"  | jq -r '.storageProfile.osDisk.diskSizeGB // 0')
      os_caching=$(echo "$vm"    | jq -r '.storageProfile.osDisk.caching // "ReadWrite"')

      # Image reference
      img_pub=$(echo "$vm"  | jq -r '.storageProfile.imageReference.publisher // ""')
      img_offer=$(echo "$vm" | jq -r '.storageProfile.imageReference.offer // ""')
      img_sku=$(echo "$vm"   | jq -r '.storageProfile.imageReference.sku // ""')
      img_ver=$(echo "$vm"   | jq -r '.storageProfile.imageReference.version // "latest"')

      # Network interfaces
      nic_ids=$(echo "$vm" | jq -r '[.networkProfile.networkInterfaces[]?.id] | join(",")' 2>/dev/null || true)

      # Identity
      identity_type=$(echo "$vm" | jq -r '.identity.type // ""')
      identity_ids=$(echo "$vm"  | jq -r '[.identity.userAssignedIdentities // {} | keys[]] | join(",")' 2>/dev/null || true)

      # Boot diagnostics
      boot_diag=$(echo "$vm" | jq -r '.diagnosticsProfile.bootDiagnostics.enabled // false')

      # Admin details (no passwords ever exported)
      admin_user=$(echo "$vm" | jq -r '.osProfile.adminUsername // ""')
      disable_pw=$(echo "$vm" | jq -r '.osProfile.linuxConfiguration.disablePasswordAuthentication // false')

      tags=$(echo "$vm"  | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Virtual Machine" "$name" "$name" "$loc" "$rid" "$state" \
        "Size=${size},OS=${os},OSDisk=${os_disk_type},Image=${img_pub}:${img_offer}:${img_sku},Zones=${zones},BootDiag=${boot_diag},ResourceGroup=${RG}"

      tf_resource=$([ "$os" == "Windows" ] && echo "azurerm_windows_virtual_machine" || echo "azurerm_linux_virtual_machine")

      attrs="  name                  = \"${name}\"\n  resource_group_name   = \"${RG}\"\n  location              = \"${loc}\"\n  size                  = \"${size}\"\n  admin_username        = \"${admin_user}\""
      if [[ "$os" == "Linux" && "$disable_pw" == "true" ]]; then
        attrs="${attrs}\n  disable_password_authentication = true\n\n  admin_ssh_key {\n    username   = \"${admin_user}\"\n    public_key = \"# TODO: replace with actual public key contents (ssh-rsa AAAA...)\"\n  }"
      else
        attrs="${attrs}\n  admin_password = \"# TODO: set via sensitive tfvar or Key Vault reference — never hardcode\""
      fi

      # NIC list
      if [[ -n "$nic_ids" ]]; then
        nic_list=$(echo "$nic_ids" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        attrs="${attrs}\n  network_interface_ids = [${nic_list}]"
      fi

      attrs="${attrs}\n\n  os_disk {\n    name                 = \"${os_disk_name}\"\n    caching              = \"${os_caching}\"\n    storage_account_type = \"${os_disk_type}\""
      [[ "$os_disk_size" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n    disk_size_gb         = ${os_disk_size}"
      attrs="${attrs}\n  }"

      if [[ -n "$img_pub" ]]; then
        attrs="${attrs}\n\n  source_image_reference {\n    publisher = \"${img_pub}\"\n    offer     = \"${img_offer}\"\n    sku       = \"${img_sku}\"\n    version   = \"${img_ver}\"\n  }"
      fi

      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\""
        [[ -n "$identity_ids" ]] && attrs="${attrs}\n    identity_ids = [\"${identity_ids//,/\",\"}\"]"
        attrs="${attrs}\n  }"
      fi

      if [[ -n "$zones" ]]; then
        attrs="${attrs}\n  zone = \"${zones%%,*}\""
      fi

      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "compute" "$tf_resource" "$rid" \
        "$(sanitise_label "vm_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" vm list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} virtual machines"

    # ── Managed Disks ─────────────────────────────────────────────────────────
    log_section "Managed Disks [${RG}]"
    COUNT=0
    while IFS= read -r disk; do
      [[ -z "$disk" || "$disk" == "null" ]] && continue
      name=$(echo "$disk"       | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$disk"        | jq -r '.id // ""')
      loc=$(echo "$disk"        | jq -r '.location // ""')
      size=$(echo "$disk"       | jq -r '.diskSizeGb // 0')
      sku=$(echo "$disk"        | jq -r '.sku.name // ""')
      state=$(echo "$disk"      | jq -r '.provisioningState // ""')
      disk_state=$(echo "$disk" | jq -r '.diskState // ""')
      os_type=$(echo "$disk"    | jq -r '.osType // ""')
      zones=$(echo "$disk"      | jq -r '[.zones[]?] | join(",")' 2>/dev/null || true)
      iops=$(echo "$disk"       | jq -r '.diskIOPSReadWrite // 0')
      mbps=$(echo "$disk"       | jq -r '.diskMBpsReadWrite // 0')
      create_option=$(echo "$disk" | jq -r '.creationData.createOption // "Empty"')
      src_id=$(echo "$disk"     | jq -r '.creationData.sourceResourceId // ""')
      encryption=$(echo "$disk" | jq -r '.encryption.type // ""')
      des_id=$(echo "$disk"     | jq -r '.encryption.diskEncryptionSetId // ""')
      max_shares=$(echo "$disk" | jq -r '.maxShares // 0')
      tags=$(echo "$disk"       | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Managed Disk" "$name" "$name" "$loc" "$rid" "$state" \
        "Size=${size}GB,SKU=${sku},State=${disk_state},OSType=${os_type},Zones=${zones},CreateOption=${create_option},Encryption=${encryption}"

      attrs="  name                 = \"${name}\"\n  resource_group_name  = \"${RG}\"\n  location             = \"${loc}\"\n  storage_account_type = \"${sku}\"\n  disk_size_gb         = ${size}\n  create_option        = \"${create_option}\""
      [[ -n "$os_type" ]]  && attrs="${attrs}\n  os_type              = \"${os_type}\""
      [[ -n "$src_id" ]]   && attrs="${attrs}\n  source_resource_id   = \"${src_id}\""
      [[ "$iops" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n  disk_iops_read_write = ${iops}"
      [[ "$mbps" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n  disk_mbps_read_write = ${mbps}"
      [[ "$max_shares" -gt 1 ]] 2>/dev/null && attrs="${attrs}\n  max_shares           = ${max_shares}"
      if [[ -n "$zones" ]]; then
        attrs="${attrs}\n  zone                 = \"${zones%%,*}\""
      fi
      if [[ -n "$des_id" ]]; then
        attrs="${attrs}\n\n  encryption_settings {\n    enabled               = true\n    disk_encryption_set_id = \"${des_id}\"\n  }"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "compute" "azurerm_managed_disk" "$rid" \
        "$(sanitise_label "disk_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" disk list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} managed disks"

    # ── Load Balancers ─────────────────────────────────────────────────────────
    log_section "Load Balancers [${RG}]"
    COUNT=0
    while IFS= read -r lb; do
      [[ -z "$lb" || "$lb" == "null" ]] && continue
      name=$(echo "$lb"   | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$lb"    | jq -r '.id // ""')
      loc=$(echo "$lb"    | jq -r '.location // ""')
      sku=$(echo "$lb"    | jq -r '.sku.name // "Basic"')
      sku_tier=$(echo "$lb" | jq -r '.sku.tier // "Regional"')
      state=$(echo "$lb"  | jq -r '.provisioningState // ""')
      fe_count=$(echo "$lb" | jq '.frontendIPConfigurations | length' 2>/dev/null || echo 0)
      be_count=$(echo "$lb" | jq '.backendAddressPools | length' 2>/dev/null || echo 0)
      probe_count=$(echo "$lb" | jq '.probes | length' 2>/dev/null || echo 0)
      rule_count=$(echo "$lb"  | jq '.loadBalancingRules | length' 2>/dev/null || echo 0)
      zones=$(echo "$lb"  | jq -r '[.zones[]?] | join(",")' 2>/dev/null || true)
      tags=$(echo "$lb"   | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      # Frontend IP configuration details
      fe_name=$(echo "$lb"   | jq -r '.frontendIPConfigurations[0].name // "LoadBalancerFrontEnd"')
      fe_pip_id=$(echo "$lb" | jq -r '.frontendIPConfigurations[0].publicIPAddress.id // ""')
      fe_subnet=$(echo "$lb" | jq -r '.frontendIPConfigurations[0].subnet.id // ""')
      fe_priv_ip=$(echo "$lb" | jq -r '.frontendIPConfigurations[0].privateIPAddress // ""')
      fe_alloc=$(echo "$lb"  | jq -r '.frontendIPConfigurations[0].privateIPAllocationMethod // "Dynamic"')

      add_csv "Load Balancer" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},Tier=${sku_tier},Frontends=${fe_count},Backends=${be_count},Probes=${probe_count},Rules=${rule_count},Zones=${zones},ResourceGroup=${RG}"

      attrs="  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  sku                 = \"${sku}\"\n  sku_tier            = \"${sku_tier}\""
      attrs="${attrs}\n\n  frontend_ip_configuration {\n    name = \"${fe_name}\""
      if [[ -n "$fe_pip_id" ]]; then
        attrs="${attrs}\n    public_ip_address_id = \"${fe_pip_id}\""
      elif [[ -n "$fe_subnet" ]]; then
        attrs="${attrs}\n    subnet_id                     = \"${fe_subnet}\"\n    private_ip_address_allocation = \"${fe_alloc}\""
        [[ "$fe_alloc" == "Static" && -n "$fe_priv_ip" ]] && \
          attrs="${attrs}\n    private_ip_address            = \"${fe_priv_ip}\""
      fi
      attrs="${attrs}\n  }"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "networking" "azurerm_lb" "$rid" \
        "$(sanitise_label "lb_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network lb list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} load balancers"

    # ── Application Gateways ───────────────────────────────────────────────────
    log_section "Application Gateways [${RG}]"
    COUNT=0
    while IFS= read -r agw; do
      [[ -z "$agw" || "$agw" == "null" ]] && continue
      name=$(echo "$agw"   | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$agw"    | jq -r '.id // ""')
      loc=$(echo "$agw"    | jq -r '.location // ""')
      sku_name=$(echo "$agw" | jq -r '.sku.name // ""')
      sku_tier=$(echo "$agw" | jq -r '.sku.tier // ""')
      capacity=$(echo "$agw" | jq -r '.sku.capacity // 2')
      state=$(echo "$agw"  | jq -r '.provisioningState // ""')
      waf_enabled=$(echo "$agw" | jq -r '.webApplicationFirewallConfiguration.enabled // false')
      waf_mode=$(echo "$agw"    | jq -r '.webApplicationFirewallConfiguration.firewallMode // ""')
      autoscale_min=$(echo "$agw" | jq -r '.autoscaleConfiguration.minCapacity // ""')
      autoscale_max=$(echo "$agw" | jq -r '.autoscaleConfiguration.maxCapacity // ""')
      fe_count=$(echo "$agw" | jq '.frontendIPConfigurations | length' 2>/dev/null || echo 0)
      be_count=$(echo "$agw" | jq '.backendAddressPools | length' 2>/dev/null || echo 0)
      zones=$(echo "$agw"    | jq -r '[.zones[]?] | join(",")' 2>/dev/null || true)
      tags=$(echo "$agw"     | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Application Gateway" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku_name},Tier=${sku_tier},Capacity=${capacity},WAF=${waf_enabled},WAFMode=${waf_mode},Zones=${zones},ResourceGroup=${RG}"

      attrs="  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n\n  sku {\n    name     = \"${sku_name}\"\n    tier     = \"${sku_tier}\""
      if [[ -n "$autoscale_min" ]]; then
        attrs="${attrs}\n  }\n\n  autoscale_configuration {\n    min_capacity = ${autoscale_min}"
        [[ -n "$autoscale_max" ]] && attrs="${attrs}\n    max_capacity = ${autoscale_max}"
        attrs="${attrs}\n  }"
      else
        attrs="${attrs}\n    capacity = ${capacity}\n  }"
      fi
      if [[ "$waf_enabled" == "true" ]]; then
        attrs="${attrs}\n\n  waf_configuration {\n    enabled          = true\n    firewall_mode    = \"${waf_mode}\"\n    rule_set_type    = \"OWASP\"\n    rule_set_version = \"3.2\"\n  }"
      fi
      if [[ -n "$zones" ]]; then
        zone_list=$(echo "$zones" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        attrs="${attrs}\n  zones = [${zone_list}]"
      fi
      # Fetch full app gateway config to build required blocks
      agw_config=$(az network application-gateway show --name "${name}" --resource-group "${RG}" -o json 2>/dev/null || echo "null")

      # gateway_ip_configuration
      gw_ip_name=$(echo "$agw_config"   | jq -r '.gatewayIpConfigurations[0].name // "appGatewayIpConfig"')
      gw_subnet=$(echo "$agw_config"    | jq -r '.gatewayIpConfigurations[0].subnet.id // ""')
      attrs="${attrs}\n\n  gateway_ip_configuration {\n    name      = \"${gw_ip_name}\"\n    subnet_id = \"${gw_subnet}\"\n  }"

      # frontend_port
      fe_port_name=$(echo "$agw_config" | jq -r '.frontendPorts[0].name // "frontendPort"')
      fe_port_num=$(echo "$agw_config"  | jq -r '.frontendPorts[0].properties.port // 443')
      attrs="${attrs}\n\n  frontend_port {\n    name = \"${fe_port_name}\"\n    port = ${fe_port_num}\n  }"

      # frontend_ip_configuration
      fe_ip_name=$(echo "$agw_config"   | jq -r '.frontendIpConfigurations[0].name // "frontendIpConfig"')
      fe_pip_id=$(echo "$agw_config"    | jq -r '.frontendIpConfigurations[0].properties.publicIpAddress.id // ""')
      fe_priv_ip=$(echo "$agw_config"   | jq -r '.frontendIpConfigurations[0].properties.privateIpAddress // ""')
      attrs="${attrs}\n\n  frontend_ip_configuration {\n    name = \"${fe_ip_name}\""
      [[ -n "$fe_pip_id" ]]  && attrs="${attrs}\n    public_ip_address_id = \"${fe_pip_id}\""
      [[ -n "$fe_priv_ip" ]] && attrs="${attrs}\n    private_ip_address   = \"${fe_priv_ip}\"\n    private_ip_address_allocation = \"Static\""
      attrs="${attrs}\n  }"

      # backend_address_pool
      be_pool_name=$(echo "$agw_config" | jq -r '.backendAddressPools[0].name // "backendPool"')
      attrs="${attrs}\n\n  backend_address_pool {\n    name = \"${be_pool_name}\"\n  }"

      # backend_http_settings
      be_http_name=$(echo "$agw_config" | jq -r '.backendHttpSettingsCollection[0].name // "backendHttpSettings"')
      be_port=$(echo "$agw_config"      | jq -r '.backendHttpSettingsCollection[0].properties.port // 443')
      be_proto=$(echo "$agw_config"     | jq -r '.backendHttpSettingsCollection[0].properties.protocol // "Https"')
      be_timeout=$(echo "$agw_config"   | jq -r '.backendHttpSettingsCollection[0].properties.requestTimeout // 60')
      attrs="${attrs}\n\n  backend_http_settings {\n    name                  = \"${be_http_name}\"\n    cookie_based_affinity = \"Disabled\"\n    port                  = ${be_port}\n    protocol              = \"${be_proto}\"\n    request_timeout       = ${be_timeout}\n  }"

      # http_listener
      lis_name=$(echo "$agw_config"     | jq -r '.httpListeners[0].name // "httpListener"')
      lis_proto=$(echo "$agw_config"    | jq -r '.httpListeners[0].properties.protocol // "Https"')
      attrs="${attrs}\n\n  http_listener {\n    name                           = \"${lis_name}\"\n    frontend_ip_configuration_name = \"${fe_ip_name}\"\n    frontend_port_name             = \"${fe_port_name}\"\n    protocol                       = \"${lis_proto}\"\n  }"

      # request_routing_rule
      rr_name=$(echo "$agw_config"      | jq -r '.requestRoutingRules[0].name // "routingRule"')
      rr_type=$(echo "$agw_config"      | jq -r '.requestRoutingRules[0].properties.ruleType // "Basic"')
      rr_prio=$(echo "$agw_config"      | jq -r '.requestRoutingRules[0].properties.priority // 100')
      attrs="${attrs}\n\n  request_routing_rule {\n    name                       = \"${rr_name}\"\n    rule_type                  = \"${rr_type}\"\n    priority                   = ${rr_prio}\n    http_listener_name         = \"${lis_name}\"\n    backend_address_pool_name  = \"${be_pool_name}\"\n    backend_http_settings_name = \"${be_http_name}\"\n  }"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "networking" "azurerm_application_gateway" "$rid" \
        "$(sanitise_label "agw_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network application-gateway list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} application gateways"

    # ── SQL Servers + Databases ────────────────────────────────────────────────
    log_section "SQL Servers [${RG}]"
    COUNT=0
    SQL_SERVERS=()
    while IFS= read -r srv; do
      [[ -z "$srv" || "$srv" == "null" ]] && continue
      name=$(echo "$srv"    | jq -r '.name // ""');  [[ -z "$name" ]] && continue
      rid=$(echo "$srv"     | jq -r '.id // ""')
      loc=$(echo "$srv"     | jq -r '.location // ""')
      fqdn=$(echo "$srv"    | jq -r '.fullyQualifiedDomainName // ""')
      state=$(echo "$srv"   | jq -r '.state // ""')
      version=$(echo "$srv" | jq -r '.version // "12.0"')
      admin=$(echo "$srv"   | jq -r '.administratorLogin // ""')
      min_tls=$(echo "$srv" | jq -r '.minimalTlsVersion // "1.2"')
      public_net=$(echo "$srv" | jq -r '.publicNetworkAccess // "Enabled"')
      conn_policy=$(echo "$srv" | jq -r '.connectionPolicy // "Default"')
      identity_type=$(echo "$srv" | jq -r '.identity.type // ""')
      tags=$(echo "$srv"    | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")
      SQL_SERVERS+=("$name")

      add_csv "SQL Server" "$name" "$name" "$loc" "$rid" "$state" \
        "FQDN=${fqdn},Version=${version},MinTLS=${min_tls},PublicNetwork=${public_net},ResourceGroup=${RG}"

      attrs="  name                          = \"${name}\"\n  resource_group_name           = \"${RG}\"\n  location                      = \"${loc}\"\n  version                       = \"${version}\"\n  administrator_login           = \"${admin}\"\n  administrator_login_password  = \"# TODO: set via sensitive tfvar or Key Vault reference — never hardcode\"\n  minimum_tls_version           = \"${min_tls}\"\n  public_network_access_enabled = $([ "$public_net" == "Enabled" ] && echo true || echo false)"
      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\"\n  }"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "sql" "azurerm_mssql_server" "$rid" \
        "$(sanitise_label "sqlsrv_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" sql server list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} SQL servers"

    log_section "SQL Databases [${RG}]"
    COUNT=0
    for SQL_SRV in "${SQL_SERVERS[@]:-}"; do
      [[ -z "$SQL_SRV" ]] && continue
      while IFS= read -r db; do
        [[ -z "$db" || "$db" == "null" ]] && continue
        name=$(echo "$db"     | jq -r '.name // ""');  [[ -z "$name" ]] && continue
        [[ "$name" == "master" ]] && continue
        rid=$(echo "$db"      | jq -r '.id // ""')
        loc=$(echo "$db"      | jq -r '.location // ""')
        sku=$(echo "$db"      | jq -r '.sku.name // ""')
        state=$(echo "$db"    | jq -r '.status // ""')
        tier=$(echo "$db"     | jq -r '.sku.tier // ""')
        max_size=$(echo "$db" | jq -r '.maxSizeBytes // 0')
        zone_redundant=$(echo "$db" | jq -r '.zoneRedundant // false')
        collation=$(echo "$db"      | jq -r '.collation // ""')
        license=$(echo "$db"        | jq -r '.licenseType // ""')
        read_scale=$(echo "$db"     | jq -r '.readScale // "Disabled"')
        backup_storage=$(echo "$db" | jq -r '.requestedBackupStorageRedundancy // ""')
        elastic_pool=$(echo "$db"   | jq -r '.elasticPoolId // ""')
        tags=$(echo "$db"           | jq -c '.tags // {}')
        tags_hcl=$(render_tags_hcl "$tags")

        max_gb=$(echo "scale=2; ${max_size} / 1073741824" | bc 2>/dev/null || echo 0)

        add_csv "SQL Database" "${SQL_SRV}/${name}" "$name" "$loc" "$rid" "$state" \
          "Server=${SQL_SRV},SKU=${sku},Tier=${tier},MaxSizeGB=${max_gb},ZoneRedundant=${zone_redundant},ResourceGroup=${RG}"

        srv_label=$(sanitise_label "sqlsrv_${SQL_SRV}")
        attrs="  name                        = \"${name}\"\n  server_id                   = azurerm_mssql_server.${srv_label}.id\n  sku_name                    = \"${sku}\"\n  zone_redundant              = ${zone_redundant}"
        [[ "$max_size" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n  max_size_gb                 = ${max_gb%.*}"
        [[ -n "$collation" ]]   && attrs="${attrs}\n  collation                   = \"${collation}\""
        [[ -n "$license" ]]     && attrs="${attrs}\n  license_type                = \"${license}\""
        [[ -n "$elastic_pool" ]] && attrs="${attrs}\n  elastic_pool_id             = \"${elastic_pool}\""
        [[ -n "$backup_storage" ]] && attrs="${attrs}\n  storage_account_type        = \"${backup_storage}\""
        [[ "$read_scale" == "Enabled" ]] && attrs="${attrs}\n  read_scale                  = true"
        [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

        emit_resource "sql" "azurerm_mssql_database" "$rid" \
          "$(sanitise_label "sqldb_${SQL_SRV}_${name}")" "$loc" "$(printf '%b' "$attrs")"
        ((COUNT++)) || true
      done < <(az_sub "$SUB_ID" sql db list \
          --server "$SQL_SRV" --resource-group "$RG" \
          --output json 2>/dev/null | jq -c '.[]?' || true)
    done
    echo -e "  ${GREEN}✓${NC} ${COUNT} SQL databases"

    # ── Cosmos DB Accounts ─────────────────────────────────────────────────────
    log_section "Cosmos DB Accounts [${RG}]"
    COUNT=0
    while IFS= read -r cosmos; do
      [[ -z "$cosmos" || "$cosmos" == "null" ]] && continue
      name=$(echo "$cosmos"          | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$cosmos"           | jq -r '.id // ""')
      loc=$(echo "$cosmos"           | jq -r '.location // ""')
      kind=$(echo "$cosmos"          | jq -r '.kind // "GlobalDocumentDB"')
      state=$(echo "$cosmos"         | jq -r '.provisioningState // ""')
      consistency=$(echo "$cosmos"   | jq -r '.consistencyPolicy.defaultConsistencyLevel // "Session"')
      max_staleness=$(echo "$cosmos" | jq -r '.consistencyPolicy.maxStalenessPrefix // 0')
      max_interval=$(echo "$cosmos"  | jq -r '.consistencyPolicy.maxIntervalInSeconds // 0')
      geo_locs=$(echo "$cosmos"      | jq -r '[.locations[]?.locationName] | join(",")' 2>/dev/null || true)
      free_tier=$(echo "$cosmos"     | jq -r '.enableFreeTier // false')
      auto_failover=$(echo "$cosmos" | jq -r '.enableAutomaticFailover // false')
      multi_write=$(echo "$cosmos"   | jq -r '.enableMultipleWriteLocations // false')
      analytical=$(echo "$cosmos"    | jq -r '.enableAnalyticalStorage // false')
      public_net=$(echo "$cosmos"    | jq -r '.publicNetworkAccess // "Enabled"')
      ip_rules=$(echo "$cosmos"      | jq -r '[.ipRules[]?.ipAddressOrRange] | join(",")' 2>/dev/null || true)
      tags=$(echo "$cosmos"          | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Cosmos DB" "$name" "$name" "$loc" "$rid" "$state" \
        "Kind=${kind},Consistency=${consistency},GeoLocations=${geo_locs},FreeTier=${free_tier},MultiWrite=${multi_write},ResourceGroup=${RG}"

      attrs="  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  offer_type          = \"Standard\"\n  kind                = \"${kind}\"\n  enable_free_tier    = ${free_tier}\n  enable_automatic_failover = ${auto_failover}\n  enable_multiple_write_locations = ${multi_write}\n  analytical_storage_enabled = ${analytical}\n  public_network_access_enabled = $([ "$public_net" == "Enabled" ] && echo true || echo false)"
      attrs="${attrs}\n\n  consistency_policy {\n    consistency_level = \"${consistency}\""
      [[ "$consistency" == "BoundedStaleness" ]] && \
        attrs="${attrs}\n    max_staleness_prefix  = ${max_staleness}\n    max_interval_in_seconds = ${max_interval}"
      attrs="${attrs}\n  }"
      # Geo-locations block
      echo "$cosmos" | jq -c '.locations[]?' 2>/dev/null | while IFS= read -r geo; do
        gloc=$(echo "$geo"  | jq -r '.locationName // ""')
        gfail=$(echo "$geo" | jq -r '.failoverPriority // 0')
        gzone=$(echo "$geo" | jq -r '.isZoneRedundant // false')
        printf '\n  geo_location {\n    location          = "%s"\n    failover_priority = %s\n    zone_redundant    = %s\n  }' \
          "$gloc" "$gfail" "$gzone"
      done >> /dev/null  # geo_location blocks are complex; note for user
      # Build geo_location blocks from the fetched location list
      geo_hcl=""
      failover_pri=0
      while IFS= read -r geo; do
        [[ -z "$geo" || "$geo" == "null" ]] && continue
        geo_loc=$(echo "$geo"  | jq -r '.locationName // ""' | tr -d " " | tr "[:upper:]" "[:lower:]")
        geo_hcl="${geo_hcl}\n\n  geo_location {\n    location          = \"${geo_loc}\"\n    failover_priority = ${failover_pri}\n  }"
        ((failover_pri++))
      done < <(echo "$acct" | jq -c ".locations[]?" 2>/dev/null || true)
      # Fallback to primary location if API returned nothing
      [[ -z "$geo_hcl" ]] && geo_hcl="\n\n  geo_location {\n    location          = \"${loc// /}\"\n    failover_priority = 0\n  }"
      attrs="${attrs}${geo_hcl}"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "cosmosdb" "azurerm_cosmosdb_account" "$rid" \
        "$(sanitise_label "cosmos_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" cosmosdb list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} Cosmos DB accounts"

    # ── Redis Cache ────────────────────────────────────────────────────────────
    log_section "Redis Caches [${RG}]"
    COUNT=0
    while IFS= read -r redis; do
      [[ -z "$redis" || "$redis" == "null" ]] && continue
      name=$(echo "$redis"      | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$redis"       | jq -r '.id // ""')
      loc=$(echo "$redis"       | jq -r '.location // ""')
      sku=$(echo "$redis"       | jq -r '.sku.name // ""')
      family=$(echo "$redis"    | jq -r '.sku.family // "C"')
      capacity=$(echo "$redis"  | jq -r '.sku.capacity // 1')
      state=$(echo "$redis"     | jq -r '.provisioningState // ""')
      hostname=$(echo "$redis"  | jq -r '.hostName // ""')
      port=$(echo "$redis"      | jq -r '.port // 6379')
      ssl_port=$(echo "$redis"  | jq -r '.sslPort // 6380')
      non_ssl=$(echo "$redis"   | jq -r '.enableNonSslPort // false')
      min_tls=$(echo "$redis"   | jq -r '.minimumTlsVersion // "1.2"')
      shard_count=$(echo "$redis" | jq -r '.shardCount // 0')
      max_mem_policy=$(echo "$redis" | jq -r '.redisConfiguration.maxmemoryPolicy // ""')
      max_mem_reserved=$(echo "$redis" | jq -r '.redisConfiguration.maxmemoryReserved // ""')
      subnet_id=$(echo "$redis" | jq -r '.subnetId // ""')
      static_ip=$(echo "$redis" | jq -r '.staticIP // ""')
      zones=$(echo "$redis"     | jq -r '[.zones[]?] | join(",")' 2>/dev/null || true)
      tags=$(echo "$redis"      | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Redis Cache" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},Family=${family},Capacity=${capacity},Hostname=${hostname},MinTLS=${min_tls},ShardCount=${shard_count},ResourceGroup=${RG}"

      attrs="  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  capacity            = ${capacity}\n  family              = \"${family}\"\n  sku_name            = \"${sku}\"\n  enable_non_ssl_port = ${non_ssl}\n  minimum_tls_version = \"${min_tls}\""
      [[ "$shard_count" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n  shard_count         = ${shard_count}"
      [[ -n "$subnet_id" ]]  && attrs="${attrs}\n  subnet_id           = \"${subnet_id}\""
      [[ -n "$static_ip" ]]  && attrs="${attrs}\n  private_static_ip_address = \"${static_ip}\""
      if [[ -n "$max_mem_policy" || -n "$max_mem_reserved" ]]; then
        attrs="${attrs}\n\n  redis_configuration {"
        [[ -n "$max_mem_policy" ]]   && attrs="${attrs}\n    maxmemory_policy   = \"${max_mem_policy}\""
        [[ -n "$max_mem_reserved" ]] && attrs="${attrs}\n    maxmemory_reserved = ${max_mem_reserved}"
        attrs="${attrs}\n  }"
      fi
      if [[ -n "$zones" ]]; then
        zone_list=$(echo "$zones" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        attrs="${attrs}\n  zones = [${zone_list}]"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "redis" "azurerm_redis_cache" "$rid" \
        "$(sanitise_label "redis_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" redis list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} Redis caches"

    # ── AKS Clusters ──────────────────────────────────────────────────────────
    log_section "AKS Clusters [${RG}]"
    COUNT=0
    while IFS= read -r aks; do
      [[ -z "$aks" || "$aks" == "null" ]] && continue
      name=$(echo "$aks"       | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$aks"        | jq -r '.id // ""')
      loc=$(echo "$aks"        | jq -r '.location // ""')
      ver=$(echo "$aks"        | jq -r '.kubernetesVersion // ""')
      state=$(echo "$aks"      | jq -r '.provisioningState // ""')
      dns_prefix=$(echo "$aks" | jq -r '.dnsPrefix // "${name}"')
      fqdn=$(echo "$aks"       | jq -r '.fqdn // ""')
      node_rg=$(echo "$aks"    | jq -r '.nodeResourceGroup // ""')
      rbac=$(echo "$aks"       | jq -r '.enableRbac // true')
      private=$(echo "$aks"    | jq -r '.apiServerAccessProfile.enablePrivateCluster // false')
      network_plugin=$(echo "$aks" | jq -r '.networkProfile.networkPlugin // "kubenet"')
      network_policy=$(echo "$aks" | jq -r '.networkProfile.networkPolicy // ""')
      lb_sku=$(echo "$aks"         | jq -r '.networkProfile.loadBalancerSku // "standard"')
      service_cidr=$(echo "$aks"   | jq -r '.networkProfile.serviceCidr // ""')
      dns_service_ip=$(echo "$aks" | jq -r '.networkProfile.dnsServiceIP // ""')
      outbound_type=$(echo "$aks"  | jq -r '.networkProfile.outboundType // "loadBalancer"')
      identity_type=$(echo "$aks"  | jq -r '.identity.type // ""')

      # System node pool
      np_name=$(echo "$aks"     | jq -r '.agentPoolProfiles[0].name // "system"')
      np_count=$(echo "$aks"    | jq -r '.agentPoolProfiles[0].count // 1')
      np_vm=$(echo "$aks"       | jq -r '.agentPoolProfiles[0].vmSize // ""')
      np_os_disk=$(echo "$aks"  | jq -r '.agentPoolProfiles[0].osDiskSizeGB // 0')
      np_disk_type=$(echo "$aks" | jq -r '.agentPoolProfiles[0].osDiskType // "Managed"')
      np_subnet=$(echo "$aks"   | jq -r '.agentPoolProfiles[0].vnetSubnetID // ""')
      np_min=$(echo "$aks"      | jq -r '.agentPoolProfiles[0].minCount // ""')
      np_max=$(echo "$aks"      | jq -r '.agentPoolProfiles[0].maxCount // ""')
      np_autoscale=$(echo "$aks" | jq -r '.agentPoolProfiles[0].enableAutoScaling // false')
      np_zones=$(echo "$aks"    | jq -r '[.agentPoolProfiles[0].availabilityZones[]?] | join(",")' 2>/dev/null || true)

      # Add-ons
      oms_enabled=$(echo "$aks" | jq -r '.addonProfiles.omsagent.enabled // false')
      oms_ws=$(echo "$aks"      | jq -r '.addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID // ""')
      ingress_enabled=$(echo "$aks" | jq -r '.addonProfiles.httpApplicationRouting.enabled // false')

      tags=$(echo "$aks" | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "AKS Cluster" "$name" "$name" "$loc" "$rid" "$state" \
        "K8sVersion=${ver},NodePool=${np_name}(${np_count}x${np_vm}),Autoscale=${np_autoscale},NetworkPlugin=${network_plugin},Private=${private},FQDN=${fqdn},ResourceGroup=${RG}"

      attrs="  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  kubernetes_version  = \"${ver}\"\n  dns_prefix          = \"${dns_prefix}\"\n  node_resource_group = \"${node_rg}\"\n  role_based_access_control_enabled = ${rbac}\n  private_cluster_enabled = ${private}"
      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\"\n  }"
      fi
      attrs="${attrs}\n\n  default_node_pool {\n    name       = \"${np_name}\"\n    node_count = ${np_count}\n    vm_size    = \"${np_vm}\""
      [[ "$np_os_disk" -gt 0 ]] 2>/dev/null && attrs="${attrs}\n    os_disk_size_gb = ${np_os_disk}"
      attrs="${attrs}\n    os_disk_type    = \"${np_disk_type}\""
      [[ -n "$np_subnet" ]] && attrs="${attrs}\n    vnet_subnet_id  = \"${np_subnet}\""
      if [[ "$np_autoscale" == "true" ]]; then
        attrs="${attrs}\n    enable_auto_scaling = true"
        [[ -n "$np_min" ]] && attrs="${attrs}\n    min_count           = ${np_min}"
        [[ -n "$np_max" ]] && attrs="${attrs}\n    max_count           = ${np_max}"
      fi
      if [[ -n "$np_zones" ]]; then
        nz_list=$(echo "$np_zones" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        attrs="${attrs}\n    zones           = [${nz_list}]"
      fi
      attrs="${attrs}\n  }"
      attrs="${attrs}\n\n  network_profile {\n    network_plugin    = \"${network_plugin}\"\n    load_balancer_sku = \"${lb_sku}\"\n    outbound_type     = \"${outbound_type}\""
      [[ -n "$network_policy" ]]  && attrs="${attrs}\n    network_policy    = \"${network_policy}\""
      [[ -n "$service_cidr" ]]    && attrs="${attrs}\n    service_cidr      = \"${service_cidr}\""
      [[ -n "$dns_service_ip" ]]  && attrs="${attrs}\n    dns_service_ip    = \"${dns_service_ip}\""
      attrs="${attrs}\n  }"
      if [[ "$oms_enabled" == "true" && -n "$oms_ws" ]]; then
        attrs="${attrs}\n\n  oms_agent {\n    log_analytics_workspace_id = \"${oms_ws}\"\n  }"
      fi
      if [[ "$ingress_enabled" == "true" ]]; then
        attrs="${attrs}\n\n  http_application_routing_enabled = true"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "aks" "azurerm_kubernetes_cluster" "$rid" \
        "$(sanitise_label "aks_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" aks list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} AKS clusters"

    # ── Container Registries ───────────────────────────────────────────────────
    log_section "Container Registries (ACR) [${RG}]"
    COUNT=0
    while IFS= read -r acr; do
      [[ -z "$acr" || "$acr" == "null" ]] && continue
      name=$(echo "$acr"       | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$acr"        | jq -r '.id // ""')
      loc=$(echo "$acr"        | jq -r '.location // ""')
      sku=$(echo "$acr"        | jq -r '.sku.name // ""')
      server=$(echo "$acr"     | jq -r '.loginServer // ""')
      state=$(echo "$acr"      | jq -r '.provisioningState // ""')
      admin_enabled=$(echo "$acr"      | jq -r '.adminUserEnabled // false')
      public_net=$(echo "$acr"         | jq -r '.publicNetworkAccess // "Enabled"')
      geo_repl=$(echo "$acr"           | jq -r '[.replicationLocations[]?] | join(",")' 2>/dev/null || true)
      data_endpoints=$(echo "$acr"     | jq -r '.dataEndpointEnabled // false')
      zone_redundancy=$(echo "$acr"    | jq -r '.zoneRedundancy // "Disabled"')
      retention_days=$(echo "$acr"     | jq -r '.policies.retentionPolicy.days // 7')
      retention_enabled=$(echo "$acr"  | jq -r '.policies.retentionPolicy.status // "disabled"')
      trust_policy=$(echo "$acr"       | jq -r '.policies.trustPolicy.status // "disabled"')
      identity_type=$(echo "$acr"      | jq -r '.identity.type // ""')
      tags=$(echo "$acr"               | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Container Registry" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},LoginServer=${server},AdminEnabled=${admin_enabled},PublicNetwork=${public_net},ZoneRedundancy=${zone_redundancy},ResourceGroup=${RG}"

      attrs="  name                          = \"${name}\"\n  resource_group_name           = \"${RG}\"\n  location                      = \"${loc}\"\n  sku                           = \"${sku}\"\n  admin_enabled                 = ${admin_enabled}\n  public_network_access_enabled = $([ "$public_net" == "Enabled" ] && echo true || echo false)\n  data_endpoint_enabled         = ${data_endpoints}\n  zone_redundancy_enabled       = $([ "$zone_redundancy" == "Enabled" ] && echo true || echo false)"
      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\"\n  }"
      fi
      if [[ "$retention_enabled" == "enabled" ]]; then
        attrs="${attrs}\n\n  retention_policy {\n    days    = ${retention_days}\n    enabled = true\n  }"
      fi
      if [[ "$trust_policy" == "enabled" ]]; then
        attrs="${attrs}\n\n  trust_policy {\n    enabled = true\n  }"
      fi
      [[ -n "$geo_repl" ]] && attrs="${attrs}\n\n  # georeplications: ${geo_repl}\n  # Add azurerm_container_registry_replication resources per location"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "acr" "azurerm_container_registry" "$rid" \
        "$(sanitise_label "acr_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" acr list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} container registries"

    # ── Container Instances ────────────────────────────────────────────────────
    log_section "Container Instances (ACI) [${RG}]"
    COUNT=0
    while IFS= read -r aci; do
      [[ -z "$aci" || "$aci" == "null" ]] && continue
      name=$(echo "$aci"        | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$aci"         | jq -r '.id // ""')
      loc=$(echo "$aci"         | jq -r '.location // ""')
      state=$(echo "$aci"       | jq -r '.provisioningState // ""')
      os=$(echo "$aci"          | jq -r '.osType // "Linux"')
      ip_type=$(echo "$aci"     | jq -r '.ipAddress.type // "Public"')
      ip_addr=$(echo "$aci"     | jq -r '.ipAddress.ip // ""')
      restart=$(echo "$aci"     | jq -r '.restartPolicy // "Always"')
      sku=$(echo "$aci"         | jq -r '.sku // "Standard"')
      subnet_ids=$(echo "$aci"  | jq -r '[.subnetIds[]?.id] | join(",")' 2>/dev/null || true)
      dns_label=$(echo "$aci"   | jq -r '.ipAddress.dnsNameLabel // ""')
      identity_type=$(echo "$aci" | jq -r '.identity.type // ""')
      tags=$(echo "$aci"        | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      # Container details
      container_name=$(echo "$aci" | jq -r '.containers[0].name // ""')
      image=$(echo "$aci"          | jq -r '.containers[0].image // ""')
      cpu=$(echo "$aci"            | jq -r '.containers[0].resources.requests.cpu // 1')
      mem=$(echo "$aci"            | jq -r '.containers[0].resources.requests.memoryInGB // 1.5')
      ports=$(echo "$aci"          | jq -r '[.containers[0].ports[]?.port] | join(",")' 2>/dev/null || true)
      container_count=$(echo "$aci" | jq '.containers | length' 2>/dev/null || echo 1)

      add_csv "Container Instance" "$name" "$name" "$loc" "$rid" "$state" \
        "OS=${os},IP=${ip_addr},IPType=${ip_type},Containers=${container_count},Image=${image},CPU=${cpu},Memory=${mem}GB,ResourceGroup=${RG}"

      attrs="  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  ip_address_type     = \"${ip_type}\"\n  os_type             = \"${os}\"\n  restart_policy      = \"${restart}\"\n  sku                 = \"${sku}\""
      [[ -n "$dns_label" ]] && attrs="${attrs}\n  dns_name_label      = \"${dns_label}\""
      if [[ -n "$subnet_ids" ]]; then
        sn_list=$(echo "$subnet_ids" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        attrs="${attrs}\n  subnet_ids          = [${sn_list}]"
      fi
      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\"\n  }"
      fi
      attrs="${attrs}\n\n  container {\n    name   = \"${container_name}\"\n    image  = \"${image}\"\n    cpu    = \"${cpu}\"\n    memory = \"${mem}\""
      if [[ -n "$ports" ]]; then
        for p in $(echo "$ports" | tr ',' ' '); do
          attrs="${attrs}\n    ports {\n      port     = ${p}\n      protocol = \"TCP\"\n    }"
        done
      fi
      attrs="${attrs}\n  }"
      [[ "$container_count" -gt 1 ]] && attrs="${attrs}\n\n  # TODO: add ${container_count} container blocks total"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "aci" "azurerm_container_group" "$rid" \
        "$(sanitise_label "aci_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" container group list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} container instances"

    # ── App Service Plans ──────────────────────────────────────────────────────
    log_section "App Service Plans [${RG}]"
    COUNT=0
    while IFS= read -r plan; do
      [[ -z "$plan" || "$plan" == "null" ]] && continue
      name=$(echo "$plan"    | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$plan"     | jq -r '.id // ""')
      loc=$(echo "$plan"     | jq -r '.location // ""')
      sku=$(echo "$plan"     | jq -r '.sku.name // ""')
      tier=$(echo "$plan"    | jq -r '.sku.tier // ""')
      capacity=$(echo "$plan" | jq -r '.sku.capacity // 1')
      kind=$(echo "$plan"    | jq -r '.kind // "app"')
      state=$(echo "$plan"   | jq -r '.provisioningState // ""')
      per_site=$(echo "$plan" | jq -r '.perSiteScaling // false')
      zone_bal=$(echo "$plan" | jq -r '.zoneRedundant // false')
      max_burst=$(echo "$plan" | jq -r '.maximumElasticWorkerCount // ""')
      tags=$(echo "$plan"    | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      # os_type: Windows vs Linux
      os_type=$([ "$kind" == "linux" ] || [[ "$kind" == *"Linux"* ]] && echo "Linux" || echo "Windows")

      add_csv "App Service Plan" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},Tier=${tier},Capacity=${capacity},Kind=${kind},ZoneRedundant=${zone_bal},ResourceGroup=${RG}"

      attrs="  name                         = \"${name}\"\n  resource_group_name          = \"${RG}\"\n  location                     = \"${loc}\"\n  os_type                      = \"${os_type}\"\n  sku_name                     = \"${sku}\"\n  per_site_scaling_enabled     = ${per_site}\n  zone_balancing_enabled       = ${zone_bal}"
      [[ -n "$max_burst" ]] && attrs="${attrs}\n  maximum_elastic_worker_count = ${max_burst}"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "appservice" "azurerm_service_plan" "$rid" \
        "$(sanitise_label "asp_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" appservice plan list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} app service plans"

    # ── App Services / Web Apps ────────────────────────────────────────────────
    log_section "App Services / Web Apps [${RG}]"
    COUNT=0
    while IFS= read -r app; do
      [[ -z "$app" || "$app" == "null" ]] && continue
      name=$(echo "$app"       | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$app"        | jq -r '.id // ""')
      loc=$(echo "$app"        | jq -r '.location // ""')
      kind=$(echo "$app"       | jq -r '.kind // ""')
      state=$(echo "$app"      | jq -r '.state // ""')
      hostname=$(echo "$app"   | jq -r '.defaultHostName // ""')
      plan_id=$(echo "$app"    | jq -r '.appServicePlanId // ""')
      https_only=$(echo "$app" | jq -r '.httpsOnly // false')
      client_cert=$(echo "$app" | jq -r '.clientCertEnabled // false')
      client_affinity=$(echo "$app" | jq -r '.clientAffinityEnabled // false')
      public_net=$(echo "$app" | jq -r '.publicNetworkAccess // "Enabled"')
      identity_type=$(echo "$app" | jq -r '.identity.type // ""')

      # Site config
      SITE_CONFIG=$(az_sub "$SUB_ID" webapp config show \
        --name "$name" --resource-group "$RG" 2>/dev/null || echo "{}")
      linux_fx=$(echo "$SITE_CONFIG"     | jq -r '.linuxFxVersion // ""')
      windows_fx=$(echo "$SITE_CONFIG"   | jq -r '.windowsFxVersion // ""')
      php_ver=$(echo "$SITE_CONFIG"      | jq -r '.phpVersion // ""')
      node_ver=$(echo "$SITE_CONFIG"     | jq -r '.nodeVersion // ""')
      python_ver=$(echo "$SITE_CONFIG"   | jq -r '.pythonVersion // ""')
      dotnet_ver=$(echo "$SITE_CONFIG"   | jq -r '.netFrameworkVersion // ""')
      always_on=$(echo "$SITE_CONFIG"    | jq -r '.alwaysOn // false')
      http2=$(echo "$SITE_CONFIG"        | jq -r '.http20Enabled // false')
      min_tls=$(echo "$SITE_CONFIG"      | jq -r '.minTlsVersion // "1.2"')
      ftps_state=$(echo "$SITE_CONFIG"   | jq -r '.ftpsState // "Disabled"')
      ws_enabled=$(echo "$SITE_CONFIG"   | jq -r '.webSocketsEnabled // false')
      health_check=$(echo "$SITE_CONFIG" | jq -r '.healthCheckPath // ""')

      tags=$(echo "$app" | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      # Choose correct TF resource based on OS
      tf_resource=$([ "$kind" == *"linux"* ] || [[ "$linux_fx" != "" ]] \
        && echo "azurerm_linux_web_app" || echo "azurerm_windows_web_app")

      add_csv "App Service" "$name" "$name" "$loc" "$rid" "$state" \
        "Kind=${kind},Hostname=${hostname},LinuxFX=${linux_fx},AlwaysOn=${always_on},HTTPSOnly=${https_only},ResourceGroup=${RG}"

      attrs="  name                    = \"${name}\"\n  resource_group_name     = \"${RG}\"\n  location                = \"${loc}\"\n  service_plan_id         = \"${plan_id}\"\n  https_only              = ${https_only}\n  client_affinity_enabled = ${client_affinity}\n  client_certificate_enabled = ${client_cert}"
      attrs="${attrs}\n\n  site_config {\n    always_on         = ${always_on}\n    http2_enabled     = ${http2}\n    minimum_tls_version = \"${min_tls}\"\n    ftps_state        = \"${ftps_state}\"\n    websockets_enabled = ${ws_enabled}"
      [[ -n "$linux_fx" && "$linux_fx" != "null" ]] && \
        attrs="${attrs}\n    linux_fx_version  = \"${linux_fx}\""
      [[ -n "$health_check" ]] && \
        attrs="${attrs}\n    health_check_path = \"${health_check}\""
      attrs="${attrs}\n  }"
      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\"\n  }"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "appservice" "$tf_resource" "$rid" \
        "$(sanitise_label "webapp_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" webapp list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} web apps"

    # ── Function Apps ──────────────────────────────────────────────────────────
    log_section "Function Apps [${RG}]"
    COUNT=0
    while IFS= read -r fn; do
      [[ -z "$fn" || "$fn" == "null" ]] && continue
      name=$(echo "$fn"        | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$fn"         | jq -r '.id // ""')
      loc=$(echo "$fn"         | jq -r '.location // ""')
      state=$(echo "$fn"       | jq -r '.state // ""')
      kind=$(echo "$fn"        | jq -r '.kind // ""')
      plan_id=$(echo "$fn"     | jq -r '.appServicePlanId // ""')
      https_only=$(echo "$fn"  | jq -r '.httpsOnly // false')
      identity_type=$(echo "$fn" | jq -r '.identity.type // ""')

      # Site config
      FN_CONFIG=$(az_sub "$SUB_ID" functionapp config show \
        --name "$name" --resource-group "$RG" 2>/dev/null || echo "{}")
      linux_fx=$(echo "$FN_CONFIG"   | jq -r '.linuxFxVersion // ""')
      always_on=$(echo "$FN_CONFIG"  | jq -r '.alwaysOn // false')
      min_tls=$(echo "$FN_CONFIG"    | jq -r '.minTlsVersion // "1.2"')
      ftps_state=$(echo "$FN_CONFIG" | jq -r '.ftpsState // "Disabled"')

      # App settings (keys only — values may contain connection strings/secrets)
      FN_SETTINGS=$(az_sub "$SUB_ID" functionapp config appsettings list \
        --name "$name" --resource-group "$RG" 2>/dev/null || echo "[]")
      settings_keys=$(echo "$FN_SETTINGS" | jq -r '[.[].name] | join(",")' 2>/dev/null || true)
      storage_acct=$(echo "$FN_SETTINGS"  | jq -r '.[] | select(.name=="AzureWebJobsStorage") | .value // ""' 2>/dev/null || true)

      tags=$(echo "$fn" | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      tf_resource=$([[ "$kind" == *"linux"* ]] && echo "azurerm_linux_function_app" \
        || echo "azurerm_windows_function_app")

      add_csv "Function App" "$name" "$name" "$loc" "$rid" "$state" \
        "Kind=${kind},LinuxFX=${linux_fx},AlwaysOn=${always_on},HTTPSOnly=${https_only},SettingsKeys=${settings_keys},ResourceGroup=${RG}"

      attrs="  name                       = \"${name}\"\n  resource_group_name        = \"${RG}\"\n  location                   = \"${loc}\"\n  service_plan_id            = \"${plan_id}\"\n  https_only                 = ${https_only}"
      # storage_account_name extracted from connection string is unreliable; leave as placeholder
      attrs="${attrs}\n  storage_account_name       = \"<storage-account-name>\"\n  storage_account_access_key = \"<set via Key Vault reference — never hardcode>\""
      attrs="${attrs}\n\n  site_config {\n    always_on   = ${always_on}\n    ftps_state  = \"${ftps_state}\"\n    minimum_tls_version = \"${min_tls}\""
      [[ -n "$linux_fx" && "$linux_fx" != "null" ]] && \
        attrs="${attrs}\n    application_stack {\n      # linux_fx_version = \"${linux_fx}\"\n    }"
      attrs="${attrs}\n  }"
      if [[ -n "$settings_keys" ]]; then
        attrs="${attrs}\n\n  # App setting keys (values must be set via tfvars/Key Vault): ${settings_keys}"
      fi
      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\"\n  }"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "functions" "$tf_resource" "$rid" \
        "$(sanitise_label "func_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" functionapp list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} function apps"

    # ── Service Bus Namespaces ─────────────────────────────────────────────────
    log_section "Service Bus Namespaces [${RG}]"
    COUNT=0
    while IFS= read -r sb; do
      [[ -z "$sb" || "$sb" == "null" ]] && continue
      name=$(echo "$sb"       | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$sb"        | jq -r '.id // ""')
      loc=$(echo "$sb"        | jq -r '.location // ""')
      sku=$(echo "$sb"        | jq -r '.sku.name // ""')
      tier=$(echo "$sb"       | jq -r '.sku.tier // ""')
      capacity=$(echo "$sb"   | jq -r '.sku.capacity // 1')
      state=$(echo "$sb"      | jq -r '.provisioningState // ""')
      zone_redundant=$(echo "$sb" | jq -r '.zoneRedundant // false')
      public_net=$(echo "$sb" | jq -r '.publicNetworkAccess // "Enabled"')
      min_tls=$(echo "$sb"    | jq -r '.minimumTlsVersion // "1.2"')
      identity_type=$(echo "$sb" | jq -r '.identity.type // ""')
      endpoint=$(echo "$sb"   | jq -r '.serviceBusEndpoint // ""')

      # Queue/topic counts
      queue_count=$(az_sub "$SUB_ID" servicebus queue list \
        --namespace-name "$name" --resource-group "$RG" 2>/dev/null \
        | jq 'length' 2>/dev/null || echo 0)
      topic_count=$(az_sub "$SUB_ID" servicebus topic list \
        --namespace-name "$name" --resource-group "$RG" 2>/dev/null \
        | jq 'length' 2>/dev/null || echo 0)

      tags=$(echo "$sb" | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Service Bus Namespace" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},Tier=${tier},ZoneRedundant=${zone_redundant},Queues=${queue_count},Topics=${topic_count},ResourceGroup=${RG}"

      attrs="  name                         = \"${name}\"\n  resource_group_name          = \"${RG}\"\n  location                     = \"${loc}\"\n  sku                          = \"${sku}\"\n  zone_redundant               = ${zone_redundant}\n  public_network_access_enabled = $([ "$public_net" == "Enabled" ] && echo true || echo false)\n  minimum_tls_version          = \"${min_tls}\""
      [[ "$sku" == "Premium" ]] && attrs="${attrs}\n  capacity                     = ${capacity}"
      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\"\n  }"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"
      [[ "$queue_count" -gt 0 ]] && attrs="${attrs}\n\n  # ${queue_count} queues — add azurerm_servicebus_queue resources"
      [[ "$topic_count" -gt 0 ]] && attrs="${attrs}\n  # ${topic_count} topics — add azurerm_servicebus_topic resources"

      emit_resource "servicebus" "azurerm_servicebus_namespace" "$rid" \
        "$(sanitise_label "sb_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" servicebus namespace list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} Service Bus namespaces"

    # ── Event Hub Namespaces ───────────────────────────────────────────────────
    log_section "Event Hub Namespaces [${RG}]"
    COUNT=0
    while IFS= read -r eh; do
      [[ -z "$eh" || "$eh" == "null" ]] && continue
      name=$(echo "$eh"         | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$eh"          | jq -r '.id // ""')
      loc=$(echo "$eh"          | jq -r '.location // ""')
      sku=$(echo "$eh"          | jq -r '.sku.name // ""')
      capacity=$(echo "$eh"     | jq -r '.sku.capacity // 1')
      state=$(echo "$eh"        | jq -r '.provisioningState // ""')
      auto_inflate=$(echo "$eh" | jq -r '.isAutoInflateEnabled // false')
      max_units=$(echo "$eh"    | jq -r '.maximumThroughputUnits // 0')
      zone_redundant=$(echo "$eh" | jq -r '.zoneRedundant // false')
      kafka_enabled=$(echo "$eh"  | jq -r '.kafkaEnabled // false')
      public_net=$(echo "$eh"     | jq -r '.publicNetworkAccess // "Enabled"')
      identity_type=$(echo "$eh"  | jq -r '.identity.type // ""')

      eh_count=$(az_sub "$SUB_ID" eventhubs eventhub list \
        --namespace-name "$name" --resource-group "$RG" 2>/dev/null \
        | jq 'length' 2>/dev/null || echo 0)

      tags=$(echo "$eh" | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Event Hub Namespace" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},Capacity=${capacity},AutoInflate=${auto_inflate},MaxUnits=${max_units},Kafka=${kafka_enabled},EventHubs=${eh_count},ResourceGroup=${RG}"

      attrs="  name                     = \"${name}\"\n  resource_group_name      = \"${RG}\"\n  location                 = \"${loc}\"\n  sku                      = \"${sku}\"\n  capacity                 = ${capacity}\n  auto_inflate_enabled     = ${auto_inflate}\n  zone_redundant           = ${zone_redundant}\n  kafka_enabled            = ${kafka_enabled}\n  public_network_access_enabled = $([ "$public_net" == "Enabled" ] && echo true || echo false)"
      [[ "$auto_inflate" == "true" && "$max_units" -gt 0 ]] 2>/dev/null && \
        attrs="${attrs}\n  maximum_throughput_units = ${max_units}"
      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\"\n  }"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"
      [[ "$eh_count" -gt 0 ]] && attrs="${attrs}\n\n  # ${eh_count} event hubs — add azurerm_eventhub resources"

      emit_resource "eventhub" "azurerm_eventhub_namespace" "$rid" \
        "$(sanitise_label "eh_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" eventhubs namespace list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} Event Hub namespaces"

    # ── Log Analytics Workspaces ───────────────────────────────────────────────
    log_section "Log Analytics Workspaces [${RG}]"
    COUNT=0
    while IFS= read -r ws; do
      [[ -z "$ws" || "$ws" == "null" ]] && continue
      name=$(echo "$ws"        | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$ws"         | jq -r '.id // ""')
      loc=$(echo "$ws"         | jq -r '.location // ""')
      sku=$(echo "$ws"         | jq -r '.sku.name // "PerGB2018"')
      state=$(echo "$ws"       | jq -r '.provisioningState // ""')
      retention=$(echo "$ws"   | jq -r '.retentionInDays // 30')
      daily_cap=$(echo "$ws"   | jq -r '.workspaceCapping.dailyQuotaGb // -1')
      public_ingestion=$(echo "$ws" | jq -r '.publicNetworkAccessForIngestion // "Enabled"')
      public_query=$(echo "$ws"     | jq -r '.publicNetworkAccessForQuery // "Enabled"')
      cmk_id=$(echo "$ws"           | jq -r '.customerId // ""')
      tags=$(echo "$ws"        | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "Log Analytics Workspace" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},RetentionDays=${retention},DailyCapGB=${daily_cap},PublicIngestion=${public_ingestion},ResourceGroup=${RG}"

      attrs="  name                                = \"${name}\"\n  resource_group_name                 = \"${RG}\"\n  location                            = \"${loc}\"\n  sku                                 = \"${sku}\"\n  retention_in_days                   = ${retention}\n  internet_ingestion_enabled          = $([ "$public_ingestion" == "Enabled" ] && echo true || echo false)\n  internet_query_enabled              = $([ "$public_query" == "Enabled" ] && echo true || echo false)"
      [[ "$daily_cap" != "-1" && "$daily_cap" != "null" ]] && \
        attrs="${attrs}\n  daily_quota_gb                      = ${daily_cap}"
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "monitoring" "azurerm_log_analytics_workspace" "$rid" \
        "$(sanitise_label "law_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" monitor log-analytics workspace list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} log analytics workspaces"

    # ── API Management ─────────────────────────────────────────────────────────
    log_section "API Management Services [${RG}]"
    COUNT=0
    while IFS= read -r apim; do
      [[ -z "$apim" || "$apim" == "null" ]] && continue
      name=$(echo "$apim"         | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$apim"          | jq -r '.id // ""')
      loc=$(echo "$apim"          | jq -r '.location // ""')
      sku=$(echo "$apim"          | jq -r '.sku.name // ""')
      capacity=$(echo "$apim"     | jq -r '.sku.capacity // 1')
      state=$(echo "$apim"        | jq -r '.provisioningState // ""')
      publisher_name=$(echo "$apim"  | jq -r '.publisherName // ""')
      publisher_email=$(echo "$apim" | jq -r '.publisherEmail // ""')
      gateway_url=$(echo "$apim"     | jq -r '.gatewayUrl // ""')
      portal_url=$(echo "$apim"      | jq -r '.developerPortalUrl // ""')
      mgmt_url=$(echo "$apim"        | jq -r '.managementApiUrl // ""')
      vnet_type=$(echo "$apim"       | jq -r '.virtualNetworkType // "None"')
      subnet_id=$(echo "$apim"       | jq -r '.virtualNetworkConfiguration.subnetResourceId // ""')
      public_net=$(echo "$apim"      | jq -r '.publicNetworkAccess // "Enabled"')
      zones=$(echo "$apim"           | jq -r '[.zones[]?] | join(",")' 2>/dev/null || true)
      identity_type=$(echo "$apim"   | jq -r '.identity.type // ""')
      min_api_ver=$(echo "$apim"     | jq -r '.apiVersionConstraint.minApiVersion // ""')
      tags=$(echo "$apim"            | jq -c '.tags // {}')
      tags_hcl=$(render_tags_hcl "$tags")

      add_csv "API Management" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},Capacity=${capacity},GatewayURL=${gateway_url},VNetType=${vnet_type},PublicNetwork=${public_net},ResourceGroup=${RG}"

      attrs="  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  publisher_name      = \"${publisher_name}\"\n  publisher_email     = \"${publisher_email}\"\n  sku_name            = \"${sku}_${capacity}\"\n  virtual_network_type = \"${vnet_type}\""
      [[ "$public_net" == "Disabled" ]] && \
        attrs="${attrs}\n  public_network_access_enabled = false"
      if [[ -n "$subnet_id" && "$vnet_type" != "None" ]]; then
        attrs="${attrs}\n\n  virtual_network_configuration {\n    subnet_id = \"${subnet_id}\"\n  }"
      fi
      if [[ -n "$identity_type" && "$identity_type" != "null" ]]; then
        attrs="${attrs}\n\n  identity {\n    type = \"${identity_type}\"\n  }"
      fi
      if [[ -n "$min_api_ver" ]]; then
        attrs="${attrs}\n\n  protocols {\n    enable_http2 = true\n  }\n  min_api_version = \"${min_api_ver}\""
      fi
      if [[ -n "$zones" ]]; then
        zone_list=$(echo "$zones" | tr ',' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        attrs="${attrs}\n  zones = [${zone_list}]"
      fi
      [[ -n "$tags_hcl" ]] && attrs="${attrs}\n${tags_hcl}"

      emit_resource "apim" "azurerm_api_management" "$rid" \
        "$(sanitise_label "apim_${name}")" "$loc" "$(printf '%b' "$attrs")"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" apim list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} API Management services"

  done  # end resource groups loop

done  # end subscriptions loop

# =============================================================================
# SUMMARY
# =============================================================================
TF_FILE_COUNT=$(find "${TF_DIR}" -name "*.tf" ! -name "imports.tf" 2>/dev/null | wc -l | tr -d ' ')
IMPORT_BLOCK_COUNT=0
if $IMPORT_BLOCKS && [[ -f "$IMPORTS_FILE" ]]; then
  IMPORT_BLOCK_COUNT=$(grep -c '^import {' "$IMPORTS_FILE" 2>/dev/null || true)
fi

cat > "${SUMMARY_FILE}" <<SUMMARY
Azure Infrastructure Inventory Summary  (v2)
=============================================
Tenant ID       : ${TENANT_ID}
Subscription(s) : ${SUBSCRIPTION_IDS[*]}
Generated       : ${TIMESTAMP}
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
6. terraform apply   → performs the imports
7. terraform plan    → should show zero drift when done

Legacy workflow (any Terraform version)
----------------------------------------
For each resource, run:
  terraform import <resource>.<label> <azure_resource_id>
The Azure resource ID is the long /subscriptions/.../resourceGroups/...
path shown in the CSV column AzureResourceID.

Tips
----
- Passwords / connection strings are NEVER exported — use Key Vault references
- Review all # TODO comments before applying
- Set up remote state (Azure Blob Storage backend) before importing at scale
- Use -parallelism=1 for large imports to avoid ARM API throttling
- azuread_* resources require the AzureAD / Entra provider in addition to azurerm

Example backend config:
  terraform {
    backend "azurerm" {
      resource_group_name  = "tfstate-rg"
      storage_account_name = "tfstateXXXXXX"
      container_name       = "tfstate"
      key                  = "prod.terraform.tfstate"
    }
  }
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
