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
    docker exec "$NAME" sh -c "
    
clear
read -p "Enter your domain (e.g., panel.example.com): " DOMAIN


# --- Dependencies ---
apt update && apt install -y curl apt-transport-https ca-certificates gnupg unzip git tar sudo lsb-release

# Detect OS
OS=$(lsb_release -is | tr '[:upper:]' '[:lower:]')

if [[ "$OS" == "ubuntu" ]]; then
    echo "✅ Detected Ubuntu. Adding PPA for PHP..."
    apt install -y software-properties-common
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
elif [[ "$OS" == "debian" ]]; then
    echo "✅ Detected Debian. Skipping PPA and adding PHP repo manually..."
    # Add SURY PHP repo for Debian
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/sury-php.list
fi

# Add Redis GPG key and repo
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list

apt update

# --- Install PHP + extensions ---
apt install -y php8.3 php8.3-{cli,fpm,common,mysql,mbstring,bcmath,xml,zip,curl,gd,tokenizer,ctype,simplexml,dom} mariadb-server nginx redis-server

# --- Install Composer ---
curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer

# --- Download Pterodactyl Panel ---
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# --- MariaDB Setup ---
DB_NAME=panel
DB_USER=pterodactyl
DB_PASS=yourPassword
mariadb -e "CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "CREATE DATABASE ${DB_NAME};"
mariadb -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;"
mariadb -e "FLUSH PRIVILEGES;"

# --- .env Setup ---
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

# --- Install PHP dependencies ---
echo "✅ Installing PHP dependencies..."
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# --- Generate Application Key ---
echo "✅ Generating application key..."
php artisan key:generate --force

# --- Run Migrations ---
php artisan migrate --seed --force

# --- Permissions ---
chown -R www-data:www-data /var/www/pterodactyl/*
apt install -y cron
systemctl enable --now cron
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -
# --- Nginx Setup ---
mkdir -p /etc/certs/panel
cd /etc/certs/panel
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
-subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
-keyout privkey.pem -out fullchain.pem

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

# --- Queue Worker ---
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
# --- Admin User ---
cd /var/www/pterodactyl
php artisan p:user:make 

sed -i '/^APP_ENVIRONMENT_ONLY=/d' .env
echo "APP_ENVIRONMENT_ONLY=false" >> .env
"
