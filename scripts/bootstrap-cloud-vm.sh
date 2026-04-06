k#!/usr/bin/env bash
set -euo pipefail

VM_ID="${VM_ID:-9000}"
VM_NAME="${VM_NAME:-ubuntu-2404-cloudinit}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
BRIDGE="${BRIDGE:-vmbr0}"

STAGING_STORAGE="${STAGING_STORAGE:-local}"
TARGET_STORAGE="${TARGET_STORAGE:-ceph-storage}"

IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
IMAGE_FILE="${IMAGE_FILE:-noble-server-cloudimg-amd64.img}"

CI_USER="${CI_USER:-ubuntu}"
CI_PASSWORD="${CI_PASSWORD:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

IP_MODE="${IP_MODE:-dhcp}"
IP_ADDRESS="${IP_ADDRESS:-10.10.0.150/24}"
GATEWAY="${GATEWAY:-10.10.0.1}"

DISK_SIZE="${DISK_SIZE:-40G}"
USE_UEFI="${USE_UEFI:-true}"
ENABLE_AGENT="${ENABLE_AGENT:-true}"

log() {
  echo
  echo "==> $1"
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

get_storage_path() {
  local storage_name="$1"
  pvesm path "$storage_name" 2>/dev/null || true
}

require_cmd qm
require_cmd pvesm
require_cmd wget
require_cmd awk
require_cmd grep

pvesm status | grep -q "^${STAGING_STORAGE}[[:space:]]" || fail "staging storage '${STAGING_STORAGE}' not found"
pvesm status | grep -q "^${TARGET_STORAGE}[[:space:]]" || fail "target storage '${TARGET_STORAGE}' not found"

STAGING_PATH="$(get_storage_path "$STAGING_STORAGE")"
[ -n "$STAGING_PATH" ] || fail "could not resolve a filesystem path for staging storage '${STAGING_STORAGE}'. Use a file-based storage like local or NFS."

IMAGE_PATH="${STAGING_PATH%/}/${IMAGE_FILE}"

log "Node"
echo "$NODE_NAME"

log "Staging path"
echo "$STAGING_PATH"

log "Download cloud image if missing"
if [ ! -f "$IMAGE_PATH" ]; then
  wget -O "$IMAGE_PATH" "$IMAGE_URL"
else
  echo "Image already exists: $IMAGE_PATH"
fi

ls -lh "$IMAGE_PATH"

log "Create minimal VM config if needed"
if qm status "$VM_ID" >/dev/null 2>&1; then
  echo "VM $VM_ID already exists, skipping create"
else
  qm create "$VM_ID" \
    --name "$VM_NAME" \
    --net0 "virtio,bridge=${BRIDGE}"
fi

if [ "$USE_UEFI" = "true" ]; then
  log "Configure UEFI"
  qm set "$VM_ID" --bios ovmf
  if ! qm config "$VM_ID" | grep -q '^efidisk0:'; then
    qm set "$VM_ID" --efidisk0 "${TARGET_STORAGE}:0,pre-enrolled-keys=0"
  else
    echo "EFI disk already present"
  fi
else
  log "Configure SeaBIOS"
  qm set "$VM_ID" --bios seabios
fi

log "Import disk if no system disk is attached yet"
if qm config "$VM_ID" | grep -Eq '^(scsi0|virtio0|sata0):'; then
  echo "System disk already attached, skipping import"
else
  qm importdisk "$VM_ID" "$IMAGE_PATH" "$TARGET_STORAGE"
fi

log "Attach imported disk if needed"
if ! qm config "$VM_ID" | grep -q '^scsi0:'; then
  IMPORTED_DISK_LINE="$(qm config "$VM_ID" | grep '^unused[0-9]\+:')"
  [ -n "$IMPORTED_DISK_LINE" ] || fail "no imported disk found as unusedX"
  IMPORTED_DISK="$(echo "$IMPORTED_DISK_LINE" | awk '{print $2}')"

  qm set "$VM_ID" \
    --scsihw virtio-scsi-pci \
    --scsi0 "$IMPORTED_DISK"
else
  echo "scsi0 already present"
fi

log "Add Cloud-Init disk if needed"
if ! qm config "$VM_ID" | grep -q '^ide2:.*cloudinit'; then
  qm set "$VM_ID" --ide2 "${TARGET_STORAGE}:cloudinit"
else
  echo "Cloud-Init disk already present"
fi

log "Configure boot and console"
qm set "$VM_ID" \
  --boot order=scsi0 \
  --serial0 socket \
  --vga serial0

if [ "$ENABLE_AGENT" = "true" ]; then
  qm set "$VM_ID" --agent enabled=1
fi

log "Configure Cloud-Init user"
qm set "$VM_ID" --ciuser "$CI_USER"

if [ "$IP_MODE" = "dhcp" ]; then
  log "Configure DHCP"
  qm set "$VM_ID" --ipconfig0 ip=dhcp
elif [ "$IP_MODE" = "static" ]; then
  log "Configure static IP"
  qm set "$VM_ID" --ipconfig0 "ip=${IP_ADDRESS},gw=${GATEWAY}"
else
  fail "IP_MODE must be dhcp or static"
fi

if [ -f "$SSH_KEY_FILE" ]; then
  log "Add SSH public key"
  qm set "$VM_ID" --sshkeys "$SSH_KEY_FILE"
else
  echo "SSH key file not found, skipping: $SSH_KEY_FILE"
fi

if [ -n "$CI_PASSWORD" ]; then
  log "Set Cloud-Init password"
  qm set "$VM_ID" --cipassword "$CI_PASSWORD"
fi

log "Resize disk"
qm resize "$VM_ID" scsi0 "$DISK_SIZE" || true

log "Final VM config"
qm config "$VM_ID"

echo
echo "Done. Start the VM with:"
echo "  qm start $VM_ID"
