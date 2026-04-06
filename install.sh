#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/ionoxdev/ionox-infra-proxmox/main}"
TMP_SCRIPT="/tmp/bootstrap-cloud-vm.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

pick_from_list() {
  local prompt="$1"
  shift
  local options=("$@")

  echo
  echo "$prompt"
  local i=1
  for opt in "${options[@]}"; do
    echo "  [$i] $opt"
    i=$((i + 1))
  done

  local choice
  while true; do
    read -r -p "Choose [1-${#options[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#options[@]} ]; then
      echo "${options[$((choice - 1))]}"
      return
    fi
    echo "Invalid choice"
  done
}

get_storage_names() {
  pvesm status | awk 'NR>1 {print $1}'
}

get_bridge_names() {
  ip -o link show | awk -F': ' '{print $2}' | grep '^vmbr' || true
}

prompt_default() {
  local label="$1"
  local default_value="$2"
  local result
  read -r -p "$label [$default_value]: " result
  echo "${result:-$default_value}"
}

require_cmd curl
require_cmd qm
require_cmd pvesm
require_cmd ip

HOSTNAME_NOW="$(hostname)"
mapfile -t STORAGES < <(get_storage_names)
mapfile -t BRIDGES < <(get_bridge_names)

echo
echo "IONOX Proxmox Cloud VM Installer"
echo "Running on node: $HOSTNAME_NOW"

STAGING_STORAGE="$(pick_from_list "Select staging storage" "${STORAGES[@]}")"
TARGET_STORAGE="$(pick_from_list "Select target storage" "${STORAGES[@]}")"
BRIDGE="$(pick_from_list "Select bridge" "${BRIDGES[@]}")"

VM_ID="$(prompt_default "VM ID" "9000")"
VM_NAME="$(prompt_default "VM name" "ubuntu-vm")"

echo
echo "Starting bootstrap..."

curl -fsSL "${REPO_RAW_BASE}/scripts/bootstrap-cloud-vm.sh" -o "$TMP_SCRIPT"
chmod +x "$TMP_SCRIPT"

VM_ID="$VM_ID" \
VM_NAME="$VM_NAME" \
STAGING_STORAGE="$STAGING_STORAGE" \
TARGET_STORAGE="$TARGET_STORAGE" \
BRIDGE="$BRIDGE" \
"$TMP_SCRIPT"
