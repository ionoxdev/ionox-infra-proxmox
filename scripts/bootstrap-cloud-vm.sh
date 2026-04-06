#!/usr/bin/env bash
set -euo pipefail

#
# Proxmox cloud-image VM bootstrap
# - download image naar file-based staging storage
# - maak minimale VM-config
# - importeer disk naar Ceph
# - voeg EFI + Cloud-Init toe
# - configureer user / netwerk / SSH
#

### ===== Variabelen =====

VM_ID="${VM_ID:-9000}"
VM_NAME="${VM_NAME:-ubuntu-2404-cloudinit}"

NODE_NAME="${NODE_NAME:-pve1}"
BRIDGE="${BRIDGE:-vmbr0}"

# Staging pad moet file-based storage zijn, niet Ceph
STAGING_DIR="${STAGING_DIR:-/var/lib/vz/template/iso}"

IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
IMAGE_FILE="${IMAGE_FILE:-noble-server-cloudimg-amd64.img}"
IMAGE_PATH="${IMAGE_PATH:-$STAGING_DIR/$IMAGE_FILE}"

CEPH_STORAGE="${CEPH_STORAGE:-ceph-storage}"

CI_USER="${CI_USER:-ubuntu}"
CI_PASSWORD="${CI_PASSWORD:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

IP_MODE="${IP_MODE:-dhcp}"               # dhcp of static
IP_ADDRESS="${IP_ADDRESS:-10.10.0.150/24}"
GATEWAY="${GATEWAY:-10.10.0.1}"

DISK_SIZE="${DISK_SIZE:-40G}"

USE_UEFI="${USE_UEFI:-true}"             # true of false
ENABLE_AGENT="${ENABLE_AGENT:-true}"     # true of false

### ===== Helpers =====

log() {
  echo
  echo "==> $1"
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

command -v qm >/dev/null 2>&1 || fail "qm command niet gevonden. Run dit script op een Proxmox node."
command -v pvesm >/dev/null 2>&1 || fail "pvesm command niet gevonden."

### ===== Validaties =====

log "Valideer storage"
pvesm status | grep -q "^${CEPH_STORAGE}[[:space:]]" || fail "Ceph storage '${CEPH_STORAGE}' niet gevonden."

log "Valideer staging directory"
mkdir -p "$STAGING_DIR"

if [[ "$IP_MODE" != "dhcp" && "$IP_MODE" != "static" ]]; then
  fail "IP_MODE moet 'dhcp' of 'static' zijn."
fi

if [[ -n "$CI_PASSWORD" ]]; then
  log "Let op: CI_PASSWORD is ingesteld. Gebruik dit alleen als je dat bewust wilt."
fi

### ===== Stap 1: image downloaden =====

log "Download cloud image indien nodig"
if [[ ! -f "$IMAGE_PATH" ]]; then
  cd "$STAGING_DIR"
  wget -O "$IMAGE_FILE" "$IMAGE_URL"
else
  echo "Image bestaat al: $IMAGE_PATH"
fi

ls -lh "$IMAGE_PATH"

### ===== Stap 2: minimale VM-config =====

log "Maak minimale VM-config indien nodig"
if qm status "$VM_ID" >/dev/null 2>&1; then
  echo "VM $VM_ID bestaat al, create wordt overgeslagen."
else
  qm create "$VM_ID" \
    --name "$VM_NAME" \
    --net0 "virtio,bridge=${BRIDGE}"
fi

### ===== Stap 3: BIOS/EFI instellen =====

if [[ "$USE_UEFI" == "true" ]]; then
  log "Stel UEFI in"
  qm set "$VM_ID" --bios ovmf
  if ! qm config "$VM_ID" | grep -q '^efidisk0:'; then
    qm set "$VM_ID" --efidisk0 "${CEPH_STORAGE}:0,pre-enrolled-keys=0"
  else
    echo "EFI disk bestaat al, overslaan."
  fi
else
  log "Gebruik SeaBIOS"
  qm set "$VM_ID" --bios seabios
fi

### ===== Stap 4: image importeren naar Ceph =====

log "Controleer of OS disk al aanwezig is"
if qm config "$VM_ID" | grep -Eq '^(scsi0|virtio0|sata0):'; then
  echo "Er is al een systeemdisk gekoppeld, import wordt overgeslagen."
else
  qm importdisk "$VM_ID" "$IMAGE_PATH" "$CEPH_STORAGE"
fi

### ===== Stap 5: imported disk koppelen =====

log "Koppel imported disk indien nodig"
if ! qm config "$VM_ID" | grep -q '^scsi0:'; then
  IMPORTED_DISK_LINE="$(qm config "$VM_ID" | grep '^unused[0-9]\+:')"
  [[ -n "$IMPORTED_DISK_LINE" ]] || fail "Geen imported disk gevonden als unusedX."
  IMPORTED_DISK="$(echo "$IMPORTED_DISK_LINE" | awk '{print $2}')"

  qm set "$VM_ID" \
    --scsihw virtio-scsi-pci \
    --scsi0 "$IMPORTED_DISK"
else
  echo "scsi0 bestaat al, overslaan."
fi

### ===== Stap 6: Cloud-Init disk =====

log "Voeg Cloud-Init disk toe indien nodig"
if ! qm config "$VM_ID" | grep -q '^ide2:.*cloudinit'; then
  qm set "$VM_ID" --ide2 "${CEPH_STORAGE}:cloudinit"
else
  echo "Cloud-Init disk bestaat al, overslaan."
fi

### ===== Stap 7: boot en console =====

log "Stel boot en console in"
qm set "$VM_ID" \
  --boot order=scsi0 \
  --serial0 socket \
  --vga serial0

if [[ "$ENABLE_AGENT" == "true" ]]; then
  qm set "$VM_ID" --agent enabled=1
fi

### ===== Stap 8: Cloud-Init config =====

log "Stel Cloud-Init user in"
qm set "$VM_ID" --ciuser "$CI_USER"

if [[ "$IP_MODE" == "dhcp" ]]; then
  log "Gebruik DHCP"
  qm set "$VM_ID" --ipconfig0 ip=dhcp
else
  log "Gebruik statisch IP"
  qm set "$VM_ID" --ipconfig0 "ip=${IP_ADDRESS},gw=${GATEWAY}"
fi

if [[ -f "$SSH_KEY_FILE" ]]; then
  log "Voeg SSH public key toe"
  qm set "$VM_ID" --sshkeys "$SSH_KEY_FILE"
else
  echo "SSH key file niet gevonden: $SSH_KEY_FILE"
  echo "Overslaan. Zet SSH_KEY_FILE goed als je key-based login wilt."
fi

if [[ -n "$CI_PASSWORD" ]]; then
  log "Stel Cloud-Init wachtwoord in"
  qm set "$VM_ID" --cipassword "$CI_PASSWORD"
fi

### ===== Stap 9: disk vergroten =====

log "Vergroot disk naar ${DISK_SIZE}"
qm resize "$VM_ID" scsi0 "$DISK_SIZE" || true

### ===== Klaar =====

log "Eindconfiguratie"
qm config "$VM_ID"

echo
echo "Klaar."
echo "Start de VM met:"
echo "  qm start $VM_ID"
echo
echo "Cloud-Init user dump:"
echo "  qm cloudinit dump $VM_ID user"
