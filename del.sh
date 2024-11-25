#!/bin/bash
# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Function to detect PHP version
get_php_version() {
    php -v | head -n1 | cut -d" " -f2 | cut -d"." -f1,2
}

# Function to get MySQL root password
get_mysql_password() {
    if [ ! -f /root/.pwdmysql ]; then
        echo "Error: MySQL password file ~/.pwdmysql not found"
        exit 1
    }
    cat ~/.pwdmysql
}

# Get PHP version
PHP_VERSION=$(get_php_version)
if [ -z "$PHP_VERSION" ]; then
    echo "Error: PHP is not installed or not found in PATH"
    exit 1
fi

# Get MySQL password
MYSQL_PWD=$(get_mysql_password)
if [ -z "$MYSQL_PWD" ]; then
    echo "Error: MySQL password is empty"
    exit 1
fi

# Function to sanitize domain for database name
sanitize_domain() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]'
}

# Function to execute MySQL commands
execute_mysql() {
    mysql -u root -p"${MYSQL_PWD}" -e "$1"
}

# Domain input with confirmation
read -p "Enter domain name to delete (e.g., example.com): " DOMAIN
echo "You entered: $DOMAIN"
read -p "Are you sure you want to delete all components for ${DOMAIN}? (y/n): " confirm
if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo "Deletion cancelled."
    exit 1
fi

# Generate sanitized domain for database
SANITIZED_DOMAIN=$(sanitize_domain "$DOMAIN")
DB_NAME="db_${SANITIZED_DOMAIN}"
DB_USER="u_${SANITIZED_DOMAIN}"

echo "The following will be deleted:"
echo "- Website files in /var/www/${DOMAIN}"
echo "- Nginx configuration for ${DOMAIN}"
echo "- PHP-FPM pool configuration for ${DOMAIN} (PHP ${PHP_VERSION})"
echo "- Database: ${DB_NAME}"
echo "- Database user: ${DB_USER}"
echo "- Credentials file: /root/.wordpress_credentials_${SANITIZED_DOMAIN}"

read -p "THIS ACTION CANNOT BE UNDONE. Continue? (type 'yes' to confirm): " final_confirm
if [ "$final_confirm" != "yes" ]; then
    echo "Deletion cancelled."
    exit 1
fi

echo "Starting deletion process..."

# Remove Nginx configuration
echo "Removing Nginx configuration..."
rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
rm -f "/etc/nginx/sites-available/${DOMAIN}"

# Remove PHP-FPM pool
echo "Removing PHP-FPM pool configuration..."
rm -f "/etc/php/${PHP_VERSION}/fpm/pool.d/${DOMAIN}.conf"

# Remove website files
echo "Removing website files..."
rm -rf "/var/www/${DOMAIN}"

# Remove database and user
echo "Removing database and user..."
if ! execute_mysql "DROP DATABASE IF EXISTS ${DB_NAME}"; then
    echo "Error: Failed to drop database"
    exit 1
fi

if ! execute_mysql "DROP USER IF EXISTS '${DB_USER}'@'localhost'"; then
    echo "Error: Failed to drop user"
    exit 1
fi

if ! execute_mysql "FLUSH PRIVILEGES"; then
    echo "Error: Failed to flush privileges"
    exit 1
fi

# Remove credentials file
echo "Removing credentials file..."
rm -f "/root/.wp_creds_${SANITIZED_DOMAIN}"

# Restart services
echo "Restarting services..."
systemctl restart "php${PHP_VERSION}-fpm"
if ! nginx -t; then
    echo "Error: Nginx configuration test failed"
    exit 1
fi
systemctl restart nginx

echo "Deletion completed successfully!"
echo "The following components were removed:"
echo "✓ Website files"
echo "✓ Nginx configuration"
echo "✓ PHP-FPM pool configuration (PHP ${PHP_VERSION})"
echo "✓ Database and database user"
echo "✓ Credentials file"
