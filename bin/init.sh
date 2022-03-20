#!/bin/bash

SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
SYNC=${SCRIPT_PATH}/sync.sh

Y=-y

# get rid of that f**** useless editor
apt remove --purge $Y joe

apt install $Y vim

# set a usable vimrc (no stupid mouse, dark background, etc...)
$SYNC /etc/vim/vimrc.local

# pick a default editor (nano is novice friendly)
update-alternatives --config editor


# run any pending updates
apt update
apt upgrade $Y

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

echo "if you need plain ftp access"
echo "TODO: conf for limiting to a ftp-access group + chroot + fail2ban"
apt install proftpd-basic

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

# php sury
apt install $Y apt-transport-https lsb-release ca-certificates curl

wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
sh -c 'echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'

apt update

PHP_VERSION=7.4

apt install $Y php-pear php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-apcu php${PHP_VERSION}-apcu-bc \
  php${PHP_VERSION}-opcache php${PHP_VERSION}-curl php${PHP_VERSION}-imagick php${PHP_VERSION}-gnupg php${PHP_VERSION}-mysql \
  php${PHP_VERSION}-intl php${PHP_VERSION}-json php${PHP_VERSION}-zip php${PHP_VERSION}-xsl php${PHP_VERSION}-xmlrpc php${PHP_VERSION}-xml \
  php${PHP_VERSION}-uuid php${PHP_VERSION}-sqlite3 php${PHP_VERSION}-mbstring php${PHP_VERSION}-bcmath php${PHP_VERSION}-bz2 \
  php${PHP_VERSION}-mcrypt php${PHP_VERSION}-imap php${PHP_VERSION}-memcache php${PHP_VERSION}-memcached \
  php${PHP_VERSION}-soap

# this one doesn't exist in 7.0
apt install $Y php7.4-maxminddb

$SYNC /etc/php/${PHP_VERSION}/fpm/pool.d

systemctl restart php${PHP_VERSION}-fpm

echo "Installing php composer"
php -r "readfile('http://getcomposer.org/installer');" | php -- --install-dir=/usr/local/bin/ --filename=composer

echo "Installing wp-cli"
curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod a+x /usr/local/bin/wp

echo "and enable autocompletion"
curl -o /etc/bash_completion.d/wp-completion.bash https://raw.githubusercontent.com/wp-cli/wp-cli/v2.4.0/utils/wp-completion.bash

echo "Done."

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


## Munin
initMunin() {
  apt install $Y munin munin-node munin-plugins-extra libwww-perl libcache-{perl,cache-perl} libnet-dns-perl libfcgi-client-perl

  # we don't want to expose /munin/ on all virtual hosts
  a2disconf munin
  systemctl reload apache2

  $SYNC /etc/munin

  cd /etc/munin/plugins

  ln -s /usr/share/munin/plugins/apache_* ./
  ln -s /usr/share/munin/plugins/nginx_* ./

  munin-node-configure --suggest --shell | sh

  # install https://github.com/MorbZ/munin-php-fpm
  wget -O php-fpm https://raw.github.com/MorbZ/munin-php-fpm/master/php-fpm.php
  chmod a+x php-fpm 
  ln -s php-fpm php-fpm-memory
  ln -s php-fpm  php-fpm-cpu
  ln -s php-fpm  php-fpm-count
  ln -s php-fpm  php-fpm-time

  cd -
  service munin-node restart
}
initMunin

# Varnish
initVarnish() {
  # https://packagecloud.io/varnishcache/varnish70/

  curl -s https://packagecloud.io/install/repositories/varnishcache/varnish70/script.deb.sh | sudo bash

  # script does an apt update

  apt install varnish

  # add group varnish to munin
  adduser munin varnish

  # listen to port localhost:6081 and localhost:6091
  # restrict to localhost
  # adjust cache size to your needs
  # TODO: cache on tmpfs
  systemctl edit --full varnish

  # varnish-modules
  apt install varnish-dev python-sphinx make automake libtool

  git clone https://github.com/varnish/varnish-modules.git /root/varnish-modules
  cd /root/varnish-modules
  git checkout 7.0

  ./bootstrap
  ./configure   # run "configure -h" first to list options
  make
  #make check    # optional (tests)
  # Note: a building from source you need to run make rst-docs before being able to install.
  make rst-docs # optional (docs)
  make install  # optional (installation), run as root

  cd -
}

read -p "Install Varnish 7.0 [Y/n]?" installVarnish
if [[ $installVarnish =~ ^(Y|y| ) ]] || [[ -z $installVarnish ]]; then
  initVarnish
fi
# case "$installVarnish" in 
#   y|Y ) initVarnish;;
#   n|N ) ;;
#   * ) initVarnish;;
# esac


# NetData
initNetData() {
  apt install netdata netdata-web

  $SYNC /etc/netdata/python.d

  touch /etc/netdata/htpasswd

  pwgen -A
  echo "Set password for user netdata"
  printf "netdata:$(openssl passwd -apr1)" >> /etc/netdata/htpasswd

  # Node
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install nodejs


  # imgopt
  apt install $Y advancecomp optipng libjpeg-turbo-progs build-essential wget

  curl -o /usr/local/bin/imgopt https://raw.githubusercontent.com/kormoc/imgopt/main/imgopt \
    && chmod a+x /usr/local/bin/imgopt

  cd /tmp

  curl -o jfifremove.c https://raw.githubusercontent.com/kormoc/imgopt/main/jfifremove.c \
    && gcc -o jfifremove jfifremove.c \
    && mv jfifremove /usr/local/bin/

  wget http://www.jonof.id.au/files/kenutils/pngout-20200115-linux.tar.gz \
    && tar xzvf pngout-20200115-linux.tar.gz \
    && mv pngout-20200115-linux/amd64/pngout /usr/local/bin/

  cd -
}
initNetData

read -p "Install NetData [Y/n]?" installNetData
if [[ $installNetData =~ ^(Y|y| ) ]] || [[ -z $installNetData ]]; then
  initNetData
fi


# Finelizing

# clear some disk space
apt autoclean
apt clean

# create www-adm user (phpmyadmin)
pwgen
adduser www-adm

echo "sudo -u www-adm -s"
echo "cd"
echo "wget https://files.phpmyadmin.net/phpMyAdmin/4.9.7/phpMyAdmin-4.9.7-all-languages.zip"
echo "unzip phpMyAdmin-4.9.7-all-languages.zip"
echo "ln -s phpMyAdmin-4.9.7-all-languages www.mysql"
echo "exit"
echo "# Now as root run this to add .user.ini and config.inc.php"
echo "${SYNC} /home/www-adm/www.mysql"
echo "chown -R www-adm:www-adm /home/www-adm/www.mysql"
echo "You still have to add blowfish key if you want to use cookie based auth. (By default we use http auth)"

MYSQL_SUPERUSER=newuser
MYSQL_SUPERUSER_PASSWORD=password
echo
echo "echo \"CREATE USER '${MYSQL_SUPERUSER}'@'localhost' IDENTIFIED BY '${MYSQL_SUPERUSER_PASSWORD}';\" | mysql"
echo "echo \"GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_SUPERUSER}'@'localhost' WITH GRANT OPTION;\" | mysql"
echo "echo \"FLUSH PRIVILEGES;\" | mysql"
