#!/usr/bin/env bash
set -euo pipefail

# deploy_ntq_ops_vm.sh (v3) - Direct deploy from Debian 13 cloud image (no template)
#
# Lädt das Debian 13 Cloud-Image (QCOW2), erstellt direkt eine VM und hängt Cloud-Init an.
# Naming: ntq-<customer>-<role><index>[-<site>]
#
# Beispiel DHCP:
#   ./deploy_ntq_ops_vm.sh \
#     --customer musterfirma --role ops --index 1 \
#     --storage local-lvm --snippets-storage local \
#     --bridge vmbr0 --cpu 2 --ram 4096 --disk 20G \
#     --ssh-key-url https://neoteq.be/install/global/key.pub \
#     --dhcp \
#     --tailscale-authkey tskey-XXXXXXXXXXXXXXXXXXXXXXXX
#
# Beispiel statische IP:
#   ./deploy_ntq_ops_vm.sh \
#     --customer musterfirma --role ops --index 1 \
#     --ip 10.0.10.50/24 --gw 10.0.10.1 --dns 10.0.10.10 \
#     --storage local-lvm --snippets-storage local \
#     --bridge vmbr0 --ssh-key-url https://neoteq.be/install/global/key.pub

STORAGE="local-lvm"
SNIPPETS_STORAGE="local"
BRIDGE="vmbr0"
VLAN="0"
CPU=2
RAM=4096
DISK="20G"
SSH_KEY_URL="https://neoteq.be/install/global/key.pub"
CI_USER="ntq"
DNS_SERVER=""
SEARCH_DOMAIN=""
USE_DHCP=true
IP_CIDR=""
GW_IP=""
TAILSCALE_AUTHKEY=""
EXTRA_PACKAGES=""
ROLE="orb"
INDEX="1"
CUSTOMER=""
SITE=""

IMAGE_URL_DEFAULT="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMAGE_URL="$IMAGE_URL_DEFAULT"

usage() {
cat <<EOF
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
  --customer <code>             REQUIRED. Customer/site code (e.g., axero, dehz)
  --site <code>                 Optional site suffix
  --role <code>                 Role (default: ops)
  --index <n>                   Index (default: 1)
  --ssh-key-url <url>           SSH pubkey (default: https://neoteq.be/install/global/key.pub)
  --ci-user <user>              Cloud-init user (default: ntq)
  --dns <ip>                    DNS server
  --search-domain <domain>      Search domain
  --dhcp                        Use DHCP (default)
  --ip <CIDR>                   Static IP (implies static mode)
  --gw <IP>                     Gateway IP

Integrations:
  --tailscale-authkey <key>     Tailscale up
  --extra-packages "<pkgs>"     Extra apt packages

Image:
  --image-url <url>             Override Debian 13 cloud image URL
EOF
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
    --tailscale-authkey) TAILSCALE_AUTHKEY="$2"; shift 2;;
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
[[ -n "$TAILSCALE_AUTHKEY" ]] || err "--tailscale-authkey required"
[[ "$INDEX" =~ ^[0-9]+$ ]] || err "--index must be number"

NAME="ntq-${CUSTOMER}-${ROLE}${INDEX}"
[[ -n "$SITE" ]] && NAME="${NAME}-${SITE}"

SSH_KEY_FILE="/tmp/${NAME}.pub"

curl -fsSL "$SSH_KEY_URL" -o "$SSH_KEY_FILE"

[[ -r "$SSH_KEY_FILE" ]] || err "SSH pubkey not readable"

SNIPPETS_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPETS_DIR"
IMAGES_DIR="/var/lib/vz/template/tmp"
mkdir -p "$IMAGES_DIR"

next_vmid() {
  # Try cluster-wide via pvesh (includes VMs & CTs)
  if existing=$(pvesh get /cluster/resources --type vm 2>/dev/null | \
                grep -o '"vmid":[0-9]\+' | cut -d: -f2 | sort -n | uniq); then
    :
  else
    # Fallback: local node only (VMs + CTs)
    existing=$(
      { qm list 2>/dev/null | awk 'NR>1{print $1}'; \
        pct list 2>/dev/null | awk 'NR>1{print $1}'; } | sort -n | uniq
    )
  fi

  vmid=900
  while echo "$existing" | grep -qx "$vmid"; do
    vmid=$((vmid+1))
  done
  echo "$vmid"
}

# --- OPTIONAL: clusterweiter Namenskonflikt-Check (statt nur qm list auf dem Node) ---
name_exists_cluster() {
  pvesh get /cluster/resources --type vm 2>/dev/null | \
    grep -o '"name":"[^"]*"' | cut -d: -f2 | tr -d '"' | grep -qx "$1"
}

# usage:
if name_exists_cluster "$NAME"; then
  err "A VM/CT with name $NAME already exists in the cluster"
fi

VMID=$(next_vmid)

! qm list | awk 'NR>1{print $2}' | grep -qx "$NAME" || err "VM $NAME already exists"

IMG_PATH="${IMAGES_DIR}/$(basename "$IMAGE_URL")"
if [[ ! -s "$IMG_PATH" ]]; then
  echo "Downloading Debian 13 cloud image..."
  curl -fL "$IMAGE_URL" -o "$IMG_PATH"
else
  echo "Using cached image: $IMG_PATH"
fi

qm create "$VMID" --name "$NAME" --memory "$RAM" --cores "$CPU" --net0 "virtio,bridge=${BRIDGE}"
qm set "$VMID" --scsihw virtio-scsi-pci

# Import
qm importdisk "$VMID" "$IMG_PATH" "$STORAGE" --format qcow2 >/tmp/import.$VMID.log 2>&1

# Vol-ID robust ermitteln (erstes Image-Volume dieser VM auf dem Storage)
volid=$(pvesm list "$STORAGE" --vmid "$VMID" --content images | awk 'NR==2{print $1}')
if [[ -z "$volid" ]]; then
  echo "Import-Log:"
  cat /tmp/import.$VMID.log >&2
  err "Could not determine volid after importdisk"
fi

# Jetzt korrekt anhängen:
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
  [[ -n "$IP_CIDR" ]] || err "--ip required"
  ipcfg="ip=${IP_CIDR}"
  [[ -n "$GW_IP" ]] && ipcfg="${ipcfg},gw=${GW_IP}"
  qm set "$VMID" --ipconfig0 "$ipcfg"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/userdata-ops.yaml.tmpl"
[[ -r "$TEMPLATE_PATH" ]] || err "Missing template $TEMPLATE_PATH"

UD_FILE="${SNIPPETS_DIR}/${NAME}-user-data.yaml"
cp "$TEMPLATE_PATH" "$UD_FILE"

ESC_NAME=$(printf '%s' "$NAME" | sed -e 's/[\/&]/\\&/g')
ESC_CUSTOMER=$(printf '%s' "$CUSTOMER" | sed -e 's/[\/&]/\\&/g')
ESC_ROLE=$(printf '%s' "$ROLE" | sed -e 's/[\/&]/\\&/g')

sed -i "s/{{HOSTNAME}}/${ESC_NAME}/g" "$UD_FILE"
sed -i "s/{{CUSTOMER}}/${ESC_CUSTOMER}/g" "$UD_FILE"
sed -i "s/{{ROLE}}/${ESC_ROLE}/g" "$UD_FILE"

if [[ -n "$EXTRA_PACKAGES" ]]; then
  sed -i "s|#EXTRA_PACKAGES_PLACEHOLDER|  - ${EXTRA_PACKAGES}|g" "$UD_FILE"
fi

if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
  sed -i "s|#TAILSCALE_UP_CMD|tailscale up --authkey ${TAILSCALE_AUTHKEY} --hostname ${NAME} --accept-dns=false --ssh|g" "$UD_FILE"
else
  sed -i "s|#TAILSCALE_UP_CMD|echo 'No tailscale auth key provided'|g" "$UD_FILE"
fi

qm set "$VMID" --cicustom "user=${SNIPPETS_STORAGE}:snippets/$(basename "$UD_FILE")"

echo "Starting VM $VMID ($NAME)..."
qm start "$VMID"
echo "Done. VM $NAME (ID $VMID) is booting with cloud-init."