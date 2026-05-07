#!/usr/bin/env bash
# =============================================================================
# Azure Infrastructure Inventory Script
# Discovers resources across your Azure subscription and outputs:
#   1. CSV  → azure_inventory_<timestamp>.csv
#   2. Terraform HCL stubs → terraform_stubs/
# =============================================================================
# REQUIREMENTS: azure-cli (az), jq
# USAGE:
#   chmod +x azure_inventory.sh
#   ./azure_inventory.sh                                    # current subscription
#   ./azure_inventory.sh --subscription <id-or-name>        # named subscription
#   ./azure_inventory.sh --resource-group <rg>              # limit to one RG
#   ./azure_inventory.sh --all-subscriptions                # scan every subscription
# =============================================================================

# No set -e — we handle errors per-command so one failure never kills the run
set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
SUBSCRIPTION=""
RESOURCE_GROUP=""
ALL_SUBSCRIPTIONS=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="azure_inventory_${TIMESTAMP}"
CSV_FILE="${OUT_DIR}/azure_inventory_${TIMESTAMP}.csv"
TF_DIR="${OUT_DIR}/terraform_stubs"
SUMMARY_FILE="${OUT_DIR}/summary_${TIMESTAMP}.txt"
TOTAL_RESOURCES=0
SUBSCRIPTION_IDS=()

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --subscription)      SUBSCRIPTION="$2";    shift 2 ;;
    --resource-group)    RESOURCE_GROUP="$2";  shift 2 ;;
    --all-subscriptions) ALL_SUBSCRIPTIONS=true; shift ;;
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

# ── Helper: safe az call — never exits on error ───────────────────────────────
az_safe() {
  # Usage: az_safe [az args...]
  az "$@" --output json 2>/dev/null || echo "null"
}

az_sub() {
  # Usage: az_sub SUB_ID [az args...]
  local sub="$1"; shift
  az "$@" --subscription "$sub" --output json 2>/dev/null || echo "null"
}

az_sub_rg() {
  # Usage: az_sub_rg SUB_ID RG [az args...]
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
  echo "\"${type}\",\"${id}\",\"${name}\",\"${location}\",\"${resource_id}\",\"${state}\",\"${attrs}\"" >> "${CSV_FILE}"
  ((TOTAL_RESOURCES++)) || true
}

sanitise_label() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | sed 's/^[0-9]/_&/' | cut -c1-60
}

get_tag() {
  # Usage: get_tag <json_tags_object> <key>
  echo "$1" | jq -r --arg k "$2" '.[$k] // ""' 2>/dev/null || echo ""
}

write_tf_stub() {
  local service="$1" resource="$2" id="$3" label="$4" location="$5" attrs="${6:-}"
  local tf_file="${TF_DIR}/${service}.tf"
  if [[ ! -f "$tf_file" ]]; then
    cat >> "$tf_file" <<EOF
# Auto-generated Terraform import stubs — Subscription: ${SUBSCRIPTION_ID} — ${TIMESTAMP}
# Run: terraform import <resource>.<label> <id>

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.0" }
  }
}

EOF
  fi
  printf '# terraform import %s.%s %s\nresource "%s" "%s" {\n  # location = "%s"\n%s\n  lifecycle { prevent_destroy = true }\n}\n\n' \
    "$resource" "$label" "$id" "$resource" "$label" "$location" "$attrs" >> "$tf_file"
}

# ── Auth check ────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│      Azure Infrastructure Inventory Tool        │${NC}"
echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────┘${NC}"
echo ""

IDENTITY=$(az_safe account show)
if [[ "$IDENTITY" == "null" ]]; then
  echo -e "${RED}ERROR: Could not authenticate. Run 'az login' first.${NC}"
  exit 1
fi

TENANT_ID=$(echo "$IDENTITY" | jq -r '.tenantId')
CALLER_USER=$(echo "$IDENTITY" | jq -r '.user.name // .user.type')
echo -e "${GREEN}✓ Authenticated${NC}"
echo -e "  Tenant : ${BOLD}${TENANT_ID}${NC}"
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
echo ""

# ── Setup output ──────────────────────────────────────────────────────────────
mkdir -p "${TF_DIR}"
echo "ResourceType,ResourceID,Name,Location,AzureResourceID,State,AdditionalAttributes" > "${CSV_FILE}"

# =============================================================================
# PER-SUBSCRIPTION LOOP
# =============================================================================

for SUB_ID in "${SUBSCRIPTION_IDS[@]}"; do

  SUBSCRIPTION_ID="$SUB_ID"
  SUB_NAME=$(az_sub "$SUB_ID" account show | jq -r '.name // "unknown"')

  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  Subscription: ${SUB_NAME} (${SUB_ID})${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # ── Resource Groups ──────────────────────────────────────────────────────────
  log_section "Resource Groups"
  COUNT=0
  RG_FILTER_ARGS=()
  [[ -n "$RESOURCE_GROUP" ]] && RG_FILTER_ARGS=(--name "$RESOURCE_GROUP")
  while IFS= read -r rg; do
    [[ -z "$rg" || "$rg" == "null" ]] && continue
    name=$(echo "$rg"     | jq -r '.name // ""');     [[ -z "$name" ]] && continue
    loc=$(echo "$rg"      | jq -r '.location // ""')
    state=$(echo "$rg"    | jq -r '.properties.provisioningState // ""')
    rid=$(echo "$rg"      | jq -r '.id // ""')
    add_csv "Resource Group" "$name" "$name" "$loc" "$rid" "$state" ""
    write_tf_stub "resource_groups" "azurerm_resource_group" "$rid" \
      "$(sanitise_label "rg_${name}")" "$loc" \
      "  name     = \"${name}\"\n  location = \"${loc}\""
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" group list "${RG_FILTER_ARGS[@]}" | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} resource groups"

  # Determine which RGs to iterate over
  if [[ -n "$RESOURCE_GROUP" ]]; then
    RESOURCE_GROUPS=("$RESOURCE_GROUP")
  else
    mapfile -t RESOURCE_GROUPS < <(az_sub "$SUB_ID" group list --query '[].name' | jq -r '.[]' 2>/dev/null | sort || true)
  fi

  # =============================================================================
  # GLOBAL / SUBSCRIPTION-LEVEL RESOURCES
  # =============================================================================

  # ── Entra ID (AAD) Users ─────────────────────────────────────────────────────
  log_section "Entra ID Users"
  COUNT=0
  while IFS= read -r user; do
    [[ -z "$user" || "$user" == "null" ]] && continue
    upn=$(echo "$user"  | jq -r '.userPrincipalName // ""'); [[ -z "$upn" ]] && continue
    oid=$(echo "$user"  | jq -r '.id // ""')
    name=$(echo "$user" | jq -r '.displayName // ""')
    add_csv "Entra ID User" "$oid" "$name" "global" "/users/${oid}" "active" "UPN=${upn}"
    write_tf_stub "entra_users" "azurerm_user" "$oid" \
      "$(sanitise_label "user_${name}")" "global" \
      "  # user_principal_name = \"${upn}\""
    ((COUNT++)) || true
  done < <(az_safe ad user list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} Entra ID users"

  # ── Entra ID Service Principals / App Registrations ──────────────────────────
  log_section "Entra ID Service Principals"
  COUNT=0
  while IFS= read -r sp; do
    [[ -z "$sp" || "$sp" == "null" ]] && continue
    oid=$(echo "$sp"  | jq -r '.id // ""');          [[ -z "$oid" ]] && continue
    name=$(echo "$sp" | jq -r '.displayName // ""')
    type=$(echo "$sp" | jq -r '.servicePrincipalType // ""')
    add_csv "Service Principal" "$oid" "$name" "global" "/servicePrincipals/${oid}" "active" \
      "Type=${type}"
    write_tf_stub "entra_service_principals" "azurerm_service_principal" "$oid" \
      "$(sanitise_label "sp_${name}")" "global" \
      "  # display_name = \"${name}\""
    ((COUNT++)) || true
  done < <(az_safe ad sp list --all | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} service principals"

  # ── Role Assignments ──────────────────────────────────────────────────────────
  log_section "Role Assignments (subscription scope)"
  COUNT=0
  while IFS= read -r ra; do
    [[ -z "$ra" || "$ra" == "null" ]] && continue
    id=$(echo "$ra"          | jq -r '.id // ""');            [[ -z "$id" ]] && continue
    principal=$(echo "$ra"   | jq -r '.principalName // .principalId // ""')
    role=$(echo "$ra"        | jq -r '.roleDefinitionName // ""')
    scope=$(echo "$ra"       | jq -r '.scope // ""')
    add_csv "Role Assignment" "$id" "${role} → ${principal}" "global" "$id" "active" \
      "Role=${role},Principal=${principal},Scope=${scope}"
    write_tf_stub "role_assignments" "azurerm_role_assignment" "$id" \
      "$(sanitise_label "ra_${role}_${principal}")" "global" \
      "  # role_definition_name = \"${role}\"\n  # principal_id          = \"<object-id>\"\n  # scope                 = \"${scope}\""
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" role assignment list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} role assignments"

  # ── DNS Zones ─────────────────────────────────────────────────────────────────
  log_section "DNS Zones"
  COUNT=0
  while IFS= read -r zone; do
    [[ -z "$zone" || "$zone" == "null" ]] && continue
    name=$(echo "$zone"  | jq -r '.name // ""');  [[ -z "$name" ]] && continue
    rid=$(echo "$zone"   | jq -r '.id // ""')
    rg=$(echo "$zone"    | jq -r '.resourceGroup // ""')
    rcount=$(echo "$zone"| jq -r '.numberOfRecordSets // 0')
    add_csv "DNS Zone" "$name" "$name" "global" "$rid" "active" \
      "ResourceGroup=${rg},RecordSets=${rcount}"
    write_tf_stub "dns" "azurerm_dns_zone" "$rid" \
      "$(sanitise_label "dns_${name}")" "global" \
      "  name                = \"${name}\"\n  resource_group_name = \"${rg}\""
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" network dns zone list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} DNS zones"

  # ── Azure CDN / Front Door ────────────────────────────────────────────────────
  log_section "CDN Profiles"
  COUNT=0
  while IFS= read -r cdn; do
    [[ -z "$cdn" || "$cdn" == "null" ]] && continue
    name=$(echo "$cdn"  | jq -r '.name // ""');  [[ -z "$name" ]] && continue
    rid=$(echo "$cdn"   | jq -r '.id // ""')
    rg=$(echo "$cdn"    | jq -r '.resourceGroup // ""')
    sku=$(echo "$cdn"   | jq -r '.sku.name // ""')
    state=$(echo "$cdn" | jq -r '.resourceState // ""')
    add_csv "CDN Profile" "$name" "$name" "global" "$rid" "$state" \
      "SKU=${sku},ResourceGroup=${rg}"
    write_tf_stub "cdn" "azurerm_cdn_profile" "$rid" \
      "$(sanitise_label "cdn_${name}")" "global" \
      "  name                = \"${name}\"\n  resource_group_name = \"${rg}\"\n  sku                 = \"${sku}\""
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" cdn profile list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} CDN profiles"

  # ── Key Vaults (subscription) ─────────────────────────────────────────────────
  log_section "Key Vaults"
  COUNT=0
  while IFS= read -r kv; do
    [[ -z "$kv" || "$kv" == "null" ]] && continue
    name=$(echo "$kv"  | jq -r '.name // ""');  [[ -z "$name" ]] && continue
    rid=$(echo "$kv"   | jq -r '.id // ""')
    rg=$(echo "$kv"    | jq -r '.resourceGroup // ""')
    loc=$(echo "$kv"   | jq -r '.location // ""')
    add_csv "Key Vault" "$name" "$name" "$loc" "$rid" "active" \
      "ResourceGroup=${rg}"
    write_tf_stub "keyvault" "azurerm_key_vault" "$rid" \
      "$(sanitise_label "kv_${name}")" "$loc" \
      "  name                = \"${name}\"\n  resource_group_name = \"${rg}\"\n  location            = \"${loc}\"\n  # tenant_id           = \"${TENANT_ID}\"\n  # sku_name            = \"standard\""
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" keyvault list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} key vaults"

  # ── Storage Accounts (subscription) ───────────────────────────────────────────
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
    add_csv "Storage Account" "$name" "$name" "$loc" "$rid" "$state" \
      "Kind=${kind},SKU=${sku},ResourceGroup=${rg}"
    write_tf_stub "storage" "azurerm_storage_account" "$rid" \
      "$(sanitise_label "sa_${name}")" "$loc" \
      "  name                     = \"${name}\"\n  resource_group_name      = \"${rg}\"\n  location                 = \"${loc}\"\n  account_tier             = \"Standard\"\n  account_replication_type = \"LRS\""
    ((COUNT++)) || true
  done < <(az_sub "$SUB_ID" storage account list | jq -c '.[]?' 2>/dev/null || true)
  echo -e "  ${GREEN}✓${NC} ${COUNT} storage accounts"

  # =============================================================================
  # REGIONAL / RESOURCE GROUP RESOURCES
  # =============================================================================

  for RG in "${RESOURCE_GROUPS[@]}"; do
    echo ""
    echo -e "${BOLD}${CYAN}  ─── Resource Group: ${RG} ───${NC}"

    # ── Virtual Networks ─────────────────────────────────────────────────────
    log_section "Virtual Networks (VNets)"
    COUNT=0
    while IFS= read -r vnet; do
      [[ -z "$vnet" || "$vnet" == "null" ]] && continue
      name=$(echo "$vnet"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$vnet"   | jq -r '.id // ""')
      loc=$(echo "$vnet"   | jq -r '.location // ""')
      prefixes=$(echo "$vnet" | jq -r '.addressSpace.addressPrefixes | join(",")' 2>/dev/null || echo "")
      state=$(echo "$vnet" | jq -r '.provisioningState // ""')
      add_csv "Virtual Network" "$name" "$name" "$loc" "$rid" "$state" \
        "AddressSpace=${prefixes},ResourceGroup=${RG}"
      write_tf_stub "networking" "azurerm_virtual_network" "$rid" \
        "$(sanitise_label "vnet_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  address_space       = [\"${prefixes}\"]"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network vnet list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} virtual networks"

    # ── Subnets ───────────────────────────────────────────────────────────────
    log_section "Subnets"
    COUNT=0
    VNETS_IN_RG=$(az_sub_rg "$SUB_ID" "$RG" network vnet list | jq -r '.[].name' 2>/dev/null || true)
    while IFS= read -r vnet_name; do
      [[ -z "$vnet_name" ]] && continue
      while IFS= read -r subnet; do
        [[ -z "$subnet" || "$subnet" == "null" ]] && continue
        sname=$(echo "$subnet"  | jq -r '.name // ""');  [[ -z "$sname" ]] && continue
        rid=$(echo "$subnet"    | jq -r '.id // ""')
        prefix=$(echo "$subnet" | jq -r '.addressPrefix // ""')
        add_csv "Subnet" "${vnet_name}/${sname}" "$sname" "regional" "$rid" "active" \
          "VNet=${vnet_name},Prefix=${prefix},ResourceGroup=${RG}"
        write_tf_stub "networking" "azurerm_subnet" "$rid" \
          "$(sanitise_label "subnet_${vnet_name}_${sname}")" "regional" \
          "  name                 = \"${sname}\"\n  resource_group_name  = \"${RG}\"\n  virtual_network_name = \"${vnet_name}\"\n  address_prefixes     = [\"${prefix}\"]"
        ((COUNT++)) || true
      done < <(az_sub "$SUB_ID" network vnet subnet list \
          --vnet-name "$vnet_name" --resource-group "$RG" \
          --output json 2>/dev/null | jq -c '.[]?' || true)
    done <<< "$VNETS_IN_RG"
    echo -e "  ${GREEN}✓${NC} ${COUNT} subnets"

    # ── Network Security Groups ───────────────────────────────────────────────
    log_section "Network Security Groups (NSGs)"
    COUNT=0
    while IFS= read -r nsg; do
      [[ -z "$nsg" || "$nsg" == "null" ]] && continue
      name=$(echo "$nsg"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$nsg"   | jq -r '.id // ""')
      loc=$(echo "$nsg"   | jq -r '.location // ""')
      state=$(echo "$nsg" | jq -r '.provisioningState // ""')
      add_csv "Network Security Group" "$name" "$name" "$loc" "$rid" "$state" \
        "ResourceGroup=${RG}"
      write_tf_stub "networking" "azurerm_network_security_group" "$rid" \
        "$(sanitise_label "nsg_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network nsg list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} NSGs"

    # ── Public IP Addresses ───────────────────────────────────────────────────
    log_section "Public IP Addresses"
    COUNT=0
    while IFS= read -r pip; do
      [[ -z "$pip" || "$pip" == "null" ]] && continue
      name=$(echo "$pip"    | jq -r '.name // ""');  [[ -z "$name" ]] && continue
      rid=$(echo "$pip"     | jq -r '.id // ""')
      loc=$(echo "$pip"     | jq -r '.location // ""')
      ip=$(echo "$pip"      | jq -r '.ipAddress // "unassigned"')
      sku=$(echo "$pip"     | jq -r '.sku.name // ""')
      alloc=$(echo "$pip"   | jq -r '.publicIPAllocationMethod // ""')
      state=$(echo "$pip"   | jq -r '.provisioningState // ""')
      add_csv "Public IP" "$name" "$name" "$loc" "$rid" "$state" \
        "IP=${ip},SKU=${sku},Allocation=${alloc},ResourceGroup=${RG}"
      write_tf_stub "networking" "azurerm_public_ip" "$rid" \
        "$(sanitise_label "pip_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  allocation_method   = \"${alloc}\"\n  sku                 = \"${sku}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network public-ip list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} public IPs"

    # ── Route Tables ──────────────────────────────────────────────────────────
    log_section "Route Tables"
    COUNT=0
    while IFS= read -r rt; do
      [[ -z "$rt" || "$rt" == "null" ]] && continue
      name=$(echo "$rt"  | jq -r '.name // ""');  [[ -z "$name" ]] && continue
      rid=$(echo "$rt"   | jq -r '.id // ""')
      loc=$(echo "$rt"   | jq -r '.location // ""')
      state=$(echo "$rt" | jq -r '.provisioningState // ""')
      add_csv "Route Table" "$name" "$name" "$loc" "$rid" "$state" "ResourceGroup=${RG}"
      write_tf_stub "networking" "azurerm_route_table" "$rid" \
        "$(sanitise_label "rt_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network route-table list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} route tables"

    # ── Virtual Machines ──────────────────────────────────────────────────────
    log_section "Virtual Machines"
    COUNT=0
    while IFS= read -r vm; do
      [[ -z "$vm" || "$vm" == "null" ]] && continue
      name=$(echo "$vm"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$vm"   | jq -r '.id // ""')
      loc=$(echo "$vm"   | jq -r '.location // ""')
      size=$(echo "$vm"  | jq -r '.hardwareProfile.vmSize // ""')
      os=$(echo "$vm"    | jq -r '.storageProfile.osDisk.osType // ""')
      state=$(echo "$vm" | jq -r '.provisioningState // ""')
      add_csv "Virtual Machine" "$name" "$name" "$loc" "$rid" "$state" \
        "Size=${size},OS=${os},ResourceGroup=${RG}"
      write_tf_stub "compute" "azurerm_linux_virtual_machine" "$rid" \
        "$(sanitise_label "vm_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  size                = \"${size}\"\n  # admin_username      = \"adminuser\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" vm list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} virtual machines"

    # ── Managed Disks ─────────────────────────────────────────────────────────
    log_section "Managed Disks"
    COUNT=0
    while IFS= read -r disk; do
      [[ -z "$disk" || "$disk" == "null" ]] && continue
      name=$(echo "$disk"   | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$disk"    | jq -r '.id // ""')
      loc=$(echo "$disk"    | jq -r '.location // ""')
      size=$(echo "$disk"   | jq -r '.diskSizeGb // 0')
      sku=$(echo "$disk"    | jq -r '.sku.name // ""')
      state=$(echo "$disk"  | jq -r '.provisioningState // ""')
      add_csv "Managed Disk" "$name" "$name" "$loc" "$rid" "$state" \
        "Size=${size}GB,SKU=${sku},ResourceGroup=${RG}"
      write_tf_stub "compute" "azurerm_managed_disk" "$rid" \
        "$(sanitise_label "disk_${name}")" "$loc" \
        "  name                 = \"${name}\"\n  resource_group_name  = \"${RG}\"\n  location             = \"${loc}\"\n  storage_account_type = \"${sku}\"\n  disk_size_gb         = ${size}"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" disk list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} managed disks"

    # ── Load Balancers ────────────────────────────────────────────────────────
    log_section "Load Balancers"
    COUNT=0
    while IFS= read -r lb; do
      [[ -z "$lb" || "$lb" == "null" ]] && continue
      name=$(echo "$lb"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$lb"   | jq -r '.id // ""')
      loc=$(echo "$lb"   | jq -r '.location // ""')
      sku=$(echo "$lb"   | jq -r '.sku.name // ""')
      state=$(echo "$lb" | jq -r '.provisioningState // ""')
      add_csv "Load Balancer" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},ResourceGroup=${RG}"
      write_tf_stub "networking" "azurerm_lb" "$rid" \
        "$(sanitise_label "lb_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  sku                 = \"${sku}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network lb list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} load balancers"

    # ── Application Gateways ──────────────────────────────────────────────────
    log_section "Application Gateways"
    COUNT=0
    while IFS= read -r agw; do
      [[ -z "$agw" || "$agw" == "null" ]] && continue
      name=$(echo "$agw"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$agw"   | jq -r '.id // ""')
      loc=$(echo "$agw"   | jq -r '.location // ""')
      sku=$(echo "$agw"   | jq -r '.sku.name // ""')
      tier=$(echo "$agw"  | jq -r '.sku.tier // ""')
      state=$(echo "$agw" | jq -r '.provisioningState // ""')
      add_csv "Application Gateway" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},Tier=${tier},ResourceGroup=${RG}"
      write_tf_stub "networking" "azurerm_application_gateway" "$rid" \
        "$(sanitise_label "agw_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" network application-gateway list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} application gateways"

    # ── Azure SQL Servers + Databases ─────────────────────────────────────────
    log_section "SQL Servers"
    COUNT=0
    SQL_SERVERS=()
    while IFS= read -r srv; do
      [[ -z "$srv" || "$srv" == "null" ]] && continue
      name=$(echo "$srv"   | jq -r '.name // ""');  [[ -z "$name" ]] && continue
      rid=$(echo "$srv"    | jq -r '.id // ""')
      loc=$(echo "$srv"    | jq -r '.location // ""')
      fqdn=$(echo "$srv"   | jq -r '.fullyQualifiedDomainName // ""')
      state=$(echo "$srv"  | jq -r '.state // ""')
      SQL_SERVERS+=("$name")
      add_csv "SQL Server" "$name" "$name" "$loc" "$rid" "$state" \
        "FQDN=${fqdn},ResourceGroup=${RG}"
      write_tf_stub "sql" "azurerm_mssql_server" "$rid" \
        "$(sanitise_label "sqlsrv_${name}")" "$loc" \
        "  name                         = \"${name}\"\n  resource_group_name          = \"${RG}\"\n  location                     = \"${loc}\"\n  # version                      = \"12.0\"\n  # administrator_login          = \"sqladmin\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" sql server list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} SQL servers"

    log_section "SQL Databases"
    COUNT=0
    for SQL_SRV in "${SQL_SERVERS[@]:-}"; do
      [[ -z "$SQL_SRV" ]] && continue
      while IFS= read -r db; do
        [[ -z "$db" || "$db" == "null" ]] && continue
        name=$(echo "$db"    | jq -r '.name // ""');  [[ -z "$name" ]] && continue
        [[ "$name" == "master" ]] && continue
        rid=$(echo "$db"     | jq -r '.id // ""')
        loc=$(echo "$db"     | jq -r '.location // ""')
        sku=$(echo "$db"     | jq -r '.sku.name // ""')
        state=$(echo "$db"   | jq -r '.status // ""')
        add_csv "SQL Database" "${SQL_SRV}/${name}" "$name" "$loc" "$rid" "$state" \
          "Server=${SQL_SRV},SKU=${sku},ResourceGroup=${RG}"
        write_tf_stub "sql" "azurerm_mssql_database" "$rid" \
          "$(sanitise_label "sqldb_${SQL_SRV}_${name}")" "$loc" \
          "  name      = \"${name}\"\n  # server_id = azurerm_mssql_server.$(sanitise_label "sqlsrv_${SQL_SRV}").id\n  sku_name  = \"${sku}\""
        ((COUNT++)) || true
      done < <(az_sub "$SUB_ID" sql db list \
          --server "$SQL_SRV" --resource-group "$RG" \
          --output json 2>/dev/null | jq -c '.[]?' || true)
    done
    echo -e "  ${GREEN}✓${NC} ${COUNT} SQL databases"

    # ── Cosmos DB Accounts ────────────────────────────────────────────────────
    log_section "Cosmos DB Accounts"
    COUNT=0
    while IFS= read -r cosmos; do
      [[ -z "$cosmos" || "$cosmos" == "null" ]] && continue
      name=$(echo "$cosmos"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$cosmos"   | jq -r '.id // ""')
      loc=$(echo "$cosmos"   | jq -r '.location // ""')
      kind=$(echo "$cosmos"  | jq -r '.kind // ""')
      state=$(echo "$cosmos" | jq -r '.provisioningState // ""')
      add_csv "Cosmos DB" "$name" "$name" "$loc" "$rid" "$state" \
        "Kind=${kind},ResourceGroup=${RG}"
      write_tf_stub "cosmosdb" "azurerm_cosmosdb_account" "$rid" \
        "$(sanitise_label "cosmos_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  offer_type          = \"Standard\"\n  kind                = \"${kind}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" cosmosdb list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} Cosmos DB accounts"

    # ── Azure Cache for Redis ─────────────────────────────────────────────────
    log_section "Redis Caches"
    COUNT=0
    while IFS= read -r redis; do
      [[ -z "$redis" || "$redis" == "null" ]] && continue
      name=$(echo "$redis"   | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$redis"    | jq -r '.id // ""')
      loc=$(echo "$redis"    | jq -r '.location // ""')
      sku=$(echo "$redis"    | jq -r '.sku.name // ""')
      capacity=$(echo "$redis"| jq -r '.sku.capacity // ""')
      state=$(echo "$redis"  | jq -r '.provisioningState // ""')
      add_csv "Redis Cache" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},Capacity=${capacity},ResourceGroup=${RG}"
      write_tf_stub "redis" "azurerm_redis_cache" "$rid" \
        "$(sanitise_label "redis_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  capacity            = ${capacity}\n  family              = \"C\"\n  sku_name            = \"${sku}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" redis list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} Redis caches"

    # ── Azure Kubernetes Service (AKS) ────────────────────────────────────────
    log_section "AKS Clusters"
    COUNT=0
    while IFS= read -r aks; do
      [[ -z "$aks" || "$aks" == "null" ]] && continue
      name=$(echo "$aks"    | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$aks"     | jq -r '.id // ""')
      loc=$(echo "$aks"     | jq -r '.location // ""')
      ver=$(echo "$aks"     | jq -r '.kubernetesVersion // ""')
      state=$(echo "$aks"   | jq -r '.provisioningState // ""')
      nodecount=$(echo "$aks"| jq -r '.agentPoolProfiles[0].count // 0')
      add_csv "AKS Cluster" "$name" "$name" "$loc" "$rid" "$state" \
        "K8sVersion=${ver},NodeCount=${nodecount},ResourceGroup=${RG}"
      write_tf_stub "aks" "azurerm_kubernetes_cluster" "$rid" \
        "$(sanitise_label "aks_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  kubernetes_version  = \"${ver}\"\n  dns_prefix          = \"${name}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" aks list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} AKS clusters"

    # ── Container Registries ──────────────────────────────────────────────────
    log_section "Container Registries (ACR)"
    COUNT=0
    while IFS= read -r acr; do
      [[ -z "$acr" || "$acr" == "null" ]] && continue
      name=$(echo "$acr"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$acr"   | jq -r '.id // ""')
      loc=$(echo "$acr"   | jq -r '.location // ""')
      sku=$(echo "$acr"   | jq -r '.sku.name // ""')
      server=$(echo "$acr"| jq -r '.loginServer // ""')
      state=$(echo "$acr" | jq -r '.provisioningState // ""')
      add_csv "Container Registry" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},LoginServer=${server},ResourceGroup=${RG}"
      write_tf_stub "acr" "azurerm_container_registry" "$rid" \
        "$(sanitise_label "acr_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  sku                 = \"${sku}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" acr list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} container registries"

    # ── Container Instances ───────────────────────────────────────────────────
    log_section "Container Instances (ACI)"
    COUNT=0
    while IFS= read -r aci; do
      [[ -z "$aci" || "$aci" == "null" ]] && continue
      name=$(echo "$aci"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$aci"   | jq -r '.id // ""')
      loc=$(echo "$aci"   | jq -r '.location // ""')
      state=$(echo "$aci" | jq -r '.provisioningState // ""')
      os=$(echo "$aci"    | jq -r '.osType // ""')
      add_csv "Container Instance" "$name" "$name" "$loc" "$rid" "$state" \
        "OS=${os},ResourceGroup=${RG}"
      write_tf_stub "aci" "azurerm_container_group" "$rid" \
        "$(sanitise_label "aci_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  ip_address_type     = \"Public\"\n  os_type             = \"${os}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" container group list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} container instances"

    # ── App Service Plans ─────────────────────────────────────────────────────
    log_section "App Service Plans"
    COUNT=0
    while IFS= read -r plan; do
      [[ -z "$plan" || "$plan" == "null" ]] && continue
      name=$(echo "$plan"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$plan"   | jq -r '.id // ""')
      loc=$(echo "$plan"   | jq -r '.location // ""')
      sku=$(echo "$plan"   | jq -r '.sku.name // ""')
      state=$(echo "$plan" | jq -r '.provisioningState // ""')
      add_csv "App Service Plan" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},ResourceGroup=${RG}"
      write_tf_stub "appservice" "azurerm_service_plan" "$rid" \
        "$(sanitise_label "asp_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  os_type             = \"Linux\"\n  sku_name            = \"${sku}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" appservice plan list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} app service plans"

    # ── App Services / Web Apps ───────────────────────────────────────────────
    log_section "App Services / Web Apps"
    COUNT=0
    while IFS= read -r app; do
      [[ -z "$app" || "$app" == "null" ]] && continue
      name=$(echo "$app"   | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$app"    | jq -r '.id // ""')
      loc=$(echo "$app"    | jq -r '.location // ""')
      kind=$(echo "$app"   | jq -r '.kind // ""')
      state=$(echo "$app"  | jq -r '.state // ""')
      hostname=$(echo "$app"| jq -r '.defaultHostName // ""')
      add_csv "App Service" "$name" "$name" "$loc" "$rid" "$state" \
        "Kind=${kind},Hostname=${hostname},ResourceGroup=${RG}"
      write_tf_stub "appservice" "azurerm_linux_web_app" "$rid" \
        "$(sanitise_label "webapp_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  # service_plan_id    = azurerm_service_plan.<label>.id"
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" webapp list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} web apps"

    # ── Azure Functions ───────────────────────────────────────────────────────
    log_section "Function Apps"
    COUNT=0
    while IFS= read -r fn; do
      [[ -z "$fn" || "$fn" == "null" ]] && continue
      name=$(echo "$fn"    | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$fn"     | jq -r '.id // ""')
      loc=$(echo "$fn"     | jq -r '.location // ""')
      runtime=$(echo "$fn" | jq -r '.siteConfig.linuxFxVersion // "N/A"')
      state=$(echo "$fn"   | jq -r '.state // ""')
      add_csv "Function App" "$name" "$name" "$loc" "$rid" "$state" \
        "Runtime=${runtime},ResourceGroup=${RG}"
      write_tf_stub "functions" "azurerm_linux_function_app" "$rid" \
        "$(sanitise_label "func_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  # service_plan_id    = azurerm_service_plan.<label>.id\n  # storage_account_name = \"<storage>\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" functionapp list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} function apps"

    # ── Service Bus Namespaces ────────────────────────────────────────────────
    log_section "Service Bus Namespaces"
    COUNT=0
    while IFS= read -r sb; do
      [[ -z "$sb" || "$sb" == "null" ]] && continue
      name=$(echo "$sb"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$sb"   | jq -r '.id // ""')
      loc=$(echo "$sb"   | jq -r '.location // ""')
      sku=$(echo "$sb"   | jq -r '.sku.name // ""')
      state=$(echo "$sb" | jq -r '.provisioningState // ""')
      add_csv "Service Bus Namespace" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},ResourceGroup=${RG}"
      write_tf_stub "servicebus" "azurerm_servicebus_namespace" "$rid" \
        "$(sanitise_label "sb_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  sku                 = \"${sku}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" servicebus namespace list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} Service Bus namespaces"

    # ── Event Hubs ────────────────────────────────────────────────────────────
    log_section "Event Hub Namespaces"
    COUNT=0
    while IFS= read -r eh; do
      [[ -z "$eh" || "$eh" == "null" ]] && continue
      name=$(echo "$eh"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$eh"   | jq -r '.id // ""')
      loc=$(echo "$eh"   | jq -r '.location // ""')
      sku=$(echo "$eh"   | jq -r '.sku.name // ""')
      state=$(echo "$eh" | jq -r '.provisioningState // ""')
      add_csv "Event Hub Namespace" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},ResourceGroup=${RG}"
      write_tf_stub "eventhub" "azurerm_eventhub_namespace" "$rid" \
        "$(sanitise_label "eh_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  sku                 = \"${sku}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" eventhubs namespace list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} Event Hub namespaces"

    # ── Log Analytics Workspaces ──────────────────────────────────────────────
    log_section "Log Analytics Workspaces"
    COUNT=0
    while IFS= read -r ws; do
      [[ -z "$ws" || "$ws" == "null" ]] && continue
      name=$(echo "$ws"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$ws"   | jq -r '.id // ""')
      loc=$(echo "$ws"   | jq -r '.location // ""')
      sku=$(echo "$ws"   | jq -r '.sku.name // ""')
      state=$(echo "$ws" | jq -r '.provisioningState // ""')
      add_csv "Log Analytics Workspace" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},ResourceGroup=${RG}"
      write_tf_stub "monitoring" "azurerm_log_analytics_workspace" "$rid" \
        "$(sanitise_label "law_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  sku                 = \"${sku}\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" monitor log-analytics workspace list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} log analytics workspaces"

    # ── API Management ────────────────────────────────────────────────────────
    log_section "API Management Services"
    COUNT=0
    while IFS= read -r apim; do
      [[ -z "$apim" || "$apim" == "null" ]] && continue
      name=$(echo "$apim"  | jq -r '.name // ""');   [[ -z "$name" ]] && continue
      rid=$(echo "$apim"   | jq -r '.id // ""')
      loc=$(echo "$apim"   | jq -r '.location // ""')
      sku=$(echo "$apim"   | jq -r '.sku.name // ""')
      state=$(echo "$apim" | jq -r '.provisioningState // ""')
      add_csv "API Management" "$name" "$name" "$loc" "$rid" "$state" \
        "SKU=${sku},ResourceGroup=${RG}"
      write_tf_stub "apim" "azurerm_api_management" "$rid" \
        "$(sanitise_label "apim_${name}")" "$loc" \
        "  name                = \"${name}\"\n  resource_group_name = \"${RG}\"\n  location            = \"${loc}\"\n  sku_name            = \"${sku}_1\"\n  # publisher_name     = \"My Org\"\n  # publisher_email    = \"admin@example.com\""
      ((COUNT++)) || true
    done < <(az_sub_rg "$SUB_ID" "$RG" apim list | jq -c '.[]?' 2>/dev/null || true)
    echo -e "  ${GREEN}✓${NC} ${COUNT} API Management services"

  done  # end resource groups loop

done  # end subscriptions loop

# =============================================================================
# SUMMARY
# =============================================================================

TF_FILE_COUNT=$(find "${TF_DIR}" -name "*.tf" 2>/dev/null | wc -l | tr -d ' ')

cat > "${SUMMARY_FILE}" <<SUMMARY
Azure Infrastructure Inventory Summary
=======================================
Tenant ID      : ${TENANT_ID}
Subscription(s): ${SUBSCRIPTION_IDS[*]}
Generated      : ${TIMESTAMP}
Total Resources: ${TOTAL_RESOURCES}

Outputs
-------
CSV  : ${CSV_FILE}
TF   : ${TF_DIR}/ (${TF_FILE_COUNT} .tf files)

Next Steps
----------
1. Review CSV to prioritise migration / audit order
2. Per resource, run: terraform import <resource>.<label> <azure_resource_id>
3. Run: terraform plan  (to see drift)
4. Fill # TODO / commented attributes in each stub
5. Commit to git and enable remote state (Azure Blob Storage backend)

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
echo -e "${BOLD}${GREEN}  ✓ Inventory complete! ${TOTAL_RESOURCES} resources found.${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  CSV             : ${CYAN}${CSV_FILE}${NC}"
echo -e "  Terraform stubs : ${CYAN}${TF_DIR}/${NC}"
echo -e "  Summary         : ${CYAN}${SUMMARY_FILE}${NC}"
echo ""
