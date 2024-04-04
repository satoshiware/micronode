#!/bin/bash

# Make sure we are not running as root, but that we have sudo privileges.
if [ "$(id -u)" = "0" ]; then
    echo "This script must NOT be run as root (or with sudo)!"
    echo "if you need to create a sudo user (e.g. satoshi), run the following commands:"
    echo "   sudo adduser satoshi"
    echo "   sudo usermod -aG sudo satoshi"
    echo "   sudo su satoshi # Switch to the new user"
    exit 1
elif [ "$(sudo -l | grep '(ALL : ALL) ALL' | wc -l)" = 0 ]; then
    echo "You do not have enough sudo privileges!"
    exit 1
fi
cd ~; sudo pwd # Print Working Directory; have the user enable sudo access if not already.

# Give the user pertinent information about this script and how to use it.
clear
echo "This script will install apache with a single wordpress site."
echo "Make sure your DNS records are already configured."
echo "Uses \"Let's Encrypt\" SSL Certificate Authority."
echo ""
echo "In order to see the php_info.php file, you need connect with port forwarding configured."
echo "    Example: \"ssh -L 8080:localhost:80 satoshi@btcofaz.com -i C:\Users\satoshi\.ssh\Yubikey"
echo "Once the connection is established, use point your browser to the following URL:"
echo "    localhost:8080/php_info.php"
echo ""
echo "To edit, configure, and design the wordpress website, goto \"\$DNS/wp-admin\"."
echo ""
echo "The command to update the administrator email for \"Let's Encrypt\" certbot:"
echo "    \"sudo certbot update_account --no-eff-email --email \$EMAIL\""
echo "The \"Administration Email Address\" for Wordpress can be changed in \"wp-admin\" Settings."
echo ""
echo "Plugins that are installed with the script: "
echo "    \"Limit Login Attempts Reloaded\""
echo "    \"Salt Shaker\""
echo "    \"UpdraftPlus\""
echo "    \"WP Mail SMTP\""
read -p "Press the enter key to continue..."

########## Get Setup Parameters from The User ##############
read -p "Web site/server title? (e.g. BTCofAZ): " TITLE
read -p "Domain name address? (e.g. btcofaz.com): " DNS; DNS=${DNS,,}; DNS=${DNS#http://}; DNS=${DNS#https://}; DNS=${DNS#www.} # Make lowercase and remove http and www if they exist.
read -p "Administrator email? (e.g. satoshi@btcofaz.com): " EMAIL; EMAIL=${EMAIL,,} # Make lowercase

########## Update/Upgrade The System ##############
sudo apt-get -y update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install --only-upgrade openssh-server # Upgrade seperatly to ensure non-interactive mode
sudo apt-get -y upgrade

########## Install Required Packages ##############
sudo apt-get -y install ufw                 # Install The Uncomplicated Firewall
sudo apt-get -y install apache2             # Install Apache Web Server
sudo apt-get -y install wget                # Intall get capabilities from the "World Wide Web"

sudo apt-get -y install php php-common      # Install main PHP package and its common files
sudo apt-get -y install php-mysql           # PHP Extension: Connects to MySQL for database interactions.

sudo apt-get -y install php-curl            # PHP Extension: Performs remote request operations.
sudo apt-get -y install php-imagick         # PHP Extension: Provides better image quality for media uploads. See WP_Image_Editor for details. Smarter image resizing (for smaller images) and PDF thumbnail support, when Ghost Script is also available.
sudo apt-get -y install php-mbstring        # PHP Extension: Used to properly handle UTF8 text.
sudo apt-get -y install php-xml             # PHP Extension: Used for XML parsing, such as from a third-party site.
sudo apt-get -y install php-zip             # PHP Extension: Used for decompressing Plugins, Themes, and WordPress update packages.

sudo apt-get -y install php-bcmath          # PHP Extension: For arbitrary precision mathematics, which supports numbers of any size and precision up to 2147483647 decimal digits.
sudo apt-get -y install php-gd              # PHP Extension: If Imagick isn’t installed, the GD Graphics Library is used as a functionally limited fallback for image manipulation.
sudo apt-get -y install php-intl            # PHP Extension: Enable to perform locale-aware operations including but not limited to formatting, transliteration, encoding conversion, calendar operations, conformant collation, locating text boundaries and working with locale identifiers, timezones and graphemes.
sudo apt-get -y install php-mcrypt          # PHP Extension: Generates random bytes when libsodium and /dev/urandom aren’t available.

sudo apt-get -y install php-ssh2            # PHP Extension: Provide access to resources (shell, remote exec, tunneling, file transfer) on a remote machine using a secure cryptographic transport.

sudo apt-get -y install php-cli             # PHP Extension: PHP Command Line Interface.
sudo apt-get -y install php-pear            # PHP Extension: PHP Extension and Application Repository.

sudo apt-get -y install php-soap            # PHP Extension: Used to provide and consume Web services.
sudo apt-get -y install php-xmlrpc          # PHP Extension: System that allows remote updates to WordPress from other applications.
sudo apt-get -y install php-cgi             # PHP Extension: Protocol for transferring information between a Web server and a CGI program.
sudo apt-get -y install php-net-socket      # PHP Extension: Implements a low-level interface to the socket communication functions based on the popular BSD sockets.
sudo apt-get -y install php-xml-util        # PHP Extension: Lets you parse, but not validate, XML documents.

sudo apt-get -y install php-sqlite3         # PHP Extension: Add SQLite for satoshicoins.satoshiware.org
sudo apt-get -y install php-apcu            # PHP Extension: Add object caching functionality
sudo apt-get -y install php-phpseclib       # PHP Extension: Secure Communications Library

sudo apt-get -y install libapache2-mod-php  # mpm_event support

sudo apt-get -y install php-fpm             # Install FastCGI Process Manager
sudo apt-get -y install libapache2-mod-fcgid # Install FastCGI interface module for Apache 2

sudo apt-get -y install mariadb-server mariadb-client # Install Maria DB (database)

sudo apt-get -y install snapd               # Install Snappy (be able to access Ubuntu's repository)
sudo snap install core; sudo snap refresh core   # Add Snappy compatibility with all linux versions
sudo snap install --classic certbot         # Install Certbot with Snappy
sudo ln -s /snap/bin/certbot /usr/bin/certbot    # Make sure the Certbot command can be run

# Install WP-CLI
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
sudo chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp # Install it so only need to call 'wp'

########## Configure Ports & Enable Uncomplicated Firewall ##############
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 22/tcp
sudo ufw --force enable

########## Configure Apache Web Server ##############
sudo systemctl stop apache2
sudo a2dismod php"$(php --version | head -n 1 | cut -d " " -f 2 | cut -d "." -f 1,2)" # Disable latest version of php
sudo a2dismod mpm_prefork   # Disable legacy mode for processing user requests
sudo a2enmod mpm_event      # Enable Mulit-Processing (event driven) user requests
sudo a2enconf php*-fpm      # Enable FastCGI Process Manager
sudo a2enmod proxy          # Enable Proxy module
sudo a2enmod proxy_fcgi     # Enable FastCGI protocol
sudo a2dismod --force autoindex # Disable directory listings

# Set the name of the server: "Apache2_$(hostname)"
echo "ServerName Apache2_$(hostname)" | sudo tee /etc/apache2/conf-available/servername.conf
sudo a2enconf servername

# Create site folders, files, and websites with correct permissions
echo "<meta http-equiv=\"refresh\" content=\"3;url=https://$DNS/\" />" | sudo tee /var/www/html/index.html # Redirect default page to $DNS
sudo mkdir -p /var/www/$DNS
echo "<?php phpinfo(); ?>" | sudo tee /var/www/html/php_info.php # Create php info page
sudo chown -R www-data:www-data /var/www
sudo chmod -R 755 /var/www

# Default site configuration
cat << EOF | sudo tee /etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
    <Directory /var/www/html/php_info.php>
        Require local
    </Directory>
</VirtualHost>
EOF

# Main site configuration
cat << EOF | sudo tee /etc/apache2/sites-available/$DNS.conf
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    ServerName $DNS
    ServerAlias www.$DNS
    DocumentRoot /var/www/$DNS
    ErrorLog \${APACHE_LOG_DIR}/$DNS.error.log
    CustomLog \${APACHE_LOG_DIR}/$DNS.access.log combined
    <Directory /var/www/$DNS>
        AllowOverride All
    </Directory>
</VirtualHost>
EOF

sudo a2ensite $DNS
sudo a2enmod rewrite
sudo systemctl restart apache2 # Restart apache server

########## Create admin (satoshi) and database passwords ##############
# Create secure wordpress admin password replacing '/' with '0', '+' with '1', and '=' with ''
WP_PASSWD=$(openssl rand -base64 14); WP_PASSWD=${WP_PASSWD//\//0}; WP_PASSWD=${WP_PASSWD//+/1}; WP_PASSWD=${WP_PASSWD//=/}
echo "${WP_PASSWD}" | sudo tee ~/wp_satoshi_passwd.txt
sudo chmod 600 ~/wp_satoshi_passwd.txt
# Create secure wordpress database password replacing '/' with '0', '+' with '1', and '=' with ''
DB_PASSWD=$(openssl rand -base64 14); DB_PASSWD=${DB_PASSWD//\//0}; DB_PASSWD=${DB_PASSWD//+/1}; DB_PASSWD=${DB_PASSWD//=/}

########## Install Wordpress ##############
# Download Wordpress
cd /var/www/$DNS; sudo -u www-data wp core download

# Create new database and new user
sudo mysql -e "CREATE USER IF NOT EXISTS 'wpmaria_${DNS//./_}'@'localhost' IDENTIFIED BY ''"
sudo mysql -e "SET PASSWORD FOR 'wpmaria_${DNS//./_}'@'localhost' = PASSWORD('${DB_PASSWD}')"
sudo mysql -e "CREATE DATABASE IF NOT EXISTS mariadb_${DNS//./_}"
sudo mysql -e "GRANT ALL PRIVILEGES ON mariadb_${DNS//./_}.* TO 'wpmaria_${DNS//./_}'@'localhost'"
sudo mysql -e "FLUSH PRIVILEGES"

# Configure Wordpress
sudo -u www-data wp config create --dbname=mariadb_${DNS//./_} --dbuser=wpmaria_${DNS//./_} --dbpass=${DB_PASSWD}
sudo -u www-data wp core install --url=$DNS --title="$TITLE" --admin_user=satoshi --admin_password=$WP_PASSWD --admin_email=$EMAIL

# Set up auto Wordpress updates
cat << EOF | sudo tee /etc/cron.daily/wp-core-update-$DNS
cd /var/www/$DNS
sudo -u www-data wp core update
sudo -u www-data wp theme update --all
EOF
sudo chmod -R 755 /etc/cron.daily/wp-core-update-$DNS # Keep wordpress updated

########## Install Plugins ##############
cd /var/www/$DNS
sudo -u www-data wp plugin install limit-login-attempts-reloaded --force --activate # Limit Login Attempts Reloaded
sudo -u www-data wp plugin install salt-shaker --force --activate # Salt Shaker
sudo -u www-data wp plugin install updraftplus --force --activate # UpdraftPlus
sudo -u www-data wp plugin install wp-mail-smtp --force --activate # WP Mail SMTP

########## Configure the "Let's Encrypt" certbot for SSL certificates ##############
# If there is no subdomain (only a single '.'), add a second (identical) DNS with the "www." prefix
if [[ ${DNS//[^.]} == "." ]]; then DNS=$DNS,www.$DNS; fi
# Get new certificate and have certbot edit the apache configurations automatically
sudo certbot --apache --agree-tos --redirect --hsts --uir --staple-ocsp --no-eff-email --email $EMAIL -d $DNS

# Create daily cron job for auto update
echo '#!/bin/bash' | sudo tee /etc/cron.weekly/ssl-renewal
echo "certbot renew --quiet" | sudo tee -a /etc/cron.weekly/ssl-renewal
echo "systemctl reload apache2" | sudo tee -a /etc/cron.weekly/ssl-renewal
sudo chmod -R 755 /etc/cron.weekly/ssl-renewal

########## Installations Complete... Reboot Now ##############
sudo shutdown -r now 'Installs and upgrades requires reboot'