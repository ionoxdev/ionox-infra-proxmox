#!/usr/bin/env bash
set -euo pipefail

VM_ID="${VM_ID}"
VM_NAME="${VM_NAME}"
IMAGE_VOLID="${IMAGE_VOLID}"
TARGET_STORAGE="${TARGET_STORAGE}"
BRIDGE="${BRIDGE}"
CI_USER="${CI_USER}"

SSH_KEY="$(echo "${SSH_KEY_B64:-}" | base64 -d 2>/dev/null || true)"
CI_PASSWORD="$(echo "${CI_PASSWORD_B64:-}" | base64 -d 2>/dev/null || true)"

IP_MODE="${IP_MODE}"
IP_ADDRESS="${IP_ADDRESS:-}"
GATEWAY="${GATEWAY:-}"

DISK_SIZE="${DISK_SIZE}"
USE_UEFI="${USE_UEFI}"
ENABLE_AGENT="${ENABLE_AGENT}"

STORAGE_PATH="/mnt/pve/cloudimages"
REL="${IMAGE_VOLID#*:}"
IMAGE_PATH="$STORAGE_PATH/$REL"

qm create "$VM_ID" --name "$VM_NAME" --net0 virtio,bridge="$BRIDGE"

qm importdisk "$VM_ID" "$IMAGE_PATH" "$TARGET_STORAGE"

DISK="$(qm config "$VM_ID" | grep unused | awk '{print $2}')"

qm set "$VM_ID" --scsihw virtio-scsi-pci --scsi0 "$DISK"
qm set "$VM_ID" --ide2 "$TARGET_STORAGE":cloudinit
qm set "$VM_ID" --boot order=scsi0

[[ "$USE_UEFI" == "true" ]] && qm set "$VM_ID" --bios ovmf
[[ "$ENABLE_AGENT" == "true" ]] && qm set "$VM_ID" --agent enabled=1

qm set "$VM_ID" --ciuser "$CI_USER"

if [[ "$IP_MODE" == "dhcp" ]]; then
  qm set "$VM_ID" --ipconfig0 ip=dhcp
else
  qm set "$VM_ID" --ipconfig0 ip="$IP_ADDRESS",gw="$GATEWAY"
fi

[[ -n "$SSH_KEY" ]] && qm set "$VM_ID" --sshkeys <(echo "$SSH_KEY")
[[ -n "$CI_PASSWORD" ]] && qm set "$VM_ID" --cipassword "$CI_PASSWORD"

qm resize "$VM_ID" scsi0 "$DISK_SIZE"

echo "DONE: qm start $VM_ID"
