#!/bin/bash
set -euo pipefail

# ── Colors ──────────────────────────────────────────────
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
NC="\e[0m"

ok()   { echo -e "${GREEN}[✔] $1${NC}" ; }
fail() { echo -e "${RED}[✖] $1${NC}" ; exit 1 ; }
info() { echo -e "${YELLOW}[i] $1${NC}" ; }

[[ $EUID -ne 0 ]] && fail "Run this script as root (sudo)"

clear
echo -e "${YELLOW}KS Warrior - Pterodactyl Panel (Docker Single-Container)${NC}\n"

# ── User config ───────────────────────────────────────
read -p "Domain / subdomain [panel.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-panel.example.com}

read -p "External port [80]: " HOST_PORT
HOST_PORT=${HOST_PORT:-80}

read -p "Container RAM limit in GB [2]: " RAM_GB
RAM_GB=${RAM_GB:-2}

read -rp "Admin email [admin@example.com]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}

read -rp "Admin username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -rsp "Admin password [random if empty]: " ADMIN_PASS
echo
if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
fi
echo -e " → Using password: ${YELLOW}${ADMIN_PASS}${NC}  (SAVE THIS!)"

read -rp "Timezone [Asia/Kolkata]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Asia/Kolkata}

# ── Docker & Compose install ─────────────────────────
if ! command -v docker >/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | bash || fail "Docker install failed"
fi

if ! command -v docker-compose >/dev/null; then
    info "Installing Docker Compose..."
    DC_VER=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
             | grep '"tag_name":' | cut -d'"' -f4)
    curl -L "https://github.com/docker/compose/releases/download/${DC_VER}/docker-compose-$(uname -s)-$(uname -m)" \
         -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# ── Docker Compose file ──────────────────────────────
cat > docker-compose.yml << EOF
version: "3.9"
services:
  panel:
    image: ubuntu:22.04
    container_name: ptero-panel
    hostname: panel
    privileged: true
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: ${RAM_GB}G
    ports:
      - "${HOST_PORT}:80"
    environment:
      - TZ=${TIMEZONE}
EOF

# ── Start container ───────────────────────────────────
info "Starting container..."
docker compose up -d || fail "Container start failed"

CONTAINER="ptero-panel"

# ── Install Pterodactyl inside container ─────────────
info "Installing Pterodactyl inside container (~5-10 min)..."

docker exec -i "$CONTAINER" bash << EOF
set -e
export DEBIAN_FRONTEND=noninteractive

apt update -y && apt upgrade -y
apt install -y software-properties-common curl apt-transport-https \
               ca-certificates gnupg lsb-release unzip git tar sudo cron wget openssl

# PHP 8.3
add-apt-repository -y ppa:ondrej/php || true
apt update -y
apt install -y php8.3 php8.3-{cli,fpm,mysql,mbstring,bcmath,xml,zip,curl,gd,intl,tokenizer,ctype,simplexml,dom}

# MariaDB + Redis + Nginx
apt install -y mariadb-server redis-server nginx

# Composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Pterodactyl Panel
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
rm panel.tar.gz
chmod -R 755 storage/* bootstrap/cache

# MariaDB setup
service mariadb start
DB_ROOT_PASS=\$(openssl rand -base64 16)
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '\$DB_ROOT_PASS'; FLUSH PRIVILEGES;"

DB_NAME=panel
DB_USER=pterodactyl
DB_PASS=\$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 18)

mysql -e "CREATE DATABASE \${DB_NAME};"
mysql -e "CREATE USER '\${DB_USER}'@'127.0.0.1' IDENTIFIED BY '\${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \${DB_NAME}.* TO '\${DB_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;"

echo "\$DB_PASS" > /tmp/dbpass.txt

# .env setup
curl -Lo .env.example https://raw.githubusercontent.com/pterodactyl/panel/develop/.env.example
cp .env.example .env

sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env
sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
sed -i "s|^DB_DATABASE=.*|DB_DATABASE=\${DB_NAME}|g" .env
sed -i "s|^DB_USERNAME=.*|DB_USERNAME=\${DB_USER}|g" .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=\${DB_PASS}|g" .env

echo 'APP_ENV=production' >> .env
echo 'APP_DEBUG=false' >> .env

composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan p:environment:setup --no-interaction || true
php artisan migrate --seed --force

chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 storage/* bootstrap/cache

# Cron
echo '* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1' | crontab -

# Self-signed SSL
mkdir -p /etc/certs/panel
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/C=XX/ST=XX/L=XX/O=XX/CN=${DOMAIN}" \
    -keyout /etc/certs/panel/privkey.pem -out /etc/certs/panel/fullchain.pem

# Nginx config
cat > /etc/nginx/sites-available/pterodactyl << 'NGX'
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

    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
    }

    location ~ /\.ht {
        deny all;
    }
}
NGX

ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && service nginx restart

# Queue worker
cat > /etc/systemd/system/pteroq.service << 'SRV'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5

[Install]
WantedBy=multi-user.target
SRV

systemctl daemon-reload
systemctl enable --now redis-server pteroq.service mariadb nginx cron php8.3-fpm

# Create admin user
printf 'yes\n${ADMIN_EMAIL}\n${ADMIN_USER}\nAdmin\nHosting\n${ADMIN_PASS}\n' | php artisan p:user:make

EOF

# ── Final output ─────────────────────────────────────────
clear
DB_PASS=$(docker exec "$CONTAINER" cat /tmp/dbpass.txt || echo "unknown")

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Pterodactyl Panel (Docker) Ready!        "
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

echo -e "🌐 Access:            ${YELLOW}http://${DOMAIN}  (or https if you fix cert)${NC}"
echo -e "   → from host:       ${YELLOW}http://localhost:${HOST_PORT}${NC}"
echo -e "👤 Admin:             ${YELLOW}${ADMIN_USER} / ${ADMIN_PASS}${NC}"
echo -e "🔑 DB:                ${YELLOW}pterodactyl / ${DB_PASS}${NC}\n"

echo -e "${YELLOW}Notes:${NC}"
echo " • Single-container setup (MariaDB + Redis + PHP + Nginx inside one)"
echo " • For production: use multi-container & real SSL (certbot)"
echo " • Enter container:  docker exec -it ptero-panel bash"
echo " • Logs:              docker logs ptero-panel"
echo " • Stop:              docker compose down"

ok "KS Warrior setup finished!"
