#!/bin/bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[ "$EUID" -ne 0 ] && echo -e "${RED}[✖] Run this script as root${NC}" && exit 1


install_panel() {
    # ------------------- Colors -------------------
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
    docker exec "$NAME" sh -c "
apt update -y &&
DEBIAN_FRONTEND=noninteractive apt install -y openssh-server sudo curl wget git &&
mkdir -p /run/sshd &&
echo 'root:root' | chpasswd &&
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config &&
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
/usr/sbin/sshd
"

clear
read -rp "Admin Email [admin@gmail.com]: " EMAIL
    read -rp "Admin Username [admin]: " USERNAME
    read -rp "First Name [Admin]: " FIRSTNAME
    read -rp "Last Name [Hosting]: " LASTNAME
    read -rsp "Admin Password [admin@123]: " PASSWORD
    echo
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

apt update && apt install -y curl apt-transport-https ca-certificates gnupg unzip git tar sudo lsb-release

OS=$(lsb_release -is | tr '[:upper:]' '[:lower:]')

if [[ "$OS" == "ubuntu" ]]; then
    echo "✅ Detected Ubuntu. Adding PPA for PHP..."
    apt install -y software-properties-common
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
elif [[ "$OS" == "debian" ]]; then
    echo "✅ Detected Debian. Skipping PPA and adding PHP repo manually..."
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/sury-php.list
fi

curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list

apt update

apt install -y php8.3 php8.3-{cli,fpm,common,mysql,mbstring,bcmath,xml,zip,curl,gd,tokenizer,ctype,simplexml,dom} mariadb-server nginx redis-server

curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer

mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

DB_NAME=panel
DB_USER=pterodactyl
DB_PASS=yourPassword
mariadb -e "CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "CREATE DATABASE ${DB_NAME};"
mariadb -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;"
mariadb -e "FLUSH PRIVILEGES;"

if [ ! -f ".env.example" ]; then
    curl -Lo .env.example https://raw.githubusercontent.com/pterodactyl/panel/develop/.env.example
fi
cp .env.example .env
sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|g" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|g" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g" .env
if ! grep -q "^APP_ENVIRONMENT_ONLY=" .env; then
    echo "APP_ENVIRONMENT_ONLY=false" >> .env
fi

echo "✅ Installing PHP dependencies..."
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

echo "✅ Generating application key..."
php artisan key:generate --force

php artisan migrate --seed --force

chown -R www-data:www-data /var/www/pterodactyl/*
apt install -y cron
systemctl enable --now cron
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

mkdir -p /etc/certs/panel
cd /etc/certs/panel
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" -keyout privkey.pem -out fullchain.pem

tee /etc/nginx/sites-available/pterodactyl.conf > /dev/null << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate /etc/certs/panel/fullchain.pem;
    ssl_certificate_key /etc/certs/panel/privkey.pem;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf || true
nginx -t && systemctl restart nginx

tee /etc/systemd/system/pteroq.service > /dev/null << 'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now redis-server
systemctl enable --now pteroq.service
clear

cd /var/www/pterodactyl
printf 'yes\n${EMAIL}\n${USERNAME}\n${FIRSTNAME}\n${LASTNAME}\n${PASSWORD}\n' | php artisan p:user:make 

sed -i '/^APP_ENVIRONMENT_ONLY=/d' .env
echo "APP_ENVIRONMENT_ONLY=false" >> .env

echo -e "\n\e[1;32m✔ Pterodactyl Panel Setup Complete!\e[0m"
echo -ne "\e[1;34mFinalizing installation"
for i in {1..5}; do
    echo -n "."
    sleep 0.5
done
echo -e "\n"
echo -e "successful Pterodactyl Panel Installation by KS Warrior code"
echo -e "\e[1;32m Create Admin: \e[1;37mphp artisan p:user:make\e[0m"
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
    install_panel
    ;;
  2)
    echo -e "${GREEN}Installing Pterodactyl Wings...${NC}"
    install_wings && config_file
    ;;
  3)
    echo -e "${GREEN}Installing Panel and Wings...${NC}"
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
