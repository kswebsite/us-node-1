#!/bin/bash

GREEN="\e[32m"
    RED="\e[31m"
    YELLOW="\e[33m"
    NC="\e[0m"

    # ------------------- Helper Functions -------------------
    ok()   { echo -e "${GREEN}[✔] $1${NC}"; }
    fail() { echo -e "${RED}[✖] $1${NC}"; exit 1; }
    info() { echo -e "${YELLOW}[… ] $1${NC}"; }

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

    # ------------------- Root Check -------------------
    [ "$EUID" -ne 0 ] && fail "Run as root"

    # ------------------- Docker Check / Install -------------------
    info "Checking Docker..."
    if ! command -v docker &>/dev/null; then
        info "Docker not found. Installing..."
        curl -fsSL https://get.docker.com | bash || fail "Docker install failed"
        ok "Docker installed"
    else
        ok "Docker already installed"
    fi

    info "Checking Docker Compose..."
    if ! docker compose version &>/dev/null; then
        info "Docker Compose not found. Installing..."
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
            | grep -Po '"tag_name": "\K.*?(?=")')
        curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose || fail "Docker Compose download failed"
        chmod +x /usr/local/bin/docker-compose
        ok "Docker Compose installed"
    else
        ok "Docker Compose already installed"
    fi

    # ------------------- Ask User for VM Config -------------------
    NAME=ks-ptero-panel
    IMAGE=$(ask "Enter Docker image" "ubuntu:22.04")
    RAM=$(ask "Enter memory limit in GB for panel" "2")
    PORT=$(ask "Enter port to access panel" "80")

    # ------------------- Remove Existing Container if Exists -------------------
    if [ -f docker-compose.yml ]; then
        log "Removing existing docker-compose setup..."
        docker-compose down
        rm -f docker-compose.yml
    fi

    # ------------------- Create docker-compose.yml -------------------
    log "Creating docker-compose.yml..."
    cat <<EOF > docker-compose.yml
version: "3.9"

services:
  $NAME:
    image: ubuntu:22.04
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
    ports:
      - "$PORT:80"
EOF

    # ------------------- Start Container -------------------
    log "Starting container with Docker Compose..."
    docker-compose up -d || fail "Failed to start container"

    # ------------------- Install SSH & Essential Packages -------------------
    log "Installing SSH and essential packages inside container..."
    docker exec "$NAME" sh
