#!/bin/bash

set -u

#export BORG_REPO=
#export BORG_PASSPHRASE=

backupLabel="$1"
shift

backupArgs="$@"

[[ -v 'BORG_REPO' ]] && {
  echo "BORG_REPO: ${BORG_REPO}"
}

backupPrefix="{hostname}-${backupLabel}"

createArgs=(
  --verbose
  --list
  --stats
  --show-rc
  --filter AME
  # --compression auto,zstd,11
  # --upload-ratelimit 30720
)

excludeArgs=(
  --one-file-system
  --exclude-caches
  --exclude '**/lost+found'
  --exclude '**/*nobackup*'
  --exclude '**/.*cache*'
  --exclude '**/.*Cache*'
  --exclude '**/*.tmp'
  --exclude '**/*.log'
  --exclude '**/*.LOG'
  --exclude '**/.npm/_*'
  --exclude '**/.drush'
  --exclude '**/drush-backups'
  --exclude '**/sessions/sess_*'
  --exclude '**/.wp-cli'
  --exclude '**/wp-content/*cache*'
  --exclude '**/wp-content/*log*'
  --exclude '**/wp-content/*webp*'
  --exclude '**/wp-content/*backup*'
  --exclude '**/smarty/compile'
  --exclude 'tmp'
  --exclude 'var/tmp'
  --exclude 'root/tmp'
  --exclude 'home*/*/tmp'
  --exclude 'home*/*/downloads'
  --exclude 'home*/*/Downloads'
  --exclude 'var/log'
  --exclude 'var/run'
  --exclude 'var/cache'
  --exclude '**/var/cache'
  --exclude '**/tmp/cache'
  --exclude '**/site/cache'
  --exclude 'var/lib/ntp'
  --exclude 'var/lib/**/sessions/*'
  --exclude 'var/lib/mysql'
  --exclude 'var/lib/postgresql'
  --exclude 'var/lib/postfix/*cache*'
  --exclude 'var/lib/fail2ban/fail2ban.sqlite3'
  --exclude 'var/lib/varnish'
  --exclude 'var/spool/squid'
  --exclude '**/.config/borg/security'
  --exclude '**/.ipfs/data'
)

pruneArgs=(
  --list
  --show-rc
)

pruneKeepArgs=(
  --keep-within   3d
  --keep-last     10
  --keep-hourly   12
  --keep-daily    12
  --keep-weekly   12
  --keep-monthly  12
  --keep-yearly    2
)

# some helpers and error handling:
info() { printf "\n%s %s\n\n" "$( date )" "$*" ; }
trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM

info "Starting backup"

# Backup the most important directories into an archive named after
# the machine this script is currently running on:

borg create 				                      \
	::"${backupPrefix}-{now}"                     \
	"${backupArgs[@]}" "${createArgs[@]}" "${excludeArgs[@]}"

backup_exit=$?

info "Pruning repository"

# Use the `prune` subcommand to maintain 7 daily, 4 weekly and 6 monthly
# archives of THIS machine. The '{hostname}-' prefix is very important to
# limit prune's operation to this machine's archives and not apply to
# other machines' archives also:

borg prune --glob-archives "${backupPrefix}-*" "${pruneArgs[@]}" "${pruneKeepArgs[@]}"

prune_exit=$?

# actually free repo disk space by compacting segments

info "Compacting repository"

borg compact

compact_exit=$?

# use highest exit code as global exit code
global_exit=$(( backup_exit > prune_exit ? backup_exit : prune_exit ))
global_exit=$(( compact_exit > global_exit ? compact_exit : global_exit ))

if [ ${global_exit} -eq 0 ]; then
    info "Backup, Prune, and Compact finished successfully"
elif [ ${global_exit} -eq 1 ]; then
    info "Backup, Prune, and/or Compact finished with warnings"
else
    info "Backup, Prune, and/or Compact finished with errors"
fi

exit ${global_exit}
