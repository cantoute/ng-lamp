#!/usr/bin/env bash

# for debuging stop script on error
# set -e

LOCKFILE=/var/run/backup-rdiff.pid
LOCAL_CONF=/root/backup-rdiff-local.conf

GLOBIGNORE=*:?

NICECMD="time -p ionice -c 3 nice -n 19"
# DSTBASE=root@linux.box.com::/home/backups/$(hostname -s)
DSTBASE=/home/backups/rdiff-$(hostname -s)
RDIFF="rdiff-backup"

# RDIFFARGS="-v5 --print-statistics --exclude **/*nobackup*"
# RDIFFARGS="-v5 --print-statistics --exclude **/*nobackup* --exclude-special-files"
RDIFFARGS="--exclude **/swapfile --exclude **/*nobackup* --exclude **/lost+found --exclude-sockets --exclude-device-files --exclude-fifos"

# old backups remove
RDIFFRMOLD="--remove-older-than 4W --force"

MAIL_ALERT_FROM="root"
MAIL_ALERT_TO="root"
MAIL_ALERT_SUBJECT="ALERT - Issues with backups on $(hostname)"
MAIL_ALERT_SEND="mailx -s \"${MAIL_ALERT_SUBJECT}\" -r \"${MAIL_ALERT_FROM}\" -c \"${MAIL_ALERT_TO}\""

# mail_also_to="sendCopy@example.com"
# MAIL_ALERT="mailx -s \"$mail_subject\" -r \"$mail_from\" -c \"$mail_to\" \"$mail_also_to\""

# load local settings
[[ -f "$LOCAL_CONF" ]] && source "$LOCAL_CONF"

[[ -d "$DSTBASE" ]] || {
  mkdir -p "$DSTBASE" || {
    echo $msg | $MAIL_ALERT_SEND
    exit 1
  }
}

# remove lock file if older then 3 days
# TODO: smarter to check if pid is still runing
if test -e $LOCKFILE
then
  if test `find $LOCKFILE -mtime 3 -type f`;
  then
    echo "${LOCKFILE} older then 3 days!  Deleting it."
    rm -f $LOCKFILE
  fi
fi

if test -e $LOCKFILE;
then
  # todo: send a mail alert #
  msg="Backup is already running ?"
  echo $msg
  echo "If it isn't, remove ${LOCKFILE} and try again."

  echo $msg | $MAIL_ALERT_SEND
  exit 1
else
  # put this process id in lockfile
  echo $$ > $LOCKFILE
fi

# Backing up /root
BACKUPDIR=/root
BACKUPARGS=""

[[ -d "${DSTBASE}" && ! -d "${DSTBASE}${BACKUPDIR}" ]] \
  && echo "Creating dir ${DSTBASE}${BACKUPDIR}" \
  && mkdir -p "${DSTBASE}${BACKUPDIR}"

echo /*
echo ** Backing up $BACKUPDIR
echo */
$NICECMD $RDIFF $RDIFFARGS $BACKUPARGS $BACKUPDIR $DSTBASE$BACKUPDIR
$NICECMD $RDIFF $RDIFFRMOLD $DSTBASE$BACKUPDIR

# Backing up /etc
BACKUPDIR=/etc
BACKUPARGS=""

[[ -d "${DSTBASE}" && ! -d "${DSTBASE}${BACKUPDIR}" ]] \
  && echo "Creating dir ${DSTBASE}${BACKUPDIR}" \
  && mkdir -p "${DSTBASE}${BACKUPDIR}"

echo /*
echo ** Backing up $BACKUPDIR
echo */
$NICECMD $RDIFF $RDIFFARGS $BACKUPARGS $BACKUPDIR $DSTBASE$BACKUPDIR
$NICECMD $RDIFF $RDIFFRMOLD $DSTBASE$BACKUPDIR

# Backing up /usr/local
BACKUPDIR=/usr/local
BACKUPARGS=""

[[ -d "${DSTBASE}" && ! -d "${DSTBASE}${BACKUPDIR}" ]] \
  && echo "Creating dir ${DSTBASE}${BACKUPDIR}" \
  && mkdir -p "${DSTBASE}${BACKUPDIR}"

echo /*
echo ** Backing up $BACKUPDIR
echo */
$NICECMD $RDIFF $RDIFFARGS $BACKUPARGS $BACKUPDIR $DSTBASE$BACKUPDIR
$NICECMD $RDIFF $RDIFFRMOLD $DSTBASE$BACKUPDIR

# Backing up /opt
BACKUPDIR=/opt
BACKUPARGS=""

[[ -d "${DSTBASE}" && ! -d "${DSTBASE}${BACKUPDIR}" ]] \
  && echo "Creating dir ${DSTBASE}${BACKUPDIR}" \
  && mkdir -p "${DSTBASE}${BACKUPDIR}"

echo /*
echo ** Backing up $BACKUPDIR
echo */
$NICECMD $RDIFF $RDIFFARGS $BACKUPARGS $BACKUPDIR $DSTBASE$BACKUPDIR
$NICECMD $RDIFF $RDIFFRMOLD $DSTBASE$BACKUPDIR

# Backing up /var/www
BACKUPDIR=/var/www
BACKUPARGS="--exclude '**/.cache*' \
            --exclude '**/supercache/**' \
            --exclude '**/tmp/**' \
            --exclude '**/*.tmp' \
            --exclude '**/*.log' \
            --exclude '**/smarty/compile/**' \
            --exclude '**/sessions/sess_*' \
            --exclude '**/drush-backups/**' \
            --exclude '**/*nobackup*' \
            --exclude '**/uploads/*cache*' \
            --exclude '**/uploads/*tmp*' \
            --exclude '**/uploads/*log*' \
            --exclude '**/uploads/*backup*' \
            --exclude '**/uploads/backupbuddy_backups' \
            --exclude '**/uploads/pb_backupbuddy' \
            --exclude '**/wp-content/wflogs' \
            --exclude '**/wp-content/updraft' \
            --exclude '**/wp-content/sauvegarde' \

            "

            # --exclude **/sites/default/*settings.php \

[[ -d "${DSTBASE}" && ! -d "${DSTBASE}${BACKUPDIR}" ]] \
  && echo "Creating dir ${DSTBASE}${BACKUPDIR}" \
  && mkdir -p "${DSTBASE}${BACKUPDIR}"

echo /*
echo ** Backing up $BACKUPDIR
echo */
$NICECMD $RDIFF $RDIFFARGS $BACKUPARGS $BACKUPDIR $DSTBASE$BACKUPDIR
$NICECMD $RDIFF $RDIFFRMOLD $DSTBASE$BACKUPDIR

#echo /*
#echo ** Backing up $BACKUPDIR : **/sites/default to /home/backups/serv01$BACKUPDIR
#echo */
## du to drupal saving it's settings in a readonly dir, this gave issues over NFS
## so we will make a local backup
#$NICECMD $RDIFF $RDIFFARGS --include "**/sites/default" --exclude "*" $BACKUPDIR /home/backups/serv01$BACKUPDIR
#$NICECMD $RDIFF $RDIFFRMOLD /home/backups/serv01$BACKUPDIR

# Backing up /home
BACKUPDIR=/home

# if DSTBASE is a local dir and is part of backup source path, lets avoid looping
# [[ -d "${DSTBASE}" && "${DSTBASE}/" = ${BACKUPDIR}/* ]] \
#   && RDIFFARGS="${RDIFFARGS} --exclude ${DSTBASE}**"

RDIFFARGS="${RDIFFARGS} --exclude ${DSTBASE}**"

[[ -d "${DSTBASE}" && ! -d "${DSTBASE}${BACKUPDIR}" ]] \
  && echo "Creating dir ${DSTBASE}${BACKUPDIR}" \
  && mkdir -p "${DSTBASE}${BACKUPDIR}"

echo /*
echo ** Backing up $BACKUPDIR
echo */
$NICECMD $RDIFF $RDIFFARGS $BACKUPARGS $BACKUPDIR $DSTBASE$BACKUPDIR
$NICECMD $RDIFF $RDIFFRMOLD $DSTBASE$BACKUPDIR

# Remove lock file and end script
#
if test -e $LOCKFILE; then
  rm -f $LOCKFILE;
else
  msg="ERROR Missing lock file ?!"
  echo ""
  echo "###################################"
  echo $msg
  echo $msg | $MAIL_ALERT_SEND
fi
