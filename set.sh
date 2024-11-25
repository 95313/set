#!/bin/bash

# Exit on any error
set -e

# Function to generate random password
generate_password() {
    openssl rand -base64 16
}

# Function to check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" 1>&2
        exit 1
    fi
}

# Detect system architecture
detect_architecture() {
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64)
            ARCH="x86-64"
            ;;
        aarch64)
            ARCH="aarch64"
            ;;
        *)
            echo "Unsupported architecture: ${ARCH}"
            exit 1
            ;;
    esac
}

# Update system packages
update_system() {
    echo "Updating system packages..."
    apt-get update
    apt-get upgrade -y
}

# Install NGINX
install_nginx() {
    echo "Installing NGINX..."
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
}

# Install Certbot
install_certbot() {
    echo "Installing Certbot..."
    apt-get install -y certbot python3-certbot-nginx
}

# Install IonCube Loader
install_ioncube() {
    echo "Installing IonCube Loader..."
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    cd $TEMP_DIR
    
    # Download and extract IonCube Loader
    wget https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${ARCH}.tar.gz
    tar xzf ioncube_loaders_lin_${ARCH}.tar.gz
    
    # Get PHP extension directory
    PHP_EXT_DIR=$(php -i | grep extension_dir | awk '{print $3}')
    
    # Copy IonCube Loader to PHP extension directory
    cp ioncube/ioncube_loader_lin_8.3.so $PHP_EXT_DIR
    
    # Create IonCube configuration file
    echo "zend_extension=ioncube_loader_lin_8.3.so" > /etc/php/8.3/mods-available/ioncube.ini
    
    # Enable IonCube for PHP-FPM and CLI
    ln -sf /etc/php/8.3/mods-available/ioncube.ini /etc/php/8.3/fpm/conf.d/00-ioncube.ini
    ln -sf /etc/php/8.3/mods-available/ioncube.ini /etc/php/8.3/cli/conf.d/00-ioncube.ini
    
    # Clean up
    cd
    rm -rf $TEMP_DIR
    
    # Restart PHP-FPM
    systemctl restart php8.3-fpm
}

# Install PHP 8.3 and extensions
install_php() {
    echo "Installing PHP 8.3 repository..."
    apt-get install -y software-properties-common
    add-apt-repository -y ppa:ondrej/php
    apt-get update

    echo "Installing PHP 8.3 and extensions..."
    apt-get install -y \
    php8.3-fpm \
    php8.3-common \
    php8.3-mysql \
    php8.3-xml \
    php8.3-intl \
    php8.3-curl \
    php8.3-gd \
    php8.3-imagick \
    php8.3-cli \
    php8.3-dev \
    php8.3-imap \
    php8.3-mbstring \
    php8.3-opcache \
    php8.3-soap \
    php8.3-zip
    
    # Configure php.ini
    PHP_INI="/etc/php/8.3/fpm/php.ini"
    sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 64M/' $PHP_INI
    sed -i 's/post_max_size = 8M/post_max_size = 64M/' $PHP_INI
    sed -i 's/memory_limit = 128M/memory_limit = 256M/' $PHP_INI
    
    # Optimize PHP-FPM for better performance
    PHP_FPM_CONF="/etc/php/8.3/fpm/pool.d/www.conf"
    sed -i 's/pm.max_children = 5/pm.max_children = 50/' $PHP_FPM_CONF
    sed -i 's/pm.start_servers = 2/pm.start_servers = 5/' $PHP_FPM_CONF
    sed -i 's/pm.min_spare_servers = 1/pm.min_spare_servers = 5/' $PHP_FPM_CONF
    sed -i 's/pm.max_spare_servers = 3/pm.max_spare_servers = 35/' $PHP_FPM_CONF
    
    # Enable PHP 8.3 FPM
    systemctl enable php8.3-fpm
    systemctl restart php8.3-fpm
}

# Install and secure MariaDB
install_mariadb() {
    echo "Installing MariaDB..."
    apt-get install -y mariadb-server
    systemctl enable mariadb
    systemctl start mariadb
    
    # Generate and save root password
    ROOT_PASSWORD=$(generate_password)
    echo $ROOT_PASSWORD > /root/.pwdmysql
    chmod 600 /root/.pwdmysql
    
    # Secure MariaDB installation
    mysql -e "UPDATE mysql.user SET Password=PASSWORD('$ROOT_PASSWORD') WHERE User='root'"
    mysql -e "DELETE FROM mysql.user WHERE User=''"
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
    mysql -e "DROP DATABASE IF EXISTS test"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
    mysql -e "FLUSH PRIVILEGES"
    
    echo "MariaDB root password has been saved to /root/.pwdmysql"
}

install_wp_cli(){
    echo "install wp cli"
    curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /usr/local/bin/wp
}

# Verify installations
verify_installations() {
    echo "Verifying installations..."
    
    # Check PHP and IonCube
    php -v
    php -m | grep -i "ionCube"
    
    # Check if services are running
    systemctl status nginx --no-pager
    systemctl status php8.3-fpm --no-pager
    systemctl status mariadb --no-pager
}

# Main installation process
main() {
    check_root
    detect_architecture
    update_system
    install_nginx
    install_certbot
    install_php
    install_ioncube
    install_mariadb
    install_wp_cli
    verify_installations
    
    echo "Installation completed successfully!"
    echo "NGINX, PHP 8.3-FPM with IonCube, and MariaDB have been installed and configured."
    echo "MariaDB root password is stored in /root/.pwdmysql"
}

# Run main function
main
