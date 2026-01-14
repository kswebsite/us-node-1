#!/bin/bash
set -e
clear

# --- Input ---
read -p "Enter your domain (e.g., panel.example.com): " DOMAIN
read -p "Email [admin@gmail.com]: " EMAIL
EMAIL=${EMAIL:-admin@gmail.com}

read -p "Username [admin]: " USERNAME
USERNAME=${USERNAME:-admin}

read -p "First name [Admin]: " FIRSTNAME
FIRSTNAME=${FIRSTNAME:-Admin}

read -p "Last name [Hosting]: " LASTNAME
LASTNAME=${LASTNAME:-Hosting}

read -s -p "Password [admin@123]: " PASSWORD
echo
PASSWORD=${PASSWORD:-admin@123}

# --- Update & dependencies ---
apt update
apt install -y curl gnupg unzip git tar lsb-release supervisor openssl mariadb-client php-cli php-fpm php-{cli,fpm,common,mysql,mbstring,bcmath,xml,zip,curl,gd,tokenizer,ctype,simplexml,dom} redis-server

# --- Composer ---
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# --- Setup Panel ---
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# --- .env ---
cp .env.example .env
DB_NAME=panel
DB_USER=pterodactyl
DB_PASS=$(openssl rand -base64 16)

sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|g" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|g" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g" .env
echo "APP_ENVIRONMENT_ONLY=false" >> .env

# --- PHP deps & artisan setup ---
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan migrate --seed --force

# --- Permissions ---
chown -R www-data:www-data /var/www/pterodactyl/*

# --- Supervisor for Queue Worker ---
mkdir -p /etc/supervisor/conf.d
cat >/etc/supervisor/conf.d/pteroq.conf <<EOF
[program:pteroq]
command=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
user=www-data
autostart=true
autorestart=true
stderr_logfile=/var/log/pteroq.err.log
stdout_logfile=/var/log/pteroq.out.log
EOF

# --- Nginx Setup ---
mkdir -p /etc/certs/panel
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout /etc/certs/panel/privkey.pem -out /etc/certs/panel/fullchain.pem

cat >/etc/nginx/conf.d/pterodactyl.conf <<EOF
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

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# --- Create Admin User ---
cd /var/www/pterodactyl
php artisan p:user:make --email="$EMAIL" --username="$USERNAME" --name="$FIRSTNAME $LASTNAME" --password="$PASSWORD" --admin

# --- Start Services in Docker ---
echo "✅ Starting services..."
service php8.3-fpm start
service nginx start
service redis-server start
supervisord -n -c /etc/supervisor/supervisord.conf

echo "✅ Pterodactyl Panel setup complete!"
echo "Visit https://${DOMAIN}"#!/bin/bash
set -e
clear

# --- Input ---
read -p "Enter your domain (e.g., panel.example.com): " DOMAIN
read -p "Email [admin@gmail.com]: " EMAIL
EMAIL=${EMAIL:-admin@gmail.com}

read -p "Username [admin]: " USERNAME
USERNAME=${USERNAME:-admin}

read -p "First name [Admin]: " FIRSTNAME
FIRSTNAME=${FIRSTNAME:-Admin}

read -p "Last name [Hosting]: " LASTNAME
LASTNAME=${LASTNAME:-Hosting}

read -s -p "Password [admin@123]: " PASSWORD
echo
PASSWORD=${PASSWORD:-admin@123}

# --- Update & dependencies ---
apt update
apt install -y curl gnupg unzip git tar lsb-release supervisor openssl mariadb-client php-cli php-fpm php-{cli,fpm,common,mysql,mbstring,bcmath,xml,zip,curl,gd,tokenizer,ctype,simplexml,dom} redis-server

# --- Composer ---
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# --- Setup Panel ---
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# --- .env ---
cp .env.example .env
DB_NAME=panel
DB_USER=pterodactyl
DB_PASS=$(openssl rand -base64 16)

sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|g" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|g" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g" .env
echo "APP_ENVIRONMENT_ONLY=false" >> .env

# --- PHP deps & artisan setup ---
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan migrate --seed --force

# --- Permissions ---
chown -R www-data:www-data /var/www/pterodactyl/*

# --- Supervisor for Queue Worker ---
mkdir -p /etc/supervisor/conf.d
cat >/etc/supervisor/conf.d/pteroq.conf <<EOF
[program:pteroq]
command=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
user=www-data
autostart=true
autorestart=true
stderr_logfile=/var/log/pteroq.err.log
stdout_logfile=/var/log/pteroq.out.log
EOF

# --- Nginx Setup ---
mkdir -p /etc/certs/panel
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout /etc/certs/panel/privkey.pem -out /etc/certs/panel/fullchain.pem

cat >/etc/nginx/conf.d/pterodactyl.conf <<EOF
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

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# --- Create Admin User ---
cd /var/www/pterodactyl
php artisan p:user:make --email="$EMAIL" --username="$USERNAME" --name="$FIRSTNAME $LASTNAME" --password="$PASSWORD" --admin

# --- Start Services in Docker ---
echo "✅ Starting services..."
service php8.3-fpm start
service nginx start
service redis-server start
supervisord -n -c /etc/supervisor/supervisord.conf

echo "✅ Pterodactyl Panel setup complete!"
echo "Visit https://${DOMAIN}"
