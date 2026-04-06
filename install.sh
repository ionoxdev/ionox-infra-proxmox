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
    read -r -p "$label [y/n] [$default_value]: " answer
    answer="${answer:-$default_value}"
    case "${answer,,}" in
      y|yes) echo "true"; return ;;
      n|no) echo "false"; return ;;
      *) echo "Please answer y or n" ;;
    esac
  done
}

pick_from_list() {
  local prompt="$1"
  shift
  local options=("$@")

  if [ ${#options[@]} -eq 1 ]; then
    read -r -p "$prompt [${options[0]}]: " _
    echo "${options[0]}"
    return
  fi

  echo "$prompt"
  local i=1
  for opt in "${options[@]}"; do
    echo "  [$i] $opt"
    i=$((i + 1))
  done

  while true; do
    read -r -p "Choose [1-${#options[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      echo "${options[$((choice - 1))]}"
      return
    fi
    echo "Invalid choice"
  done
}

prompt_secret() {
  local label="$1"
  local v1 v2
  while true; do
    read -r -s -p "$label: " v1; echo
    read -r -s -p "Confirm $label: " v2; echo
    [[ "$v1" == "$v2" ]] && echo "$v1" && return
    echo "Mismatch"
  done
}

prompt_auth_method() {
  echo
  echo "=== AUTHENTICATION ==="
  echo "Select authentication method:"
  echo "  [1] SSH key (paste)"
  echo "  [2] SSH key (file)"
  echo "  [3] Password"
  echo "  [4] SSH key + password"
  echo "  [5] None"

  while true; do
    read -r -p "Authentication method [1-5] [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
      1)
        echo "Paste SSH public key:"
        read -r key
        echo "SSH_KEY_B64=$(printf '%s' "$key" | base64 -w0)"
        echo "CI_PASSWORD_B64="
        return
        ;;
      2)
        read -r -p "Path [$HOME/.ssh/id_ed25519.pub]: " path
        path="${path:-$HOME/.ssh/id_ed25519.pub}"
        key="$(cat "$path")"
        echo "SSH_KEY_B64=$(printf '%s' "$key" | base64 -w0)"
        echo "CI_PASSWORD_B64="
        return
        ;;
      3)
        pass="$(prompt_secret "Password")"
        echo "SSH_KEY_B64="
        echo "CI_PASSWORD_B64=$(printf '%s' "$pass" | base64 -w0)"
        return
        ;;
      4)
        echo "Paste SSH key:"
        read -r key
        pass="$(prompt_secret "Password")"
        echo "SSH_KEY_B64=$(printf '%s' "$key" | base64 -w0)"
        echo "CI_PASSWORD_B64=$(printf '%s' "$pass" | base64 -w0)"
        return
        ;;
      5)
        echo "SSH_KEY_B64="
        echo "CI_PASSWORD_B64="
        return
        ;;
    esac
  done
}

get_bridge_names() { ip -o link show | awk -F': ' '{print $2}' | grep '^vmbr'; }
get_storage() { pvesm status | awk 'NR>1 {print $1}'; }
get_images() { pvesm list "$IMAGE_STORAGE" | awk 'NR>1 {print $1}'; }

require_cmd curl
require_cmd qm
require_cmd pvesm

HOSTNAME_NOW="$(hostname)"

mapfile -t BRIDGES < <(get_bridge_names)
mapfile -t STORAGES < <(get_storage)
mapfile -t IMAGES < <(get_images)

echo "=== VM CONFIGURATION ==="
VM_ID="$(prompt_default "VM ID" 9000)"
VM_NAME="$(prompt_default "VM name" ubuntu-cloud-vm)"

echo "=== IMAGE ==="
IMAGE_VOLID="$(pick_from_list "Select image" "${IMAGES[@]}")"

echo "=== NETWORK ==="
BRIDGE="$(pick_from_list "Select bridge" "${BRIDGES[@]}")"
IP_MODE="$(prompt_default "Network mode (dhcp/static)" dhcp)"

if [[ "$IP_MODE" == "static" ]]; then
  IP_ADDRESS="$(prompt_default "IP" 10.10.0.100/24)"
  GATEWAY="$(prompt_default "Gateway" 10.10.0.1)"
fi

echo "=== STORAGE ==="
TARGET_STORAGE="$(pick_from_list "Select storage" "${STORAGES[@]}")"

echo "=== CLOUD INIT ==="
CI_USER="$(prompt_default "Username" ubuntu)"
eval "$(prompt_auth_method)"

echo "=== OPTIONS ==="
DISK_SIZE="$(prompt_default "Disk size" 40G)"
USE_UEFI="$(prompt_yes_no "Use UEFI" y)"
ENABLE_AGENT="$(prompt_yes_no "Enable agent" y)"

curl -fsSL "${REPO_RAW_BASE}/scripts/bootstrap-cloud-vm.sh" -o "$TMP_SCRIPT"
chmod +x "$TMP_SCRIPT"

VM_ID="$VM_ID" \
VM_NAME="$VM_NAME" \
IMAGE_VOLID="$IMAGE_VOLID" \
TARGET_STORAGE="$TARGET_STORAGE" \
BRIDGE="$BRIDGE" \
CI_USER="$CI_USER" \
SSH_KEY_B64="${SSH_KEY_B64:-}" \
CI_PASSWORD_B64="${CI_PASSWORD_B64:-}" \
IP_MODE="$IP_MODE" \
IP_ADDRESS="${IP_ADDRESS:-}" \
GATEWAY="${GATEWAY:-}" \
DISK_SIZE="$DISK_SIZE" \
USE_UEFI="$USE_UEFI" \
ENABLE_AGENT="$ENABLE_AGENT" \
"$TMP_SCRIPT"
