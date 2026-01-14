#!/bin/bash
set -e

#########################################
# KS Warrior - Lightweight Docker VM Setup
# Works on GitHub Codespaces / VPS
#########################################

# ------------------- Functions -------------------

# Ask function with default
ask() {
  local prompt="$1"
  local default="$2"
  local input
  read -p "$prompt [$default]: " input
  echo "${input:-$default}"
}

# Log function
log() {
  echo -e "\n🔹 $1"
}

# Check if Docker is installed
check_docker() {
  if ! command -v docker &>/dev/null; then
    log "Docker is not installed. Installing Docker..."
    curl -fsSL https://get.docker.com | bash
    log "Docker installed successfully!"
  else
    log "Docker already installed."
  fi
}

# ------------------- Main Script -------------------

log "KS Warrior - Docker VM Creator"

# Ask for configuration
NAME=$(ask "Enter container name" "fastvm")
IMAGE=$(ask "Enter Docker image" "ubuntu:22.04")
RAM=$(ask "Enter memory limit in GB (optional, leave blank for no limit)" "")
CPU=$(ask "Enter number of CPUs (optional, leave blank for default)" "")

# Remove existing container if exists
docker rm -f "$NAME" 2>/dev/null || true

# Build docker run command dynamically
DOCKER_CMD="docker run -dit --name $NAME --hostname $NAME --privileged"

[ -n "$RAM" ] && DOCKER_CMD+=" --memory=${RAM}g"
[ -n "$CPU" ] && DOCKER_CMD+=" --cpus=$CPU"

DOCKER_CMD+=" $IMAGE bash"

log "Creating Docker container..."
eval "$DOCKER_CMD"

log "Installing SSH and essential packages inside container..."
docker exec "$NAME" sh -c "
apt update -y &&
DEBIAN_FRONTEND=noninteractive apt install -y openssh-server sudo curl wget git &&
mkdir -p /run/sshd &&
echo 'root:root' | chpasswd &&
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config &&
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
/usr/sbin/sshd
"

log "✅ Container '$NAME' is ready!"
log "You can SSH into it with: docker exec -it $NAME bash"
