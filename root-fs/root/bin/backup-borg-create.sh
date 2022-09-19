#!/bin/bash

set -u

backupName="$1"
shift

backupArgs="$@"

# so we can override default repo
# [[ "$BORG_REPO" == "" ]] && {
#   source ~/.env.borg
# }

[[ -v BORG_REPO ]] && {
  echo "BORG_REPO: ${BORG_REPO}"
}

# Setting this, so the repo does not need to be given on the commandline:
#export BORG_REPO=

# See the section "Passphrase notes" for more infos.
#export BORG_PASSPHRASE=

prefix="{hostname}-${backupName}"

createArgs=

createArgs+=" --verbose"
createArgs+=" --list"
createArgs+=" --stats"
createArgs+=" --show-rc"

createArgs+=" --filter AME"
#createArgs+=" --compression lz4"
createArgs+=" --compression auto,zstd,11"

createArgs+=" --upload-ratelimit 30720" # in kiByte/s (30720 = 30Mo/s)
createArgs+=" --upload-buffer 50" # in Mo

#createArgs+=" "

# some helpers and error handling:
info() { printf "\n%s %s\n\n" "$( date )" "$*" ; }
trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM

info "Starting backup"

# Backup the most important directories into an archive named after
# the machine this script is currently running on:

borg create 				                      \
	::"${prefix}-{now}"                     \
	${backupArgs}                           \
	${createArgs}                           \
  --one-file-system                       \
  --exclude-caches                        \
  --exclude '**/lost+found'               \
  --exclude '**/*nobackup*'               \
  --exclude 'root/tmp'                    \
  --exclude 'home*/*/tmp'                 \
  --exclude 'home*/*/downloads'           \
  --exclude 'home*/*/Downloads'           \
  --exclude '**/.*cache*'                 \
  --exclude '**/.*Cache*'                 \
  --exclude '**/*.tmp'                    \
  --exclude '**/*.log'                    \
  --exclude '**/*.LOG'                    \
  --exclude '**/.npm/_*'                  \
  --exclude '**/.drush'                   \
  --exclude '**/drush-backups'            \
  --exclude '**/sessions/sess_*'          \
  --exclude '**/.wp-cli'                  \
  --exclude '**/wp-content/*cache*'       \
  --exclude '**/wp-content/*log*'         \
  --exclude '**/wp-content/*webp*'        \
  --exclude '**/wp-content/*backup*'      \
  --exclude '**/smarty/compile/*'         \
  --exclude 'var/tmp/*'                   \
  --exclude 'var/log/*'                   \
  --exclude 'var/run/*'                   \
  --exclude 'var/cache/*'                 \
  --exclude '**/var/cache/*'              \
  --exclude '**/tmp/cache/*'              \
  --exclude '**/site/cache/*'             \
  --exclude 'var/lib/ntp/*'               \
  --exclude 'var/lib/**/sessions/*'       \
  --exclude 'var/lib/mysql/*'             \
  --exclude 'var/lib/postgresql/*'        \
  --exclude 'var/lib/varnish/varnishd/*'  \
  --exclude 'var/lib/postfix/*cache*'     \
  --exclude 'var/lib/fail2ban/fail2ban.sqlite3' \
  --exclude 'var/lib/varnish'             \
  --exclude 'var/spool/squid'             \
  --exclude '**/.ipfs/data'


backup_exit=$?

info "Pruning repository"

# Use the `prune` subcommand to maintain 7 daily, 4 weekly and 6 monthly
# archives of THIS machine. The '{hostname}-' prefix is very important to
# limit prune's operation to this machine's archives and not apply to
# other machines' archives also:

pruneArgs=
pruneArgs+=' --list'
pruneArgs+=' --show-rc'
pruneArgs+=' --keep-within   3d'
pruneArgs+=' --keep-last     2'
pruneArgs+=' --keep-hourly   12'
pruneArgs+=' --keep-daily    12'
pruneArgs+=' --keep-weekly   12'
pruneArgs+=' --keep-monthly  12'
pruneArgs+=' --keep-yearly    2'

borg prune --glob-archives "${prefix}-*" ${pruneArgs}

# borg prune                        \
#   --list                          \
#   --glob-archives "${prefix}-*"   \
#   --show-rc                       \
#   --keep-within   3d              \
#   --keep-last     2               \
#   --keep-hourly   12              \
#   --keep-daily    12              \
#   --keep-weekly   12              \
#   --keep-monthly  12              \

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

