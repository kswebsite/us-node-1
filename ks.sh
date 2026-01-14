#!/bin/bash
set -e

install_panel() {
    GREEN="\e[32m"
    RED="\e[31m"
    YELLOW="\e[33m"
    NC="\e[0m"

    ok()   { echo -e "${GREEN}[✔] $1${NC}"; }
    fail() { echo -e "${RED}[✖] $1${NC}"; exit 1; }
    info() { echo -e "${YELLOW}[… ] $1${NC}"; }
    log()  { echo -e "\n🔹 $1"; }

    ask() {
        local prompt="$1"
        local default="$2"
        local input
        read -p "$prompt [$default]: " input
        echo "${input:-$default}"
    }

    [ "$EUID" -ne 0 ] && fail "Run as root"

    info "Checking Docker..."
    if ! command -v docker &>/dev/null; then
        info "Installing Docker..."
        curl -fsSL https://get.docker.com | bash || fail "Docker install failed"
        ok "Docker installed"
    else
        ok "Docker already installed"
    fi

    info "Checking Docker Compose..."
    if ! docker compose version &>/dev/null; then
        info "Installing Docker Compose..."
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
        curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || fail "Docker Compose download failed"
        chmod +x /usr/local/bin/docker-compose
        ok "Docker Compose installed"
    else
        ok "Docker Compose already installed"
    fi

    NAME=ks-ptero-panel
    IMAGE=$(ask "Enter Docker image" "ubuntu:22.04")
    RAM=$(ask "Enter memory limit in GB" "2")
    PORT=$(ask "Enter port to access panel" "80")
    DOMAIN=$(ask "Enter your domain (example.com)" "panel.example.com")

    if [ -f docker-compose.yml ]; then
        log "Removing existing Docker setup..."
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
    ports:
      - "$PORT:80"
EOF

    log "Starting container..."
    docker-compose up -d || fail "Failed to start container"

    log "Installing SSH & essential packages..."
    docker exec "$NAME" sh -c "
apt update -y &&
DEBIAN_FRONTEND=noninteractive apt install -y openssh-server sudo curl wget git &&
mkdir -p /run/sshd &&
echo 'root:root' | chpasswd &&
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config &&
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
/usr/sbin/sshd
"

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
    [ -z "$DB_PASSWORD" ] && DB_PASSWORD=$(openssl rand -base64 16) && echo "Generated DB_PASSWORD: $DB_PASSWORD"
    read -rsp "Database Root Password [generate random]: " MYSQL_ROOT_PASSWORD
    echo
    [ -z "$MYSQL_ROOT_PASSWORD" ] && MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16) && echo "Generated MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD"

    EMAIL="${EMAIL:-admin@gmail.com}"
    USERNAME="${USERNAME:-admin}"
    FIRSTNAME="${FIRSTNAME:-Admin}"
    LASTNAME="${LASTNAME:-Hosting}"
    PASSWORD="${PASSWORD:-admin@123}"
    TIMEZONE="${TIMEZONE:-Asia/Kolkata}"

    apt update && apt install -y curl apt-transport-https ca-certificates gnupg unzip git tar sudo lsb-release software-properties-common

    OS=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
    if [[ "$OS" == "ubuntu" ]]; then
        add-apt-repository -y ppa:ondrej/php
    else
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg
        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/sury-php.list
    fi

    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list

    apt update
    apt install -y php8.3 php8.3-{cli,fpm,common,mysql,mbstring,bcmath,xml,zip,curl,gd,tokenizer,ctype,simplexml,dom} mariadb-server nginx redis-server
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzvf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/

    DB_NAME=panel
    DB_USER=pterodactyl
    DB_PASS="$DB_PASSWORD"
    mariadb -e "CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
    mariadb -e "CREATE DATABASE ${DB_NAME};"
    mariadb -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;"
    mariadb -e "FLUSH PRIVILEGES;"

    [ ! -f ".env.example" ] && curl -Lo .env.example https://raw.githubusercontent.com/pterodactyl/panel/develop/.env.example
    cp .env.example .env
    sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env
    sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|g" .env
    sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|g" .env
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g" .env
    echo "APP_ENVIRONMENT_ONLY=false" >> .env

    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
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
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE \"upload_max_filesize=100M \n post_max_size=100M\";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/ || true
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

cd /var/www/pterodactyl
printf 'yes\n%s\n%s\n%s\n%s\n%s\n' "$EMAIL" "$USERNAME" "$FIRSTNAME" "$LASTNAME" "$PASSWORD" | php artisan p:user:make

echo -e "\e[1;32m✔ Pterodactyl Panel Setup Complete!\e[0m"
echo "Access panel at: https://${DOMAIN}"
}

install_panel
