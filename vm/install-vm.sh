#!/usr/bin/env bash
set -euo pipefail

# install-vm.sh - Deploy a Debian 13 VM on Proxmox with simple cloud-init defaults.
#
# Naming: <customer>-<role><index>[-<site>]
# Example: ./install-vm.sh --customer axero --role vm --index 1

STORAGE="local-lvm"
SNIPPETS_STORAGE="local"
BRIDGE="vmbr0"
VLAN="0"
CPU=2
RAM=4096
DISK="20G"
SSH_KEY_URL="https://pub.neoteq.be/vm/vm-key.pub"
CI_USER="ntq"
DNS_SERVER=""
SEARCH_DOMAIN=""
USE_DHCP=true
IP_CIDR=""
GW_IP=""
EXTRA_PACKAGES=""
ROLE="vm"
INDEX="1"
CUSTOMER=""
SITE=""

IMAGE_URL_DEFAULT="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMAGE_URL="$IMAGE_URL_DEFAULT"

usage() {
cat <<EOF_USAGE
Usage: $0 --customer <code> [options]

Storage & resources:
  --storage <name>              Disk storage (default: local-lvm)
  --snippets-storage <name>     Snippets storage (default: local)
  --bridge <vmbrX>              Bridge (default: vmbr0)
  --vlan <id>                   VLAN tag (default: 0)
  --cpu <n>                     vCPU cores (default: 2)
  --ram <MB>                    Memory (default: 4096)
  --disk <size>                 Disk size (default: 20G)

Identity & network:
  --customer <code>             REQUIRED. Customer/site code (e.g., axero)
  --site <code>                 Optional site suffix
  --role <code>                 Role (default: vm)
  --index <n>                   Index (default: 1)
  --ssh-key-url <url>           SSH pubkey (default: https://neoteq.be/install/global/key.pub)
  --ci-user <user>              Cloud-init user (default: ntq)
  --dns <ip>                    DNS server
  --search-domain <domain>      Search domain
  --dhcp                        Use DHCP (default)
  --ip <CIDR>                   Static IP (implies static mode)
  --gw <IP>                     Gateway IP (static mode)

Extras:
  --extra-packages "<pkgs>"     Additional apt packages (space separated)
  --image-url <url>             Override Debian 13 cloud image URL
  -h, --help                    Show this help
EOF_USAGE
exit 1
}

err() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "Missing: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --storage) STORAGE="$2"; shift 2;;
    --snippets-storage) SNIPPETS_STORAGE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --vlan) VLAN="$2"; shift 2;;
    --cpu) CPU="$2"; shift 2;;
    --ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --ssh-key-url) SSH_KEY_URL="$2"; shift 2;;
    --ci-user) CI_USER="$2"; shift 2;;
    --dns) DNS_SERVER="$2"; shift 2;;
    --search-domain) SEARCH_DOMAIN="$2"; shift 2;;
    --dhcp) USE_DHCP=true; shift 1;;
    --ip) IP_CIDR="$2"; USE_DHCP=false; shift 2;;
    --gw) GW_IP="$2"; shift 2;;
    --extra-packages) EXTRA_PACKAGES="$2"; shift 2;;
    --role) ROLE="$2"; shift 2;;
    --index) INDEX="$2"; shift 2;;
    --customer) CUSTOMER="$2"; shift 2;;
    --site) SITE="$2"; shift 2;;
    --image-url) IMAGE_URL="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

need qm; need awk; need sed; need curl

[[ -n "$CUSTOMER" ]] || err "--customer required"
[[ "$INDEX" =~ ^[0-9]+$ ]] || err "--index must be number"
if ! $USE_DHCP && [[ -z "$IP_CIDR" ]]; then
  err "--ip required for static configuration"
fi

NAME="${CUSTOMER}-${ROLE}${INDEX}"
[[ -n "$SITE" ]] && NAME="${NAME}-${SITE}"

SSH_KEY_FILE="/tmp/${NAME}.pub"
trap 'rm -f "$SSH_KEY_FILE"' EXIT

curl -fsSL "$SSH_KEY_URL" -o "$SSH_KEY_FILE"
[[ -r "$SSH_KEY_FILE" ]] || err "SSH pubkey not readable"

SNIPPETS_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPETS_DIR"
IMAGES_DIR="/var/lib/vz/template/tmp"
mkdir -p "$IMAGES_DIR"

name_exists_cluster() {
  local wanted="$1" existing_names
  if command -v pvesh >/dev/null 2>&1; then
    existing_names=$(pvesh get /cluster/resources --type vm 2>/dev/null | \
      grep -o '"name":"[^"]*"' | cut -d: -f2 | tr -d '"')
    if [[ -n "$existing_names" ]] && echo "$existing_names" | grep -qx "$wanted"; then
      return 0
    fi
  fi
  qm list 2>/dev/null | awk 'NR>1{print $2}' | grep -qx "$wanted"
}

if name_exists_cluster "$NAME"; then
  err "A VM/CT with name $NAME already exists"
fi

VMID=$(pvesh get /cluster/nextid)

IMG_PATH="${IMAGES_DIR}/$(basename "$IMAGE_URL")"
if [[ ! -s "$IMG_PATH" ]]; then
  echo "Downloading Debian 13 cloud image..."
  curl -fL "$IMAGE_URL" -o "$IMG_PATH"
else
  echo "Using cached image: $IMG_PATH"
fi

qm create "$VMID" --name "$NAME" --memory "$RAM" --cores "$CPU" --net0 "virtio,bridge=${BRIDGE}"
qm set "$VMID" --scsihw virtio-scsi-pci

qm importdisk "$VMID" "$IMG_PATH" "$STORAGE" --format qcow2 >/tmp/import.$VMID.log 2>&1 || {
  echo "Import-Log:" >&2
  cat /tmp/import.$VMID.log >&2
  err "qm importdisk failed"
}

volid=$(pvesm list "$STORAGE" --vmid "$VMID" --content images | awk 'NR==2{print $1}')
[[ -n "$volid" ]] || err "Could not determine volid after importdisk"

qm set "$VMID" --scsi0 "${volid}"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot c --bootdisk scsi0
qm set "$VMID" --serial0 socket --vga serial0
qm set "$VMID" --agent enabled=1

qm resize "$VMID" scsi0 "$DISK" || true

NETCFG="virtio,bridge=${BRIDGE}"
[[ "$VLAN" != "0" ]] && NETCFG="${NETCFG},tag=${VLAN}"
qm set "$VMID" --net0 "$NETCFG"

qm set "$VMID" --ciuser "$CI_USER"
qm set "$VMID" --sshkey "$SSH_KEY_FILE"
[[ -n "$DNS_SERVER" ]] && qm set "$VMID" --nameserver "$DNS_SERVER"
[[ -n "$SEARCH_DOMAIN" ]] && qm set "$VMID" --searchdomain "$SEARCH_DOMAIN"

if $USE_DHCP; then
  qm set "$VMID" --ipconfig0 ip=dhcp
else
  ipcfg="ip=${IP_CIDR}"
  [[ -n "$GW_IP" ]] && ipcfg="${ipcfg},gw=${GW_IP}"
  qm set "$VMID" --ipconfig0 "$ipcfg"
fi

UD_FILE="${SNIPPETS_DIR}/${NAME}-user-data.yaml"
cat > "$UD_FILE" <<EOF_CLOUD
#cloud-config
hostname: ${NAME}
fqdn: ${NAME}
users:
  - name: ${CI_USER}
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: sudo
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys: ["$(cat $SSH_KEY_FILE)"]
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
EOF_CLOUD

if [[ -n "$EXTRA_PACKAGES" ]]; then
  for pkg in $EXTRA_PACKAGES; do
    printf '  - %s\n' "$pkg" >> "$UD_FILE"
  done
fi

cat >> "$UD_FILE" <<'EOF_CLOUD_TAIL'
runcmd:
  - [ systemctl, enable, "--now", qemu-guest-agent ]
EOF_CLOUD_TAIL

qm set "$VMID" --cicustom "user=${SNIPPETS_STORAGE}:snippets/$(basename "$UD_FILE")"

echo "Starting VM $VMID ($NAME)..."
qm start "$VMID"
echo "Done. VM $NAME (ID $VMID) is booting with cloud-init."
