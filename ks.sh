#!/bin/bash
set -e

############################################
# KS Warrior - Interactive LXC VM Creator
############################################

log() {
  echo -e "\n🔹 $1"
}

ask() {
  local prompt=$1
  local default=$2
  local var
  read -p "$prompt [$default]: " var
  echo "${var:-$default}"
}

check_install() {
  if ! command -v "$1" &>/dev/null; then
    echo "   ➜ Installing $1"
    apt install -y "$1"
  else
    echo "   ✔ $1 already installed"
  fi
}

log "KS Warrior VM configuration"

VM_NAME=$(ask "Enter VM name" "fastvm")
VM_OS=$(ask "Enter OS" "ubuntu")
VM_RELEASE=$(ask "Enter OS release" "jammy")
VM_ARCH=$(ask "Enter architecture" "amd64")

VM_ROOT="/var/lib/lxc/$VM_NAME"

echo -e "\n📌 Final Configuration"
echo "--------------------------------"
echo "VM Name    : $VM_NAME"
echo "OS         : $VM_OS"
echo "Release    : $VM_RELEASE"
echo "Arch       : $VM_ARCH"
echo "Root Path  : $VM_ROOT"
echo "--------------------------------"

sleep 2

log "Updating system"
apt update -y

log "Installing required packages"
check_install lxc
check_install lxc-utils
check_install uidmap
check_install curl
check_install wget
check_install sudo

log "Loading kernel modules (if available)"
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

if lxc-info -n "$VM_NAME" &>/dev/null; then
  log "VM '$VM_NAME' already exists"
else
  log "Creating LXC VM: $VM_NAME"
  lxc-create -n "$VM_NAME" -t download -- \
    -d "$VM_OS" -r "$VM_RELEASE" -a "$VM_ARCH"
fi

log "Applying VM configuration"
CONFIG_FILE="$VM_ROOT/config"

grep -q "lxc.apparmor.profile" "$CONFIG_FILE" || cat <<EOF >> "$CONFIG_FILE"
lxc.apparmor.profile = unconfined
lxc.cgroup.devices.allow = a
lxc.mount.auto = proc:rw sys:rw
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
EOF

log "Starting VM"
lxc-start -n "$VM_NAME" || true

sleep 5

log "Setting root password"
lxc-attach -n "$VM_NAME" -- bash -c "echo root:root | chpasswd"

log "Installing essentials inside VM"
lxc-attach -n "$VM_NAME" -- bash <<'EOF'
apt update -y
apt install -y openssh-server sudo curl wget git
if command -v systemctl &>/dev/null; then
  systemctl enable ssh
  systemctl start ssh
else
  service ssh start
fi
EOF

VM_IP=$(lxc-info -n "$VM_NAME" -iH || echo "N/A")

echo -e "\n✅ VM READY – KS Warrior"
echo "--------------------------------------"
echo "📦 VM Name : $VM_NAME"
echo "🌐 VM IP   : $VM_IP"
echo "🔑 SSH     : ssh root@$VM_IP"
echo "🔐 Password: root"
echo "➡ Enter VM: lxc-attach -n $VM_NAME"
echo "--------------------------------------"
