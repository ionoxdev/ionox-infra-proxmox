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

  echo >&2
  echo "$prompt" >&2

  local i=1
  for opt in "${options[@]}"; do
    echo "  [$i] $opt" >&2
    i=$((i + 1))
  done

  local choice
  while true; do
    read -r -p "Choose [1-${#options[@]}]: " choice >&2
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#options[@]} ]; then
      printf '%s\n' "${options[$((choice - 1))]}"
      return 0
    fi
    echo "Invalid choice" >&2
  done
}

prompt_default() {
  local label="$1"
  local default_value="$2"
  local result
  read -r -p "$label [$default_value]: " result
  echo "${result:-$default_value}"
}

prompt_yes_no() {
  local label="$1"
  local default_value="$2"
  local answer
  while true; do
    read -r -p "$label [$default_value]: " answer
    answer="${answer:-$default_value}"
    case "$answer" in
      y|Y|yes) echo "true"; return ;;
      n|N|no) echo "false"; return ;;
      *) echo "Please answer y or n" ;;
    esac
  done
}

get_storage_names() {
  pvesm status | awk 'NR>1 {print $1}'
}

get_bridge_names() {
  ip -o link show | awk -F': ' '{print $2}' | grep '^vmbr' || true
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

echo
echo "=== VM CONFIGURATION ==="

VM_ID="$(prompt_default "VM ID" "9000")"
VM_NAME="$(prompt_default "VM name" "ubuntu-cloud-vm")"

echo
echo "=== IMAGE ==="

IMAGE_URL="$(prompt_default "Cloud image URL" "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img")"
IMAGE_FILE="$(prompt_default "Image filename" "noble-server-cloudimg-amd64.img")"

echo
echo "=== NETWORK ==="

BRIDGE="$(pick_from_list "Select network bridge" "${BRIDGES[@]}")"

IP_MODE="$(prompt_default "Network mode (dhcp/static)" "dhcp")"

IP_ADDRESS=""
GATEWAY="10.10.0.1"

if [[ "$IP_MODE" == "static" ]]; then
  IP_ADDRESS="$(prompt_default "Static IP (CIDR)" "10.10.0.150/24")"
  GATEWAY="$(prompt_default "Gateway" "10.10.0.1")"
fi

echo
echo "=== STORAGE ==="

STAGING_STORAGE="$(pick_from_list "Select staging storage (file-based)" "${STORAGES[@]}")"
TARGET_STORAGE="$(pick_from_list "Select target VM storage" "${STORAGES[@]}")"

echo
echo "=== CLOUD INIT ==="

CI_USER="$(prompt_default "Username" "ubuntu")"
SSH_KEY_FILE="$(prompt_default "SSH public key path" "$HOME/.ssh/id_ed25519.pub")"

echo
echo "=== OPTIONS ==="

DISK_SIZE="$(prompt_default "Disk size" "40G")"
USE_UEFI="$(prompt_yes_no "Use UEFI" "y")"
ENABLE_AGENT="$(prompt_yes_no "Enable guest agent" "y")"

echo
echo "=== SUMMARY ==="

echo "VM ID:           $VM_ID"
echo "VM Name:         $VM_NAME"
echo "Image:           $IMAGE_URL"
echo "Bridge:          $BRIDGE"
echo "IP Mode:         $IP_MODE"
echo "Staging Storage: $STAGING_STORAGE"
echo "Target Storage:  $TARGET_STORAGE"

echo
read -r -p "Continue? [y/N]: " CONFIRM
case "$CONFIRM" in
  y|Y|yes) ;;
  *) echo "Aborted."; exit 0 ;;
esac

echo
echo "Downloading runtime script..."

curl -fsSL "${REPO_RAW_BASE}/scripts/bootstrap-cloud-vm.sh" -o "$TMP_SCRIPT"
chmod +x "$TMP_SCRIPT"

echo "Starting bootstrap..."

VM_ID="$VM_ID" \
VM_NAME="$VM_NAME" \
NODE_NAME="$HOSTNAME_NOW" \
STAGING_STORAGE="$STAGING_STORAGE" \
TARGET_STORAGE="$TARGET_STORAGE" \
BRIDGE="$BRIDGE" \
IMAGE_URL="$IMAGE_URL" \
IMAGE_FILE="$IMAGE_FILE" \
CI_USER="$CI_USER" \
SSH_KEY_FILE="$SSH_KEY_FILE" \
DISK_SIZE="$DISK_SIZE" \
USE_UEFI="$USE_UEFI" \
ENABLE_AGENT="$ENABLE_AGENT" \
IP_MODE="$IP_MODE" \
IP_ADDRESS="$IP_ADDRESS" \
GATEWAY="$GATEWAY" \
"$TMP_SCRIPT"
