#!/bin/bash

SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# get rid of that fu*king useless editor
apt remove --purge joe

# pick a default editor (nano is novice friendly)
update-alternatives --config editor

# run any pending updates
apt update
apt upgrade

# keep track of /etc
apt install git etckeeper
# lets not have letsencrypt ssl keys in git repo
cat $SCRIPT_PATH/../root-fs/etc/.gitignore.certbot >> /etc/.gitignore

# Don't realy see the point of having this
apt remove --purge apparmor

apt install postfix rsync vim zip

apt install certbot

apt install ntpdate ntp
apt install telnet bsd-mailx htop apachetop screen
apt install imagemagick
apt install graphicsmagick
apt install webp
apt install pwgen tree
apt install nload nmap
apt install memcached

echo "if you chose to install the firewall, don't forget to open port 21"
apt install arno-iptables-firewall
apt install fail2ban

apt install apache2 apache2-utils
a2enmod deflate setenvif headers auth_basic auth_digest expires env proxy_fcgi rewrite alias remoteip

$SCRIPT_PATH/sync.sh /etc/apache2

a2enconf ng-lamp

a2dissite 000-default

a2ensite 000-ng-lamp-default
a2ensite localhost

systemctl restart apache2


# nginx (mainline)
apt install curl gnupg2 ca-certificates lsb-release

curl -o /etc/apt/trusted.gpg.d/nginx_signing.asc https://nginx.org/keys/nginx_signing.key

echo "deb http://nginx.org/packages/mainline/debian `lsb_release -cs` nginx" \
    | sudo tee /etc/apt/sources.list.d/nginx.list

apt update
apt install nginx

# keep a copy of the distribution nginx.conf
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.dist.bak

$SCRIPT_PATH/bin/sync.sh /etc/nginx

cd /etc/nginx/conf.d
ln -s ../ng-lamp/*.conf ./
cd -

# required by snippets/letsencrypt-acme-challenge.conf
mkdir /var/www/letsencrypt

systemctl restart nginx

# php sury
apt install apt-transport-https lsb-release ca-certificates curl

wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
sh -c 'echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'

apt update

apt install php7.4-fpm php7.4-cli php-pear php7.4-apcu php7.4-apcu-bc \
  php7.4-opcache php7.4-curl php7.4-imagick php7.4-gnupg php7.4-mysql \
  php7.4-intl php7.4-json php7.4-zip php7.4-xsl php7.4-xmlrpc php7.4-xml \
  php7.4-uuid php7.4-sqlite3 php7.4-mbstring php7.4-bcmath php7.4-bz2 \
  php7.4-mcrypt php7.4-maxminddb php7.4-imap php7.4-memcache php7.4-memcached \
  php7.4-soap

$SCRIPT_PATH/sync.sh /etc/php/7.4/fpm/pool.d

systemctl restart php7.4-fpm

## MySQL
apt install mariadb-client mariadb-server
mysql_secure_installation

# munin
apt install munin munin-node munin-plugins-extra libwww-perl libcache-{perl,cache-perl} libnet-dns-perl
a2disconf munin
systemctl restart apache2

$SCRIPT_PATH/sync.sh /etc/munin/plugin-conf.d

ln -s /usr/share/munin/plugins/apache_* /etc/munin/plugins/
ln -s /usr/share/munin/plugins/nginx_* /etc/munin/plugins/

munin-node-configure --suggest --shell | sh

service munin-node restart

# update user skel (.bashrc)
$SCRIPT_PATH/sync.sh /etc/skel/

# setup fail2ban
# for phpMyAdmin don't forget to add this: $cfg['AuthLog'] = 'syslog';

$SCRIPT_PATH/sync.sh /etc/fail2ban/

service fail2ban restart

# create www-adm user (phpmyadmin)
pwgen
adduser www-adm

echo "sudo -u www-adm -s"
echo "cd"
echo "wget https://files.phpmyadmin.net/phpMyAdmin/5.1.1/phpMyAdmin-5.1.1-all-languages.tar.gz"
echo "tar xzf phpMyAdmin-5.1.1-all-languages.tar.gz"
echo "ln -s phpMyAdmin-5.1.1-all-languages www.mysql"
echo "exit"
echo "# Now as root run this to add .user.ini and config.inc.php"
echo "$SCRIPT_PATH/sync.sh /home/www-adm/www.mysql"
echo "chown -R www-adm:www-adm /home/www-adm/www.mysql"
echo "You still have to add blowfish key"

