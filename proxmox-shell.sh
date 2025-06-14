#!/bin/bash

# Automated Proxmox VM deployment script for Pterodactyl infrastructure (dedicated node setup)
# Author: Oexyz
# Version: 3.8.1 (Updated for Proxmox 8.4.0 compatibility)

# Ensure dialog is installed
if ! command -v dialog &> /dev/null; then
    echo "Dialog not found. Installing..."
    apt-get update && apt-get install -y dialog
fi

exec 3>&1

clear
VMID=$(dialog --inputbox "Enter VMID:" 8 40 2>&1 1>&3)

clear
VM_NAME=$(dialog --inputbox "Enter VM Name:" 8 40 2>&1 1>&3)

clear
SERVICE=$(dialog --menu "Select Service Role:" 15 50 5 \
  panel "Pterodactyl Panel" \
  mariadb "MariaDB Cluster" \
  redis "Redis Cache" \
  haproxy "HAProxy Load Balancer" \
  none "No service installation" \
  2>&1 1>&3)

clear
STATIC_IP=$(dialog --inputbox "Enter Static IP Address (e.g. 192.168.100.10/24):" 8 50 2>&1 1>&3)

clear
GATEWAY=$(dialog --inputbox "Enter Gateway IP Address:" 8 40 2>&1 1>&3)

clear
VM_PASSWORD=$(dialog --insecure --passwordbox "Enter VM User Password:" 8 40 2>&1 1>&3)

clear
BRIDGE=$(dialog --radiolist "Select Network Bridge:" 15 50 4 \
  vmbr1 "Default bridge" on \
  vmbr0 "Alternative bridge" off \
  2>&1 1>&3)

clear
CPU=$(dialog --inputbox "Enter Number of CPU Cores:" 8 40 2>&1 1>&3)
clear
MEMORY=$(dialog --inputbox "Enter Memory in MB:" 8 40 2>&1 1>&3)
clear
STORAGE=$(dialog --inputbox "Enter Storage Pool Name (e.g. local-lvm):" 8 40 2>&1 1>&3)
clear
DISK_SIZE=$(dialog --inputbox "Enter Disk Size in GB:" 8 40 2>&1 1>&3)
DISK_SIZE="${DISK_SIZE}G"

# ISO image
ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
ISO_NAME="ubuntu-24.04.2-live-server-amd64.iso"
ISO_PATH="/var/lib/vz/template/iso/$ISO_NAME"

if [ ! -f "$ISO_PATH" ]; then
  echo "[+] ISO not found — downloading..."
  wget -O "$ISO_PATH" "$ISO_URL" || { echo "[!] ISO download failed"; exit 1; }
else
  echo "[+] ISO already exists."
fi

# Create VM
echo "[+] Creating VM $VMID - $VM_NAME ($SERVICE)"

qm create $VMID \
  --name $VM_NAME \
  --memory $MEMORY \
  --cores $CPU \
  --net0 virtio,bridge=$BRIDGE \
  --scsihw virtio-scsi-pci \
  --scsi0 ${STORAGE}:${DISK_SIZE},discard=on,ssd=1 \
  --ide2 local:iso/$ISO_NAME,media=cdrom \
  --boot order=scsi0;ide2 \
  --bootdisk scsi0 \
  --serial0 socket \
  --vga serial0 \
  --machine pc-i440fx-8.1 \
  --bios ovmf \
  --efidisk0 ${STORAGE}:4,efitype=4m,format=raw \
  --agent enabled=1

# Wait for config file
sleep 2
if [ ! -f "/etc/pve/nodes/$(hostname)/qemu-server/$VMID.conf" ]; then
  echo "[!] VM configuration file was not created. Aborting."
  exit 1
fi

# Cloud-init setup
qm set $VMID --ciuser ubuntu --cipassword "$VM_PASSWORD"
qm set $VMID --ipconfig0 ip=$STATIC_IP,gw=$GATEWAY

mkdir -p /var/lib/vz/snippets
CLOUDINIT_SSH_DISABLE=$(cat <<EOF
#cloud-config
runcmd:
  - systemctl disable ssh
  - systemctl stop ssh
  - rm -f /etc/ssh/sshd_config
EOF
)
echo "$CLOUDINIT_SSH_DISABLE" > /var/lib/vz/snippets/disable-ssh-$VMID.yaml
qm set $VMID --cicustom "user=local:snippets/disable-ssh-$VMID.yaml"

# Start VM
echo -e "\n[✔️] VM created. Starting VM..."
qm start $VMID

# Wait for VM to boot
echo -n "[⏳] Waiting for VM to start..."
while ! qm status $VMID | grep -q "status: running"; do
  sleep 1
done
echo -e "\r[✔️] VM is running."

# Wait for cloud-init
echo -n "[⏳] Waiting for cloud-init to finish..."
while ! qm guest exec $VMID --timeout 5 -- bash -c "test -f /var/lib/cloud/instance/boot-finished" &>/dev/null; do
  sleep 2
done
echo -e "\r[✔️] Cloud-init completed."

# Optional: Wait for updates
echo "[⏳] Waiting for system updates (if any)..."
sleep 10

# Optional service installation
install_service() {
  case $SERVICE in
    panel)
      echo "[✔️] Installing Pterodactyl Panel..."
      wget -O /tmp/panel_install.sh https://raw.githubusercontent.com/Oexyz/proxmox-pterodactyl/main/panel_install.sh
      bash /tmp/panel_install.sh
      ;;
    mariadb)
      echo "[✔️] Installing MariaDB Galera Node..."
      wget -O /tmp/mariadb_install.sh https://raw.githubusercontent.com/Oexyz/proxmox-pterodactyl/main/mariadb_install.sh
      bash /tmp/mariadb_install.sh
      ;;
    redis)
      echo "[✔️] Installing Redis Cache Node..."
      wget -O /tmp/redis_install.sh https://raw.githubusercontent.com/Oexyz/proxmox-pterodactyl/main/redis_install.sh
      bash /tmp/redis_install.sh
      ;;
    haproxy)
      echo "[✔️] Installing HAProxy Node..."
      wget -O /tmp/haproxy_install.sh https://raw.githubusercontent.com/Oexyz/proxmox-pterodactyl/main/haproxy_install.sh
      bash /tmp/haproxy_install.sh
      ;;
    none)
      echo "[✔️] No service installation selected."
      ;;
  esac
}

if [[ "$SERVICE" != "none" ]]; then
  install_service
fi

dialog --msgbox "✅ VM $VMID ($VM_NAME) is ready!\n\nStatic IP: $STATIC_IP\nGateway: $GATEWAY\nService: $SERVICE\nCores: $CPU | RAM: $MEMORY MB | Disk: $DISK_SIZE\n\nUse the Proxmox console to access the VM." 14 60

exec 3>&-
