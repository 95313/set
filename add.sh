#!/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Check for MySQL password file
if [ ! -f ~/.pwdmysql ]; then
    echo "Error: MySQL password file ~/.pwdmysql not found"
    exit 1
fi

# Read MySQL root password
MYSQL_ROOT_PASSWORD=$(cat ~/.pwdmysql)
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
    echo "Error: MySQL password file is empty"
    exit 1
fi

# Function to detect PHP version
get_php_version() {
    php -v | head -n1 | cut -d" " -f2 | cut -d"." -f1,2
}

# Get PHP version
PHP_VERSION=$(get_php_version)
if [ -z "$PHP_VERSION" ]; then
    echo "Error: PHP is not installed or not found in PATH"
    exit 1
fi

# Verify PHP-FPM is installed
if [ ! -d "/etc/php/${PHP_VERSION}/fpm" ]; then
    echo "Error: PHP-FPM ${PHP_VERSION} is not installed"
    exit 1
fi

echo "Detected PHP version: ${PHP_VERSION}"

# Rest of your functions
generate_password() {
    tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[\]^_`{|}~' </dev/urandom | head -c 24
}

sanitize_domain() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]'
}

# Domain input with validation and confirmation
while true; do
    read -p "Enter domain name (e.g., example.com): " DOMAIN
    
    echo "You entered: $DOMAIN"
    read -p "Is this correct? (y/n): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        break
    fi
done

# Check if domain directory already exists
if [ -d "/var/www/${DOMAIN}" ]; then
    echo "Warning: Directory /var/www/${DOMAIN} already exists!"
    read -p "Do you want to continue and overwrite? (y/n): " overwrite
    if [[ ! $overwrite =~ ^[Yy]$ ]]; then
        echo "Setup aborted."
        exit 1
    fi
fi

# Check if nginx configuration already exists
if [ -f "/etc/nginx/sites-available/${DOMAIN}" ]; then
    echo "Warning: Nginx configuration for ${DOMAIN} already exists!"
    read -p "Do you want to continue and overwrite? (y/n): " overwrite_nginx
    if [[ ! $overwrite_nginx =~ ^[Yy]$ ]]; then
        echo "Setup aborted."
        exit 1
    fi
fi

 # Check if Certbot is installed
 if ! command -v certbot &> /dev/null; then
     echo "Certbot not found. Installing..."
     apt-get update
     apt-get install -y certbot python3-certbot-nginx
 fi

 echo "Installing SSL certificate for ${DOMAIN}"
 certbot certonly --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" --non-interactive --agree-tos -m "webmaster@${DOMAIN}" --expand
 
 if [ $? -ne 0 ]; then
     echo "SSL certificate installation failed. Continuing without SSL."
     INSTALL_SSL="n"
 fi

# Generate sanitized domain for database usage
SANITIZED_DOMAIN=$(sanitize_domain "$DOMAIN")

# Check if database already exists
DB_EXISTS=$(mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -Nse "SHOW DATABASES LIKE 'db_${SANITIZED_DOMAIN}'")
if [ "$DB_EXISTS" ]; then
    echo "Warning: Database db_${SANITIZED_DOMAIN} already exists!"
    read -p "Do you want to continue and overwrite? (y/n): " overwrite_db
    if [[ ! $overwrite_db =~ ^[Yy]$ ]]; then
        echo "Setup aborted."
        exit 1
    fi
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS db_${SANITIZED_DOMAIN}"
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "DROP USER IF EXISTS 'u_${SANITIZED_DOMAIN}'@'localhost'"
fi

# Generate database credentials
DB_NAME="db_${SANITIZED_DOMAIN}"
DB_USER="u_${SANITIZED_DOMAIN}"
DB_PASS=$(generate_password)

# Store credentials in a secure file
CREDS_FILE="/root/.wp_creds_${SANITIZED_DOMAIN}"
cat > "$CREDS_FILE" << EOF
Domain: $DOMAIN
Database Name: $DB_NAME
Database User: $DB_USER
Database Password: $DB_PASS
PHP Version: $PHP_VERSION
EOF
chmod 600 "$CREDS_FILE"

# Display setup summary
echo "=== Setup Summary ==="
echo "Domain: $DOMAIN"
echo "Web Root: /var/www/${DOMAIN}"
echo "Database Name: $DB_NAME"
echo "Database User: $DB_USER"
echo "PHP Version: $PHP_VERSION"
echo "Creds will be saved to: $CREDS_FILE"
echo "===================="
read -p "Proceed with installation? (y/n): " proceed
if [[ ! $proceed =~ ^[Yy]$ ]]; then
    echo "Setup aborted."
    rm "$CREDS_FILE"
    exit 1
fi

# Create web directory
WEBROOT="/var/www/${DOMAIN}"
mkdir -p "$WEBROOT"
chown -R www-data:www-data "$WEBROOT"

# Create PHP-FPM pool configuration
cat > "/etc/php/${PHP_VERSION}/fpm/pool.d/${DOMAIN}.conf" << EOF
[$DOMAIN]
user = www-data
group = www-data
listen = /run/php/php${PHP_VERSION}-fpm-${DOMAIN}.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF

# Create Nginx server block
cat > "/etc/nginx/sites-available/${DOMAIN}" << EOF
server {
   listen 80;
   listen 443 ssl http2;
   ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
   ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
   root /var/www/html/${DOMAIN};
   index index.php index.html index.htm;
   error_log /var/log/nginx/${DOMAIN}.error.log;
   server_name ${DOMAIN} www.${DOMAIN};
   location / {
      try_files \$uri \$uri/ /index.php?\$args;
   }
   if (\$http_user_agent ~* (BLEXBot|GrapeshotCrawler|MJ12bot|SemrushBot|AhrefsBot|DotBot) ) { return 301 http://127.0.0.1/; }
   location ~* /(?:uploads|files)/.*\.(asp|bat|cgi|htm|html|ico|js|jsp|md|php|pl|py|sh|shtml|swf|twig|txt|yaml|yml|zip|gz|tar|bzip2|7z)$ { deny all; }
   location ~ \.php$ {
       fastcgi_split_path_info ^(.+\.php)(/.+)$;
       fastcgi_param PHP_VALUE open_basedir="/tmp/:/usr/share/php/:/dev/urandom:/dev/shm:/var/lib/php/sessions/:\$document_root";
       fastcgi_pass unix:/run/php/${PHP_VERSION}-${DOMAIN}-fpm.sock;
       fastcgi_index index.php;
       fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
       include fastcgi_params;
   }
   location = /wp-login.php {
       limit_req zone=limit burst=1 nodelay;
       limit_req_status 429;
       fastcgi_pass unix:/run/php/php${PHP_VERSION}-${DOMAIN}-fpm.sock;
       fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
       include fastcgi_params;
   }
   location = /favicon.ico {
       log_not_found off;
       access_log off;
   }
   location = /robots.txt {
       try_files \$uri \$uri/ /index.php?\$args;
       allow all;
       log_not_found off;
       access_log off;
   }
   location ~* \.(js|jpg|jpeg|gif|png|css|tgz|gz|rar|bz2|doc|pdf|ppt|tar|wav|bmp|rtf|swf|ico|flv|txt|woff|woff2|svg)$ {
       expires 365d;
   }
   location ~ /\.ht {
       deny all;
   }
   location ~ /\.us {
       deny all;
   }
   location ~* "(base64_encode)(.*)(\()" {
       deny all;
   }
   location ~* "(eval\()" {
       deny all;
   }
   location = /xmlrpc.php {
       return 403;
   }
   rewrite ^/sitemap_index\.xml$ /index.php?sitemap=1 last;
   rewrite ^/([^/]+?)-sitemap([0-9]+)?\.xml$ /index.php?sitemap=\$1&sitemap_n=\$2 last;
}
EOF

# Enable Nginx site
ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/"

# Create MySQL database and user
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"

# Download and configure WordPress
cd "$WEBROOT"
wget https://wordpress.org/latest.tar.gz
tar xzf latest.tar.gz
mv wordpress/* .
rmdir wordpress
rm latest.tar.gz

# Create wp-config.php
cp wp-config-sample.php wp-config.php
sed -i "s/database_name_here/${DB_NAME}/" wp-config.php
sed -i "s/username_here/${DB_USER}/" wp-config.php
sed -i "s/password_here/${DB_PASS}/" wp-config.php

# Generate and insert WordPress salts
SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
sed -i "/put your unique phrase here/d" wp-config.php
echo "$SALTS" >> wp-config.php

# Add extra security to wp-config.php
cat >> wp-config.php << EOF

/* Custom Security Settings */
define('DISALLOW_FILE_EDIT', true);
define('AUTOMATIC_UPDATER_DISABLED', false);
define('WP_AUTO_UPDATE_CORE', 'minor');
EOF

# Set correct permissions
chown -R www-data:www-data "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;
chmod 600 "$WEBROOT/wp-config.php"

# Restart services
systemctl restart "php${PHP_VERSION}-fpm"
nginx -t && systemctl restart nginx

echo "WordPress setup completed successfully!"
echo "Your credentials have been saved to: $CREDS_FILE"
echo ""
echo "Please add the following to your DNS records:"
echo "${DOMAIN} IN A <your-server-ip>"
echo ""
echo "Key details:"
echo "Domain: $DOMAIN"
echo "Database Name: $DB_NAME"
echo "Database User: $DB_USER"
echo "Database Password: $DB_PASS"
echo "PHP Version: $PHP_VERSION"
echo ""
echo "Visit http://${DOMAIN} to complete WordPress installation."
