#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/ionoxdev/ionox-infra-proxmox/main}"
TMP_SCRIPT="/tmp/bootstrap-cloud-vm.sh"
IMAGE_STORAGE="${IMAGE_STORAGE:-cloudimages}"

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

  if [ ${#options[@]} -eq 0 ]; then
    echo "ERROR: no options available for: $prompt" >&2
    exit 1
  fi

  echo >&2
  echo "$prompt" >&2

  local i=1
  for opt in "${options[@]}"; do
    echo "  [$i] $opt" >&2
    i=$((i + 1))
  done

  if [ ${#options[@]} -eq 1 ]; then
    read -r -p "Press ENTER to use the only option [${options[0]}]..." _ >&2 || true
    printf '%s\n' "${options[0]}"
    return 0
  fi

  local choice
  while true; do
    read -r -p "Choose [1-${#options[@]}]: " choice >&2
    if [[ -z "$choice" ]]; then
      echo "Please choose a number" >&2
      continue
    fi
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
  local default_value="$2"   # y of n
  local answer
  while true; do
    read -r -p "$label [$default_value]: " answer
    answer="${answer:-$default_value}"
    case "${answer,,}" in
      y|yes) echo "true"; return 0 ;;
      n|no) echo "false"; return 0 ;;
      *) echo "Please answer y or n" ;;
    esac
  done
}

prompt_ssh_key() {
  echo
  echo "=== SSH KEY ==="
  echo "1) Paste public key"
  echo "2) Use existing file path"

  local choice
  while true; do
    read -r -p "SSH key input method [1-2]: " choice
    case "$choice" in
      1)
        echo
        echo "Paste your public key, then press ENTER:"
        local key
        read -r key
        if [[ ! "$key" =~ ^ssh- ]]; then
          echo "ERROR: invalid SSH public key format" >&2
          exit 1
        fi
        echo "$key"
        return 0
        ;;
      2)
        local path
        read -r -p "SSH public key path [$HOME/.ssh/id_ed25519.pub]: " path
        path="${path:-$HOME/.ssh/id_ed25519.pub}"
        if [ ! -f "$path" ]; then
          echo "ERROR: file not found: $path" >&2
          exit 1
        fi
        cat "$path"
        return 0
        ;;
      *)
        echo "Invalid choice"
        ;;
    esac
  done
}

get_bridge_names() {
  ip -o link show | awk -F': ' '{print $2}' | grep '^vmbr' || true
}

get_target_storage_names() {
  pvesm status | awk 'NR>1 {print $1}' | grep -v "^${IMAGE_STORAGE}$" || true
}

get_cloud_images() {
  pvesm list "$IMAGE_STORAGE" | awk 'NR>1 {print $1}'
}

require_cmd curl
require_cmd qm
require_cmd pvesm
require_cmd ip

HOSTNAME_NOW="$(hostname)"

if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$IMAGE_STORAGE"; then
  echo "ERROR: image storage '$IMAGE_STORAGE' not found" >&2
  exit 1
fi

mapfile -t BRIDGES < <(get_bridge_names)
mapfile -t TARGET_STORAGES < <(get_target_storage_names)
mapfile -t CLOUD_IMAGES < <(get_cloud_images)

if [ ${#BRIDGES[@]} -eq 0 ]; then
  echo "ERROR: no vmbr bridges found" >&2
  exit 1
fi

if [ ${#TARGET_STORAGES[@]} -eq 0 ]; then
  echo "ERROR: no target storages found" >&2
  exit 1
fi

if [ ${#CLOUD_IMAGES[@]} -eq 0 ]; then
  echo "ERROR: no cloud images found in storage '$IMAGE_STORAGE'" >&2
  exit 1
fi

echo
echo "IONOX Proxmox Cloud VM Installer"
echo "Running on node: $HOSTNAME_NOW"
echo "Image storage: $IMAGE_STORAGE"

echo
echo "=== VM CONFIGURATION ==="
VM_ID="$(prompt_default "VM ID" "9000")"
VM_NAME="$(prompt_default "VM name" "ubuntu-cloud-vm")"

echo
echo "=== IMAGE ==="
IMAGE_VOLID="$(pick_from_list "Select cloud image from storage '$IMAGE_STORAGE'" "${CLOUD_IMAGES[@]}")"

echo
echo "=== NETWORK ==="
BRIDGE="$(pick_from_list "Select network bridge" "${BRIDGES[@]}")"
IP_MODE_RAW="$(prompt_default "Network mode (dhcp/static)" "dhcp")"
IP_MODE="${IP_MODE_RAW,,}"

IP_ADDRESS=""
GATEWAY="10.10.0.1"

if [[ "$IP_MODE" == "static" ]]; then
  IP_ADDRESS="$(prompt_default "Static IP (CIDR)" "10.10.0.150/24")"
  GATEWAY="$(prompt_default "Gateway" "10.10.0.1")"
fi

echo
echo "=== STORAGE ==="
TARGET_STORAGE="$(pick_from_list "Select target VM storage" "${TARGET_STORAGES[@]}")"

echo
echo "=== CLOUD INIT ==="
CI_USER="$(prompt_default "Username" "ubuntu")"
SSH_KEY="$(prompt_ssh_key)"

echo
echo "=== OPTIONS ==="
DISK_SIZE="$(prompt_default "Disk size" "40G")"
USE_UEFI="$(prompt_yes_no "Use UEFI" "y")"
ENABLE_AGENT="$(prompt_yes_no "Enable guest agent" "y")"
MAKE_TEMPLATE="$(prompt_yes_no "Make VM a template after creation" "n")"

echo
echo "=== SUMMARY ==="
echo "VM ID:           $VM_ID"
echo "VM Name:         $VM_NAME"
echo "Image Storage:   $IMAGE_STORAGE"
echo "Image Volume ID: $IMAGE_VOLID"
echo "Bridge:          $BRIDGE"
echo "IP Mode:         $IP_MODE"
if [[ "$IP_MODE" == "static" ]]; then
  echo "IP Address:      $IP_ADDRESS"
  echo "Gateway:         $GATEWAY"
fi
echo "Target Storage:  $TARGET_STORAGE"
echo "Cloud-Init User: $CI_USER"
echo "Disk Size:       $DISK_SIZE"
echo "Use UEFI:        $USE_UEFI"
echo "Guest Agent:     $ENABLE_AGENT"
echo "Make Template:   $MAKE_TEMPLATE"
echo "SSH Key:         provided"

echo
read -r -p "Continue? [y/N]: " CONFIRM
case "${CONFIRM,,}" in
  y|yes) ;;
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
IMAGE_STORAGE="$IMAGE_STORAGE" \
IMAGE_VOLID="$IMAGE_VOLID" \
TARGET_STORAGE="$TARGET_STORAGE" \
BRIDGE="$BRIDGE" \
CI_USER="$CI_USER" \
SSH_KEY="$SSH_KEY" \
DISK_SIZE="$DISK_SIZE" \
USE_UEFI="$USE_UEFI" \
ENABLE_AGENT="$ENABLE_AGENT" \
IP_MODE="$IP_MODE" \
IP_ADDRESS="$IP_ADDRESS" \
GATEWAY="$GATEWAY" \
MAKE_TEMPLATE="$MAKE_TEMPLATE" \
"$TMP_SCRIPT"
