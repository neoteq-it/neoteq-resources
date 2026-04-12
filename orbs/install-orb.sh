#!/usr/bin/env bash
set -euo pipefail

print_logo() {
  cat <<'EOF'

  █            ███
  ████         ██████
  ███████      ████████
  █████████    ███████████
   ███████████    ███████████
      ███████████   █████████
  ███   ███████████    ██████
  █████    ███████████    ███
  ████████    ███████████
  ███████████    ██████████
     ██████████    ██████████
       ████████       ███████
          █████          ████
             ██            ██
EOF
}

header_info() {
  clear 2>/dev/null || true

  print_logo

  cat <<EOF

   NEOTEQ VM Deployment Script
   Debian 13 Cloud-Init Image

EOF
}

header_info

# install-orb.sh - Direct deploy from Debian 13 cloud image (no template)
#
# Lädt das Debian 13 Cloud-Image (QCOW2), erstellt direkt eine VM und hängt Cloud-Init an.
# Naming: ntq-<customer>-<role><index>[-<site>]
#
# Beispiel DHCP:
#   ./install-orb.sh \
#     --customer musterfirma --role orb --index 1 \
#     --storage local-lvm \
#     --bridge vmbr0 --cpu 2 --ram 4096 --disk 20G \
#     --ssh-key-url https://pub.neoteq.be/orbs/key.pub \
#     --dhcp \
#     --tailscale-authkey tskey-XXXXXXXXXXXXXXXXXXXXXXXX
#
# Beispiel statische IP:
#   ./install-orb.sh \
#     --customer musterfirma --role orb --index 1 \
#     --ip 10.0.10.50/24 --gw 10.0.10.1 --dns 10.0.10.10 \
#     --storage local-lvm --bridge vmbr0 \
#     --tailscale-authkey tskey-XXXXXXXXXXXXXXXXXXXXXXXX

STORAGE="local-lvm"
BRIDGE="vmbr0"
VLAN="0"
CPU=2
RAM=4096
DISK="20G"
SSH_KEY_URL="https://pub.neoteq.be/orbs/key.pub"
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
  local status="${1:-1}"
  cat <<EOF
Usage: $0 --customer <code> [options]

Storage & resources:
  --storage <name>              Disk storage (default: local-lvm)
  --snippets-storage <name>     Ignored; kept for backward compatibility
  --bridge <vmbrX>              Bridge (default: vmbr0)
  --vlan <id>                   VLAN tag (default: 0)
  --cpu <n>                     vCPU cores (default: 2)
  --ram <MB>                    Memory (default: 4096)
  --disk <size>                 Disk size (default: 20G)

Identity & network:
  --customer <code>             REQUIRED. Customer/site code (e.g., axero, dehz)
  --site <code>                 Optional site suffix
  --role <code>                 Role (default: orb)
  --index <n>                   Index (default: 1)
  --ssh-key-url <url>           SSH pubkey (default: https://pub.neoteq.be/orbs/key.pub)
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
exit "$status"
}

err() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "Missing: $1"; }

WORK_FILE=""
SSH_KEY_FILE=""
IMPORT_LOG=""

cleanup() {
  local status=$?
  if [[ -n "${WORK_FILE:-}" && -e "$WORK_FILE" ]]; then
    rm -f "$WORK_FILE" || true
  fi
  if [[ -n "${SSH_KEY_FILE:-}" && -e "$SSH_KEY_FILE" ]]; then
    rm -f "$SSH_KEY_FILE" || true
  fi
  if [[ -n "${IMPORT_LOG:-}" && -e "$IMPORT_LOG" ]]; then
    rm -f "$IMPORT_LOG" || true
  fi
  return "$status"
}
trap cleanup EXIT

arg_value() {
  [[ $# -ge 2 && -n "${2:-}" && "${2:0:1}" != "-" ]] || err "$1 requires a value"
  printf '%s' "$2"
}

validate_slug() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[a-z0-9][a-z0-9-]*$ ]] || err "$name must match ^[a-z0-9][a-z0-9-]*$"
}

normalize_packages() {
  printf '%s' "$1" | tr ' ' ',' | sed -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --storage) STORAGE=$(arg_value "$1" "${2:-}"); shift 2;;
    --snippets-storage) arg_value "$1" "${2:-}" >/dev/null; shift 2;;
    --bridge) BRIDGE=$(arg_value "$1" "${2:-}"); shift 2;;
    --vlan) VLAN=$(arg_value "$1" "${2:-}"); shift 2;;
    --cpu) CPU=$(arg_value "$1" "${2:-}"); shift 2;;
    --ram) RAM=$(arg_value "$1" "${2:-}"); shift 2;;
    --disk) DISK=$(arg_value "$1" "${2:-}"); shift 2;;
    --ssh-key-url) SSH_KEY_URL=$(arg_value "$1" "${2:-}"); shift 2;;
    --ci-user) CI_USER=$(arg_value "$1" "${2:-}"); shift 2;;
    --dns) DNS_SERVER=$(arg_value "$1" "${2:-}"); shift 2;;
    --search-domain) SEARCH_DOMAIN=$(arg_value "$1" "${2:-}"); shift 2;;
    --dhcp) USE_DHCP=true; shift 1;;
    --ip) IP_CIDR=$(arg_value "$1" "${2:-}"); USE_DHCP=false; shift 2;;
    --gw) GW_IP=$(arg_value "$1" "${2:-}"); shift 2;;
    --tailscale-authkey) TAILSCALE_AUTHKEY=$(arg_value "$1" "${2:-}"); shift 2;;
    --extra-packages) EXTRA_PACKAGES=$(arg_value "$1" "${2:-}"); shift 2;;
    --role) ROLE=$(arg_value "$1" "${2:-}"); shift 2;;
    --index) INDEX=$(arg_value "$1" "${2:-}"); shift 2;;
    --customer) CUSTOMER=$(arg_value "$1" "${2:-}"); shift 2;;
    --site) SITE=$(arg_value "$1" "${2:-}"); shift 2;;
    --image-url) IMAGE_URL=$(arg_value "$1" "${2:-}"); shift 2;;
    -h|--help) usage 0;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

need awk; need sed; need curl; need grep; need cut; need sort; need tr; need basename; need cp; need mktemp
[[ -n "$CUSTOMER" ]] || err "--customer required"
[[ -n "$TAILSCALE_AUTHKEY" ]] || err "--tailscale-authkey required"
validate_slug "--customer" "$CUSTOMER"
validate_slug "--role" "$ROLE"
[[ -z "$SITE" ]] || validate_slug "--site" "$SITE"
[[ "$INDEX" =~ ^[0-9]+$ ]] || err "--index must be number"
[[ "$CPU" =~ ^[1-9][0-9]*$ ]] || err "--cpu must be a positive number"
[[ "$RAM" =~ ^[1-9][0-9]*$ ]] || err "--ram must be a positive number"
[[ "$VLAN" =~ ^[0-9]+$ && "$VLAN" -le 4094 ]] || err "--vlan must be between 0 and 4094"
[[ "$DISK" =~ ^[1-9][0-9]*[KMGTP]?$ ]] || err "--disk must be a size like 20G"
[[ "$CI_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || err "--ci-user must be a valid Linux username"
[[ "$STORAGE" != *[[:space:]]* && -n "$STORAGE" ]] || err "--storage must not contain spaces"
[[ "$BRIDGE" != *[[:space:]]* && -n "$BRIDGE" ]] || err "--bridge must not contain spaces"

EXTRA_PACKAGES=$(normalize_packages "$EXTRA_PACKAGES")
if [[ -n "$EXTRA_PACKAGES" && ! "$EXTRA_PACKAGES" =~ ^[A-Za-z0-9.+_-]+(,[A-Za-z0-9.+_-]+)*$ ]]; then
  err "--extra-packages must be a comma- or space-separated package list"
fi

need qm; need pct; need pvesh; need pvesm

NAME="ntq-${CUSTOMER}-${ROLE}${INDEX}"
[[ -n "$SITE" ]] && NAME="${NAME}-${SITE}"

SSH_KEY_FILE=$(mktemp "/tmp/${NAME}.pub.XXXXXX")

curl -fsSL "$SSH_KEY_URL" -o "$SSH_KEY_FILE"

[[ -r "$SSH_KEY_FILE" ]] || err "SSH pubkey not readable"

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

# Install libguestfs-tools and dhcpcd-base if not present
if ! command -v virt-customize &>/dev/null || ! command -v dhcpcd &>/dev/null; then
  need apt-get
  echo "Installing image customization dependencies..."
  apt-get update >/dev/null 2>&1
  if ! command -v virt-customize &>/dev/null; then
    apt-get install -y libguestfs-tools >/dev/null 2>&1
  fi
  if ! command -v dhcpcd &>/dev/null; then
    apt-get install -y dhcpcd-base >/dev/null 2>&1 || true
  fi
  echo "Installed image customization dependencies"
fi

# Customize the image
echo "Customizing Debian 13 cloud image..."
WORK_FILE=$(mktemp --tmpdir="${IMAGES_DIR}" "${NAME}.XXXXXX.qcow2")
cp "$IMG_PATH" "$WORK_FILE"

# Set hostname (though Cloud-Init will override, but good for consistency)
virt-customize -q -a "$WORK_FILE" --hostname "$NAME" >/dev/null 2>&1

# Prepare for unique machine-id on first boot
virt-customize -q -a "$WORK_FILE" --run-command "truncate -s 0 /etc/machine-id" >/dev/null 2>&1
virt-customize -q -a "$WORK_FILE" --run-command "rm -f /var/lib/dbus/machine-id" >/dev/null 2>&1

# Disable systemd-firstboot
virt-customize -q -a "$WORK_FILE" --run-command "systemctl disable systemd-firstboot.service 2>/dev/null; rm -f /etc/systemd/system/sysinit.target.wants/systemd-firstboot.service; ln -sf /dev/null /etc/systemd/system/systemd-firstboot.service" >/dev/null 2>&1 || true

# Pre-seed timezone and locale
virt-customize -q -a "$WORK_FILE" --run-command "echo 'Etc/UTC' > /etc/timezone && ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime" >/dev/null 2>&1 || true
virt-customize -q -a "$WORK_FILE" --run-command "touch /etc/locale.conf" >/dev/null 2>&1 || true
virt-customize -q -a "$WORK_FILE" --run-command "sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8" >/dev/null 2>&1 || true

# Update packages and install base packages
virt-customize -q -a "$WORK_FILE" --update >/dev/null 2>&1
BASE_PACKAGES="curl,gnupg,ca-certificates,htop,qemu-guest-agent"
if [[ -n "$EXTRA_PACKAGES" ]]; then
  BASE_PACKAGES="${BASE_PACKAGES},${EXTRA_PACKAGES}"
fi
virt-customize -q -a "$WORK_FILE" --install "$BASE_PACKAGES" >/dev/null 2>&1

# Install and configure Tailscale
if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
  virt-customize -q -a "$WORK_FILE" --run-command "curl -fsSL https://tailscale.com/install.sh | sh" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "systemctl enable tailscaled" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "install -d -m 700 /etc/ntq" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "cat > /etc/ntq/tailscale.env <<'EOF'
TAILSCALE_AUTHKEY='$TAILSCALE_AUTHKEY'
TAILSCALE_HOSTNAME='$NAME'
EOF
chmod 600 /etc/ntq/tailscale.env" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "cat > /usr/local/bin/tailscale-up.sh <<'EOF'
#!/bin/bash
set -euo pipefail

source /etc/ntq/tailscale.env
tailscale up --authkey "\$TAILSCALE_AUTHKEY" --hostname "\$TAILSCALE_HOSTNAME" --login-server https://atlas.neoteq.be
rm -f /etc/ntq/tailscale.env
systemctl disable tailscale-up.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/tailscale-up.service /usr/local/bin/tailscale-up.sh
EOF" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "chmod +x /usr/local/bin/tailscale-up.sh" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "cat > /etc/systemd/system/tailscale-up.service <<'EOF'
[Unit]
Description=Tailscale Up
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tailscale-up.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "systemctl enable tailscale-up" >/dev/null 2>&1
fi

# Enable QEMU Guest Agent
virt-customize -q -a "$WORK_FILE" --run-command "systemctl enable qemu-guest-agent" >/dev/null 2>&1 || true

# SSH hardening
virt-customize -q -a "$WORK_FILE" --run-command "sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config" >/dev/null 2>&1

echo "Image customization completed."

qm create "$VMID" --name "$NAME" --memory "$RAM" --cores "$CPU" --net0 "virtio,bridge=${BRIDGE}"
qm set "$VMID" --scsihw virtio-scsi-pci

# Import
IMPORT_LOG=$(mktemp "/tmp/import.${VMID}.XXXXXX.log")
qm importdisk "$VMID" "$WORK_FILE" "$STORAGE" --format qcow2 >"$IMPORT_LOG" 2>&1

# Vol-ID robust ermitteln (erstes Image-Volume dieser VM auf dem Storage)
volid=$(pvesm list "$STORAGE" --vmid "$VMID" --content images | awk 'NR==2{print $1}')
if [[ -z "$volid" ]]; then
  echo "Import-Log:"
  cat "$IMPORT_LOG" >&2
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

echo "Starting VM $VMID ($NAME) with regenerated Cloud-Init..."
qm start "$VMID"
echo "Done. VM $NAME (ID $VMID) is booting with cloud-init."
