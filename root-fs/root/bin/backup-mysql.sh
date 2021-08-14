#!/bin/bash

# stop on error - if backup fails old ones aren't deleted
set -e

umask 027

LANG="en_US.UTF-8"

MYSQLDUMP=$(which mysqldump)
BZIP='bzip2 -z'

dateStamp=$(date +%F_%H%M)

backupSourceHostname=$(hostname -s)

backupDestinationDir="/home/backups/mysql-${backupSourceHostname}"
backupDestinationDirSingle=${backupDestinationDir}/single

# create missing dir
[ ! -d "${backupDestinationDir}" ] \
  && ( mkdir -p "${backupDestinationDir}"; chmod 700 "${backupDestinationDir}" )

[ ! -d "${backupDestinationDirSingle}" ] \
  && ( mkdir -p "${backupDestinationDirSingle}"; chmod 700 "${backupDestinationDirSingle}" )

if [ "$1" = "single" ]
then
  echo "Doing single database backups..."

  dbList=$(mysql -Br --silent <<< "SHOW databases WHERE \`Database\` NOT IN ('information_schema', 'performance_schema', 'mysql', 'article3_joomla', 'roundcubemail', 'www-stats_prod', 'antony', 'article3_drupal', 'postfixadmin', 'phpmyadmin') AND \`Database\` NOT LIKE 'trash\_%';")

  for db in ${dbList}
  do
    printf "Processing '${db}'... "

    time $MYSQLDUMP --skip-lock-tables --single-transaction "${db}" | $BZIP > "${backupDestinationDirSingle}/mysqldump_${backupSourceHostname}_${db}_$(date +%F_%H%M).sql.bz2"

    echo "Done."
  done;

  echo "Single database backups done."
else
  echo "Doing full dump (all databases)"
  time $MYSQLDUMP -A --events --single-transaction | $BZIP > ${backupDestinationDir}/mysqldumpall_${backupSourceHostname}_${dateStamp}.sql.bz2
  echo "Done."
fi

echo "Deleting old backups"
# delete full backups older then 30 days
find "${backupDestinationDir}" -type f -name 'mysqldumpall_*.sql.*' -mtime +31 -exec rm {} \;

# delete single database backup older than 3 days
find "${backupDestinationDirSingle}" -type f -name 'mysqldump_*.sql.*' -mtime +3 -exec rm {} \;

echo "Done"
