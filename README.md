# LAMP behind Nginx reverse proxy

## Work In Progress

This code has not been tested fully.

### init.sh script has never been tried yet

`sync.sh` seems to work fine so far (and makes backup of any replaced file in `/root/_ng-lamp.bak`)

## TODO:

- try `init.sh` on a fresh install
- fail2ban on phpMyAdmin
- munin configuration
- backups (rdiff-backup / mysqldump)
- install imgopt utility
- adding varnish

## Description

This is a toolbox for installing a LAMP behind Nginx reverse proxy on **Debian 10 (Buster)**

This stack is flexible, solid and works well for wordpress hosting. Getting the benefit of Nginx power yet still having .htaccess ease of use.

```txt
.
├── etc
│   ├── apache2
│   │   ├── conf-available
│   │   │   └── ng-lamp.conf
│   │   ├── ports.conf
│   │   └── sites-available
│   │       ├── 000-ng-lamp-default.conf
│   │       ├── localhost.conf
│   │       └── www.exemple.com.conf.skel
│   ├── fail2ban
│   │   └── jail.local
│   ├── .gitignore.certbot
│   ├── munin
│   │   └── plugin-conf.d
│   │       ├── apache
│   │       └── nginx
│   ├── nginx
│   │   ├── nginx.conf
│   │   ├── ng-lamp
│   │   │   ├── cloudflare.conf
│   │   │   ├── default-host.conf
│   │   │   ├── limit.conf
│   │   │   ├── localhost.conf
│   │   │   ├── misc.conf
│   │   │   ├── munin.conf.skel
│   │   │   ├── phpmyadmin.conf.skel
│   │   │   ├── redirect.conf.skel
│   │   │   ├── ssl.conf
│   │   │   ├── upstreams.conf
│   │   │   └── wordpress.conf.skel
│   │   └── snippets
│   │       ├── ban-bots.conf
│   │       ├── common-proxy-buffer.conf
│   │       ├── common-proxy.conf
│   │       ├── common-proxy-timeout.conf
│   │       ├── common-vhost.conf
│   │       ├── letsencrypt-acme-challenge.conf
│   │       ├── wordpress.conf
│   │       └── wordpress-webp-express.conf
│   ├── php
│   │   └── 7.4
│   │       └── fpm
│   │           └── pool.d
│   │               └── www-adm.conf
│   ├── skel
│   │   └── .bashrc
│   └── vim
│       └── vimrc.local
└── home
    └── www-adm
        └── www.mysql
            ├── config.inc.php
            └── .user.ini
```

### What it does

- set apache to listen only localhost:8081
  - a2enmod proxy_fcgi remoteip senenvif headers expires deflate rewrite env auth_basic auth_digest
- install nginx mainline
  - run nginx as `www-data` and not `nginx` (this is why it overrides [/etc/nginx/nginx.conf](./root-fs/etc/nginx/nginx.conf))
  - [/etc/snippets/common-proxy.conf](./root-fs/etc/nginx/snippets/common-proxy.conf) passes IP, Authentication, Schema and other headers to [/etc/apache2/conf-available/ng-lamp.conf](./root-fs/etc/apache2/conf-available/ng-lamp.conf)
- install [Sury PHP](https://deb.sury.org/) FPM alowing multiple php versions. (at this date are available 5.6, 7.0 to 7.4 and 8.0)
- making sure virtual host `localhost` is only accessible to munin
- nginx ratelimit to requests made to apache backend. [100 req then slowed to 1/s](./root-fs/etc/nginx/conf.d/wordpress.conf.skel#L61)
- remove fbclid from url (redirect 301) to improve SEO and privacy.

## Usage

clone repo as root (`sudo -s`)

```bash
# screen
apt update
apt upgrade
apt install git rsync
git clone git@github.com:cantoute/ng-lamp.git
cd ng-lamp
```

then run [init.sh](./bin/init.sh)

```bash
./bin/init.sh
```

[sync.sh](./bin/sync.sh) utility

```bash
# update all system settings/files
./bin/sync.sh /

# a diriectory (recursiveley)
./bin/sync.sh /etc/nginx/conf.d

# single file
./bin/sync.sh /etc/apache2/ports.conf
```
