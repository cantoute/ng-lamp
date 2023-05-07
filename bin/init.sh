#!/usr/bin/env bash

SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
SYNC=${SCRIPT_PATH}/sync.sh

Y=-y

read -p "Install Varnish 7.0 [Y/n]?" installVarnish

read -p "Install NetData [Y/n]?" installNetData

# get rid of that useless editor
apt remove --purge $Y joe

apt install $Y vim

# set a usable vimrc (no stupid mouse, dark background, etc...)
$SYNC /etc/vim/vimrc.local

# pick a default editor (nano is novice friendly)
update-alternatives --config editor


# run any pending updates
apt update
apt upgrade $Y

apt install $Y locales-all

# keep track of /etc
apt install $Y git etckeeper
# lets not have letsencrypt ssl keys in git repo
cat "${SCRIPT_PATH}/../root-fs/etc/.gitignore.certbot" >> /etc/.gitignore

echo "** adding etckeeper diff **"
$SYNC /etc/etckeeper

echo "If you plan to run wordpress or php sites, apparmor isn't of much help."
# Don't realy see the point of having this
apt remove --purge apparmor

echo "if you chose to install the firewall from over ssh, don't forget to open port 21 or skip apply rules at the end."
apt install arno-iptables-firewall

apt install postfix

# Install ProFtpd
. ${SCRIPT_PATH}/init.d/proftpd

apt install $Y fail2ban

apt install $Y telnet bsd-mailx htop apachetop screen wget curl build-essential
apt install $Y certbot rsync zip unzip ntpdate ntp
apt install $Y imagemagick graphicsmagick webp
apt install $Y pwgen tree
apt install $Y nload nmap
apt install $Y memcached

apt install $Y apache2 apache2-utils
a2enmod deflate setenvif headers auth_basic auth_digest expires env \
  proxy_fcgi rewrite alias remoteip

$SYNC /etc/apache2

a2enconf ng-lamp
a2enconf dont-cache-robots-txt

a2dissite 000-default

a2ensite 000-ng-lamp-default
a2ensite localhost

systemctl restart apache2


# nginx (mainline)
apt install $Y curl gnupg2 ca-certificates lsb-release

curl -o /etc/apt/trusted.gpg.d/nginx_signing.asc https://nginx.org/keys/nginx_signing.key

echo "deb http://nginx.org/packages/mainline/debian `lsb_release -cs` nginx" \
    | sudo tee /etc/apt/sources.list.d/nginx.list

apt update
apt install $Y nginx

# keep a copy of the distribution nginx.conf
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.dist.bak

$SYNC /etc/nginx

cd /etc/nginx/conf.d
ln -s ../ng-lamp/*.conf ./

# required by snippets/letsencrypt-acme-challenge.conf
mkdir /var/www/letsencrypt

systemctl restart nginx

# Install php fpm from sury.org
. ${SCRIPT_PATH}/init.d/php-sury

## MySQL
apt install $Y mariadb-client mariadb-server
mysql_secure_installation


# update user skel (.bashrc)
$SYNC /etc/skel/

# setup fail2ban
# for phpMyAdmin don't forget to add this in config.inc.php: $cfg['AuthLog'] = 'syslog';

$SYNC /etc/fail2ban/

service fail2ban restart


# Backups
apt install $Y rdiff-backup time

mkdir -p "/home/backups/rdiff-$(hostname -s)" \
  && chmod 700 /home/backups

$SYNC /root/bin
$SYNC /etc/cron.d/backups

# Install Munin
. ${SCRIPT_PATH}/init.d/munin

# Install Varnish
if [[ $installVarnish =~ ^(Y|y| ) ]] || [[ -z $installVarnish ]]; then
  . ${SCRIPT_PATH}/init.d/varnish
fi
# case "$installVarnish" in 
#   y|Y ) initVarnish;;
#   n|N ) ;;
#   * ) initVarnish;;
# esac


# Install NetData
if [[ $installNetData =~ ^(Y|y| ) ]] || [[ -z $installNetData ]]; then
  . ${SCRIPT_PATH}/init.d/netdata
fi

# Finalizing

# clear some disk space
apt autoclean
apt clean

source ${SCRIPT_PATH}/init.d/mysql-stuff

echo "Adding usr/local/bin utils"
cp ${SCRIPT_PATH}/../root-fs/usr/local/bin/* /usr/local/bin
