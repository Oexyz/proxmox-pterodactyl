#!/usr/bin/env bash

# Proxmox Debian 12 VM Deployment Script with Service Role Support
# Combines community-scripts logic with custom automation
# Author: Oexyz

set -e

# === CONFIGURATION ===
DEFAULT_CPU=32
DEFAULT_RAM_MB=245760
DEFAULT_DISK_GB=3000
DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2"
DEBIAN_IMAGE_NAME="debian-12-nocloud-amd64.qcow2"
DEBIAN_IMAGE_PATH="/var/lib/vz/template/qcow/$DEBIAN_IMAGE_NAME"

# === Ensure dialog is installed ===
if ! command -v dialog &> /dev/null; then
    echo "Dialog not found. Installing..."
    apt-get update && apt-get install -y dialog
fi

exec 3>&1

# === Collect Inputs ===
clear
VMID=$(dialog --inputbox "Enter VMID:" 8 40 2>&1 1>&3)

clear
VM_NAME=$(dialog --inputbox "Enter VM Name:" 8 40 2>&1 1>&3)

clear
SERVICE=$(dialog --menu "Select Service Role:" 15 50 5   panel "Pterodactyl Panel"   mariadb "MariaDB Cluster"   redis "Redis Cache"   haproxy "HAProxy Load Balancer"   none "No service installation"   2>&1 1>&3)

clear
STATIC_IP=$(dialog --inputbox "Enter Static IP Address (e.g. 192.168.100.10/24):" 8 50 2>&1 1>&3)

clear
GATEWAY=$(dialog --inputbox "Enter Gateway IP Address:" 8 40 2>&1 1>&3)

clear
VM_PASSWORD=$(dialog --insecure --passwordbox "Enter VM User Password:" 8 40 2>&1 1>&3)

clear
BRIDGE=$(dialog --radiolist "Select Network Bridge:" 15 50 4   vmbr1 "Default bridge" on   vmbr0 "Alternative bridge" off   2>&1 1>&3)

# === User Input for Default or Custom Hardware Configuration ===
clear
USE_DEFAULT=$(dialog --yesno "Use default hardware configuration?\n\nCPU: 32 cores (2 sockets)\nRAM: 240 GB\nDisk: 3 TB" 10 50 3>&1 1>&2 2>&3; echo $?)

if [ "$USE_DEFAULT" -eq 0 ]; then
  CPU=$DEFAULT_CPU
  SOCKETS=2
  MEMORY=$DEFAULT_RAM_MB
  DISK_SIZE="${DEFAULT_DISK_GB}G"
else
  clear
  CPU=$(dialog --inputbox "Enter number of CPU cores:" 8 40 2>&1 1>&3)
  SOCKETS=$(dialog --inputbox "Enter number of CPU sockets (default: 1):" 8 40 2>&1 1>&3)
  SOCKETS=${SOCKETS:-1}

  clear
  MEMORY=$(dialog --inputbox "Enter RAM in MB:" 8 40 2>&1 1>&3)

  clear
  DISK_GB=$(dialog --inputbox "Enter Disk Size in GB:" 8 40 2>&1 1>&3)
  DISK_SIZE="${DISK_GB}G"
fi

# === Download Debian Image ===
mkdir -p /var/lib/vz/template/qcow
if [ ! -f "$DEBIAN_IMAGE_PATH" ]; then
  echo "[+] Downloading Debian 12 cloud image..."
  wget -O "$DEBIAN_IMAGE_PATH" "$DEBIAN_IMAGE_URL" || { echo "[!] Failed to download Debian image"; exit 1; }
else
  echo "[+] Debian image already exists."
fi

# === Create VM ===
echo "[+] Creating VM $VMID - $VM_NAME ($SERVICE)"
qm create $VMID   --name $VM_NAME   --memory $MEMORY   --cores $CPU   --sockets $SOCKETS   --net0 virtio,bridge=$BRIDGE   --scsihw virtio-scsi-pci   --agent enabled=1   --bios ovmf   --machine pc-i440fx-8.1   --serial0 socket   --vga serial0

# Ask user for target disk device (e.g., scsi0, sata0, ide0)
clear
DISK_DEVICE=$(dialog --inputbox "Enter disk device to attach (e.g., scsi0):" 8 40 "scsi0" 2>&1 1>&3)

# Ask user for storage target (e.g., local-lvm, fast-ssd)
clear
STORAGE=$(dialog --inputbox "Enter storage target (e.g., local-lvm):" 8 40 "local-lvm" 2>&1 1>&3)

# Import disk
qm importdisk $VMID "$DEBIAN_IMAGE_PATH" $STORAGE --format qcow2

# Attach disk to specified device
qm set $VMID --${DISK_DEVICE} $STORAGE:vm-${VMID}-disk-0


# === Attach Disk and Configure ===
qm set $VMID   --scsi0 $STORAGE:vm-$VMID-disk-0   --boot order=scsi0   --bootdisk scsi0   --efidisk0 ${STORAGE}:4,efitype=4m,format=raw

# === Resize Disk ===
qm resize $VMID scsi0 $DISK_SIZE

# === Cloud-init Setup ===
qm set $VMID --ciuser debian --cipassword "$VM_PASSWORD"
qm set $VMID --ipconfig0 ip=$STATIC_IP,gw=$GATEWAY

# === Disable SSH via Cloud-init Snippet ===
mkdir -p /var/lib/vz/snippets
cat <<EOF > /var/lib/vz/snippets/disable-ssh-$VMID.yaml
#cloud-config
runcmd:
  - systemctl disable ssh
  - systemctl stop ssh
  - rm -f /etc/ssh/sshd_config
EOF

qm set $VMID --cicustom "user=local:snippets/disable-ssh-$VMID.yaml"

# === Start VM ===
echo -e "\n[✔️] VM created. Starting VM..."
qm start $VMID

# === Wait for VM to Boot ===
echo -n "[⏳] Waiting for VM to start..."
while ! qm status $VMID | grep -q "status: running"; do
  sleep 1
done
echo -e "\r[✔️] VM is running."

# === Wait for Cloud-init ===
echo -n "[⏳] Waiting for cloud-init to finish..."
while ! qm guest exec $VMID --timeout 5 -- bash -c "test -f /var/lib/cloud/instance/boot-finished" &>/dev/null; do
  sleep 2
done
echo -e "\r[✔️] Cloud-init completed."

# === Optional Service Installation ===
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

# === Final Message ===
dialog --msgbox "✅ VM $VMID ($VM_NAME) is ready!\n\nStatic IP: $STATIC_IP\nGateway: $GATEWAY\nService: $SERVICE\nCores: $CPU | RAM: ${MEMORY}MB | Disk: $DISK_SIZE\n\nUse the Proxmox console to access the VM." 14 60

exec 3>&-
