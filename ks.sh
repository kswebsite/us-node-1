#!/bin/bash
set -e

log() { echo -e "\n🔹 $1"; }

ask() {
  read -p "$1 [$2]: " v
  echo "${v:-$2}"
}

log "KS Warrior VM configuration"

VM_NAME=$(ask "Enter VM name" "fastvm")
VM_OS=$(ask "Enter OS" "ubuntu")
VM_RELEASE=$(ask "Enter OS release" "jammy")
VM_ARCH=$(ask "Enter architecture" "amd64")

VM_ROOT="/var/lib/lxc/$VM_NAME"

log "Updating system"
apt update -y

log "Installing LXC"
apt install -y lxc lxc-utils uidmap curl wget sudo

log "Creating VM"
if ! lxc-info -n "$VM_NAME" &>/dev/null; then
  lxc-create -n "$VM_NAME" -t download -- \
    -d "$VM_OS" -r "$VM_RELEASE" -a "$VM_ARCH"
fi

log "Starting VM (daemon mode)"
lxc-start -n "$VM_NAME" -d

log "Waiting for VM to boot"
for i in {1..15}; do
  STATE=$(lxc-info -n "$VM_NAME" -sH 2>/dev/null || true)
  [[ "$STATE" == "RUNNING" ]] && break
  sleep 1
done

log "Setting root password"
lxc-attach -n "$VM_NAME" -- sh -c "echo root:root | chpasswd"

log "Installing essentials (NO systemctl/service)"
lxc-attach -n "$VM_NAME" -- sh <<'EOF'
apt update -y
apt install -y openssh-server sudo curl wget git

mkdir -p /run/sshd
/usr/sbin/sshd
EOF

VM_IP=$(lxc-info -n "$VM_NAME" -iH || echo "N/A")

echo -e "\n✅ VM READY"
echo "VM Name : $VM_NAME"
echo "VM IP   : $VM_IP"
echo "SSH     : ssh root@$VM_IP"
echo "PASS    : root"
