#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/ionoxdev/ionox-infra-proxmox/main"
TMP_SCRIPT="/tmp/bootstrap-cloud-vm.sh"

curl -fsSL "${REPO_RAW_BASE}/scripts/bootstrap-cloud-vm.sh" -o "${TMP_SCRIPT}"
chmod +x "${TMP_SCRIPT}"

exec "${TMP_SCRIPT}" "$@"
