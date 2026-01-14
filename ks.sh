#!/bin/bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[ "$EUID" -ne 0 ] && echo -e "${RED}[✖] Run this script as root${NC}" && exit 1



install_docker() {

    ok()   { echo -e "${GREEN}[✔] $1${NC}"; }
    fail() { echo -e "${RED}[✖] $1${NC}"; exit 1; }
    info() { echo -e "${YELLOW}[… ] $1${NC}"; }

    # Root check
    [ "$EUID" -ne 0 ] && fail "Run as root"

    info "Checking Docker"

    if command -v docker >/dev/null 2>&1; then
        ok "Docker already installed"
    else
        info "Updating APT"
        apt update -y >/dev/null || fail "APT update failed"
        ok "APT updated"

        info "Installing dependencies"
        apt install -y ca-certificates curl gnupg lsb-release >/dev/null \
            || fail "Dependency install failed"
        ok "Dependencies installed"

        info "Preparing keyrings"
        install -m 0755 -d /etc/apt/keyrings || fail "Keyring creation failed"

        info "Adding Docker GPG key"
        curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
            || fail "GPG key failed"

        chmod a+r /etc/apt/keyrings/docker.gpg
        ok "Docker GPG key added"

        info "Adding Docker repository"
        echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
        || fail "Repo add failed"

        ok "Docker repository added"

        info "Updating Docker repo"
        apt update -y >/dev/null || fail "Repo update failed"
        ok "Docker repo updated"

        info "Installing Docker"
        apt install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin \
            >/dev/null || fail "Docker install failed"

        ok "Docker installed"
    fi

    info "Checking Docker service"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || fail "Docker service failed"
        ok "Docker service running"
    else
        ok "Systemd not available (skipped service check)"
    fi

    info "Checking Docker Compose v2"
    docker compose version >/dev/null 2>&1 \
        && ok "Docker Compose v2 available" \
        || fail "Docker Compose missing"

    ok "Docker setup complete"
}



install_panel() {
    clear
    read -rp "Admin Email [admin@gmail.com]: " EMAIL
    read -rp "Admin Username [admin]: " USERNAME
    read -rp "First Name [Admin]: " FIRSTNAME
    read -rp "Last Name [Hosting]: " LASTNAME
    read -rsp "Admin Password [admin@123]: " PASSWORD
    read -rp "Timezone [Asia/Kolkata]: " TIMEZONE
    read -rp "Enter port [80]: " PORT
    APP_URL="http://127.0.0.1:${PORT}"
    read -rsp "Database Password [generate random]: " DB_PASSWORD
    echo
    if [ -z "$DB_PASSWORD" ]; then
        DB_PASSWORD=$(openssl rand -base64 16)
        echo "Generated DB_PASSWORD: $DB_PASSWORD"
    fi

    read -rsp "Database Root Password [generate random]: " MYSQL_ROOT_PASSWORD
    echo
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16)
        echo "Generated MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD"
    fi


EMAIL="${EMAIL:-admin@gmail.com}"
USERNAME="${USERNAME:-admin}"
FIRSTNAME="${FIRSTNAME:-Admin}"
LASTNAME="${LASTNAME:-Hosting}"
PASSWORD="${PASSWORD:-admin@123}"
TIMEZONE="${TIMEZONE:-Asia/Kolkata}"
PORT="${PORT:-80}"

echo Updating system
apt update -y
apt upgrade -y

echo Updating system
apt update -y
apt upgrade -y

echo Installing base dependencies
apt install -y ca-certificates apt-transport-https software-properties-common lsb-release \
curl wget tar unzip git gnupg2

echo Adding PHP repository
add-apt-repository -y ppa:ondrej/php

echo Updating package list
apt update -y

echo Installing PHP 8.3 and extensions
apt install -y \
php8.3 php8.3-cli php8.3-fpm \
php8.3-openssl php8.3-gd php8.3-mysql php8.3-pdo \
php8.3-mbstring php8.3-tokenizer php8.3-bcmath \
php8.3-xml php8.3-dom php8.3-curl php8.3-zip

echo Installing database and cache
apt install -y mariadb-server redis-server

echo Installing web server
apt install -y nginx

echo Installing Composer v2
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

echo Starting Redis
redis-server --daemonize yes

echo Starting MariaDB
mysqld_safe --datadir=/var/lib/mysql &

sleep 5

echo Starting PHP-FPM
php-fpm8.3 -D

echo Starting NGINX
nginx

echo Verifying installations
php -v
composer --version
mysql --version
redis-server --version
nginx -v

echo Installation completed successfully

echo Creating database
DB_PASS=$(openssl rand -base64 16)
mysql <<EOF
CREATE DATABASE IF NOT EXISTS panel;
CREATE USER IF NOT EXISTS 'pterodactyl'@'localhost' IDENTIFIED BY '$DB_PASS';
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

echo Downloading panel
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl || exit
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 775 storage bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache

echo Installing PHP dependencies
export COMPOSER_ALLOW_SUPERUSER=1
php -d memory_limit=-1 /usr/bin/composer install --no-dev --optimize-autoloader

echo Environment setup
cp .env.example .env
chown www-data:www-data .env

php artisan key:generate --force

php artisan p:environment:setup \
--author=admin@example.com \
--url=http://localhost \
--timezone=UTC \
--cache=redis \
--session=redis \
--queue=redis

php artisan p:environment:database \
--host=127.0.0.1 \
--port=3306 \
--database=panel \
--username=pterodactyl \
--password=$DB_PASS

php artisan migrate --seed --force

printf 'yes\n${EMAIL}\n${USERNAME}\n${FIRSTNAME}\n${LASTNAME}\n${PASSWORD}\n' | php artisan p:user:make

echo Setting permissions
chown -R www-data:www-data /var/www/pterodactyl

echo Nginx configuration
cat > /etc/nginx/conf.d/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name _;
    root /var/www/pterodactyl/public;
    index index.php;

    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_index index.php;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

nginx -s reload

echo Starting queue worker
nohup bash -c "while true; do php /var/www/pterodactyl/artisan queue:work --sleep=3 --tries=3 --timeout=90; sleep 5; done" >/dev/null 2>&1 &

echo Setting cron
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

echo Pterodactyl Panel Installed Successfully
echo Access panel on port 80
echo Database password: $DB_PASS
    
}


install_wings() {
    clear

    read -p "Enter your server timezone [Asia/Kolkata]: " TIMEZONE
    TIMEZONE=${TIMEZONE:-Asia/Kolkata}

    WINGS_DIR="$HOME/ks/pterodactyl/wings"
    mkdir -p "$WINGS_DIR"
    cd "$WINGS_DIR" || exit 1

    cat > ks-pterodactyl-wings.yml <<EOF
version: '3.8'

services:
  ks-pterodactyl-wings-vm:
    image: ghcr.io/pterodactyl/wings:latest
    container_name: ks-pterodactyl-wings-vm
    restart: unless-stopped
    environment:
      TZ: "${TIMEZONE}"
    ports:
      - "8080:8080"
      - "2022:2022"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./ks-wings-config.yml:/etc/pterodactyl/config.yml
      - /var/lib/pterodactyl:/var/lib/pterodactyl
      - /var/log/pterodactyl:/var/log/pterodactyl
    networks:
      - ptero-net
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  ptero-net:
    driver: bridge
EOF

    echo -e "${YELLOW}[•] Starting Pterodactyl Wings...${NC}"
    docker-compose -f ks-pterodactyl-wings.yml up -d

    echo
    echo -e "${GREEN}✔ Pterodactyl Wings installed successfully!${NC}"
    echo -e "${GREEN}Mode     : VM (Docker)${NC}"
    echo -e "${YELLOW}Logs     : docker logs -f ks-pterodactyl-wings-vm${NC}"
}



tunnel_setup() {
    read -p "Enter Port: " PORT
    read -p "Enter subdomain (wings name): " NAME

    if [[ -z "$PORT" || -z "$NAME" ]]; then
        echo -e "\033[0;31m[✖] Port or subdomain cannot be empty!${NC}"
        return 1
    fi

    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
        echo -e "\033[0;31m[✖] Invalid port number!${NC}"
        return 1
    fi

    if ! command -v it >/dev/null 2>&1; then
        echo -e "\033[1;33m[•] Installing Instatunnel...${NC}"
        curl -fsSL https://api.instatunnel.my/releases/install.sh | bash
    fi

    echo -e "\033[1;33m[•] Starting tunnel...${NC}"
    it --port "$PORT" --name "$NAME"
}

config_file() {
    YML_DIR="$HOME/ks/pterodactyl/wings"

    if [ ! -d "$YML_DIR" ]; then
        echo -e "\033[0;31m[✖] Wings folder not found!"
        echo -e "[!] Either you didn't install Pterodactyl Wings using my installer"
        echo -e "    or the installation is incomplete/corrupted.${NC}"
        return 1
    fi

    cd "$YML_DIR" || return 1

    echo -e "\033[1;33mEnter your Wings configuration:${NC}"
    echo -e "\033[1;33mType 'KS' on a new line and press ENTER to save.${NC}"

    CONFIG=""
    while IFS= read -r line; do
        [[ "$line" == "KS" ]] && break
        CONFIG+="$line"$'\n'
    done

    if [ -z "$CONFIG" ]; then
        echo -e "\033[0;31m[✖] No configuration provided. Exiting.${NC}"
        return 1
    fi

    cat > ks-wings-config.yml <<EOF
$CONFIG
EOF

    echo -e "\033[0;32m✔ Configuration saved successfully to $YML_DIR/ks-pterodactyl-wings.yml${NC}"
}

clear
echo -e "${YELLOW}"
echo "════════════════════════════════════"
echo "   KS Warrior • Pterodactyl Installer"
echo "════════════════════════════════════"
echo -e "${NC}"

echo "1) Install Panel"
echo "2) Install Wings"
echo "3) Install Panel + Wings"
echo "4) Free Tunnel (For connect wings to panel)"
echo "5) Add Wings Config"
echo
read -rp "Select an option [1-3]: " OPTION

case "$OPTION" in
  1)
    echo -e "${GREEN}Installing Pterodactyl Panel...${NC}"
    install_docker
    install_panel
    ;;
  2)
    echo -e "${GREEN}Installing Pterodactyl Wings...${NC}"
    install_docker
    install_wings && config_file
    ;;
  3)
    echo -e "${GREEN}Installing Panel and Wings...${NC}"
    install_docker
    install_panel && install_wings && config_file
    ;;
  4)
    echo -e "${GREEN}Installing Instatunnel...${NC}"
    tunnel_setup
    ;;
  5)
    echo -e "${GREEN}Wings Configuration Adding...${NC}"
    config_file
    ;;
  *)
    echo -e "${RED}Invalid option. Exiting.${NC}"
    exit 1
    ;;
esac

echo -e "${GREEN}✔ Installation process finished${NC}"
