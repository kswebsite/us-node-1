#!/bin/bash
set -e

ask() {
    local prompt="$1"
    local default="$2"
    local input
    read -p "$prompt [$default]: " input
    echo "${input:-$default}"
}

log() {
    echo -e "\n🔹 $1"
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        log "Docker is not installed. Installing Docker..."
        curl -fsSL https://get.docker.com | bash
        log "Docker installed successfully!"
    else
        log "Docker already installed."
    fi

    if ! command -v docker-compose &>/dev/null; then
        log "Docker Compose is not installed. Installing Docker Compose..."
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
        sudo curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        log "Docker Compose installed successfully!"
    else
        log "Docker Compose already installed."
    fi
}

log "KS Warrior - Docker Compose VM Creator"

check_docker

NAME=$(ask "Enter container name" "fastvm")
IMAGE=$(ask "Enter Docker image" "ubuntu:22.04")
RAM=$(ask "Enter memory limit in GB (optional, leave blank for no limit)" "2")
CPU=$(ask "Enter number of CPUs (optional, leave blank for default)" "2")
PORT=$(ask "Enter port to expose (optional, leave blank for none)" "22")

if [ -f docker-compose.yml ]; then
    log "Removing existing docker-compose setup..."
    docker-compose down
    rm -f docker-compose.yml
fi

log "Creating docker-compose.yml..."

cat <<EOF > docker-compose.yml
version: "3.9"

services:
  $NAME:
    image: $IMAGE
    container_name: $NAME
    hostname: $NAME
    privileged: true
    stdin_open: true
    tty: true
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: ${RAM}g
          cpus: "$CPU"
    ports:
      - "$PORT:22"
EOF

log "Starting container with Docker Compose..."
docker-compose up -d
