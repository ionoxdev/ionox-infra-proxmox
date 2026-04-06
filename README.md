# IONOX – VM maken van Cloud Image (Proxmox + Ceph + Cloud-Init)

Deze handleiding laat stap voor stap zien hoe je een VM maakt vanuit een cloud image, deze op Ceph zet en configureert met Cloud-Init.

---

## 🔹 Stap 1 – Download de cloud image

Download een officiële cloud image (voorbeeld: Ubuntu):

```bash
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
```

---

## 🔹 Stap 2 – Maak een nieuwe VM aan

Maak een lege VM (zonder disk):

```bash
qm create 9000 \
  --name ubuntu-cloud-template \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0
```

---

## 🔹 Stap 3 – Import de disk naar Ceph

Importeer de gedownloade image direct naar Ceph storage:

```bash
qm importdisk 9000 jammy-server-cloudimg-amd64.img ceph-storage
```

---

## 🔹 Stap 4 – Koppel de disk aan de VM

```bash
qm set 9000 \
  --scsihw virtio-scsi-pci \
  --scsi0 ceph-storage:vm-9000-disk-0
```

---

## 🔹 Stap 5 – Voeg Cloud-Init toe

```bash
qm set 9000 --ide2 ceph-storage:cloudinit
```

---

## 🔹 Stap 6 – Stel boot en console in

```bash
qm set 9000 \
  --boot c \
  --bootdisk scsi0 \
  --serial0 socket \
  --vga serial0
```

---

## 🔹 Stap 7 – Configureer Cloud-Init

Voorbeeld configuratie:

```bash
qm set 9000 \
  --ciuser ubuntu \
  --sshkey ~/.ssh/id_rsa.pub \
  --ipconfig0 ip=dhcp
```

---

## 🔹 Stap 8 – (Optioneel) Maak er een template van

```bash
qm template 9000
```

---

## 🔹 Stap 9 – VM starten (of clone gebruiken)

Direct starten:

```bash
qm start 9000
```

Of clone maken:

```bash
qm clone 9000 100 --name ubuntu-vm-01
qm start 100
```

---

## 🔥 Resultaat

- VM disk draait op **Ceph (cluster-wide)**
- Cloud-Init configureert automatisch:
  - user
  - SSH toegang
  - netwerk

---

## ⚠️ Belangrijk

- Gebruik **Ceph voor runtime disks**
- Gebruik **local/NFS alleen als staging**
- VM is nu **op elke node in het cluster te gebruiken**

---

## TL;DR

1. Download image
2. Maak lege VM
3. Import disk → Ceph
4. Koppel disk + Cloud-Init
5. Start of maak template

Klaar.

