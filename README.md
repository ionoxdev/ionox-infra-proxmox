# ionox-infra-proxmox

Bootstrap een Proxmox VM vanaf een cloud image, met:

- interactieve installer
- staging op file-based storage
- import naar target storage
- Cloud-Init configuratie
- SSH key support
- DHCP of statisch IP

## Starten vanaf GitHub

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ionoxdev/ionox-infra-proxmox/main/install.sh)
