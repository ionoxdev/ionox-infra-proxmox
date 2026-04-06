#!/usr/bin/env bash
set -euo pipefail

VM_ID="${VM_ID:-9000}"
VM_NAME="${VM_NAME:-ubuntu-cloud-vm}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
BRIDGE="${BRIDGE:-vmbr0}"

IMAGE_STORAGE="${IMAGE_STORAGE:-cloudimages}"
IMAGE_VOLID="${IMAGE_VOLID:-}"

TARGET_STORAGE="${TARGET_STORAGE:-ceph-storage}"

CI_USER="${CI_USER:-ubuntu}"
CI_PASSWORD="${CI_PASSWORD:-}"
SSH_KEY="${SSH_KEY:-}"

IP_MODE="${IP_MODE:-dhcp}"
IP_ADDRESS="${IP_ADDRESS:-10.10.0.150/24}"
GATEWAY="${GATEWAY:-10.10.0.1}"

DISK_SIZE="${DISK_SIZE:-40G}"
USE_UEFI="${USE_UEFI:-true}"
ENABLE_AGENT="${ENABLE_AGENT:-true}"
MAKE_TEMPLATE="${MAKE_TEMPLATE:-false}"

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

resolve_storage_mount_path() {
  case "$1" in
    cloudimages) echo "/mnt/pve/cloudimages" ;;
    local) echo "/var/lib/vz" ;;
    truenas-iso) echo "/mnt/pve/truenas-iso" ;;
    truenas-vm) echo "/mnt/pve/truenas-vm" ;;
    truenas-backups) echo "/mnt/pve/truenas-backups" ;;
    truenas-lxc) echo "/mnt/pve/truenas-lxc" ;;
    *)
      pvesm path "$1" 2>/dev/null || true
      ;;
  esac
}

require_cmd qm
require_cmd pvesm
require_cmd awk
require_cmd grep
require_cmd mktemp

[ -n "$IMAGE_VOLID" ] || fail "IMAGE_VOLID is required"

pvesm status | grep -q "^${IMAGE_STORAGE}[[:space:]]" || fail "image storage '${IMAGE_STORAGE}' not found"
pvesm status | grep -q "^${TARGET_STORAGE}[[:space:]]" || fail "target storage '${TARGET_STORAGE}' not found"

IMAGE_STORAGE_PATH="$(resolve_storage_mount_path "$IMAGE_STORAGE")"
[ -n "$IMAGE_STORAGE_PATH" ] || fail "could not resolve filesystem path for image storage '${IMAGE_STORAGE}'"

REL_PATH="${IMAGE_VOLID#*:}"
IMAGE_PATH="${IMAGE_STORAGE_PATH%/}/${REL_PATH}"

[ -f "$IMAGE_PATH" ] || fail "image file not found: $IMAGE_PATH"

log "Node"
echo "$NODE_NAME"

log "Image storage path"
echo "$IMAGE_STORAGE_PATH"

log "Image volume ID"
echo "$IMAGE_VOLID"

log "Image file path"
echo "$IMAGE_PATH"

log "Create minimal VM config if needed"
if qm config "$VM_ID" >/dev/null 2>&1; then
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
echo "Cloud-Init user set to: $CI_USER"

if [ "$IP_MODE" = "dhcp" ]; then
  log "Configure DHCP"
  qm set "$VM_ID" --ipconfig0 ip=dhcp
elif [ "$IP_MODE" = "static" ]; then
  log "Configure static IP"
  qm set "$VM_ID" --ipconfig0 "ip=${IP_ADDRESS},gw=${GATEWAY}"
else
  fail "IP_MODE must be dhcp or static"
fi

if [ -n "$SSH_KEY" ]; then
  log "Add SSH public key"
  SSH_KEY_TMP="$(mktemp)"
  printf '%s\n' "$SSH_KEY" > "$SSH_KEY_TMP"
  qm set "$VM_ID" --sshkeys "$SSH_KEY_TMP"
  rm -f "$SSH_KEY_TMP"
else
  echo "No SSH public key provided, skipping"
fi

if [ -n "$CI_PASSWORD" ]; then
  log "Set Cloud-Init password"
  qm set "$VM_ID" --cipassword "$CI_PASSWORD"
fi

log "Resize disk"
qm resize "$VM_ID" scsi0 "$DISK_SIZE" || true

if [ "$MAKE_TEMPLATE" = "true" ]; then
  log "Convert VM to template"
  qm template "$VM_ID"
fi

log "Final VM config"
qm config "$VM_ID"

echo
if [ "$MAKE_TEMPLATE" = "true" ]; then
  echo "Done. VM $VM_ID is now a template."
else
  echo "Done. Start the VM with:"
  echo "  qm start $VM_ID"
fi
