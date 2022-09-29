#!/bin/bash

set -u

#################################
# Default values

createArgs=(
  --verbose
  --list
  --stats
  --show-rc
  --filter AME
  --compression auto,zstd,11
  --upload-ratelimit 30720
)

excludeArgs=(
  --one-file-system                     # Don't backup mounted fs
  --exclude-caches                      # See https://bford.info/cachedir/
  --exclude '**/.config/borg/security'  # creates annoying warnings
  --exclude '**/lost+found'
  --exclude '**/*nobackup*'

  # some commons
  --exclude '**/.*cache*'
  --exclude '**/.*Cache*'
  --exclude '**/*.tmp'
  --exclude '**/*.log'
  --exclude '**/*.LOG'
  --exclude '**/.npm/_*'
  --exclude '**/tmp'
  --exclude 'var/log'
  --exclude 'var/run'
  --exclude 'var/cache'
  --exclude 'var/lib/ntp'
  --exclude 'var/lib/mysql'
  --exclude 'var/lib/postgresql'
  --exclude 'var/lib/postfix/*cache*'
  --exclude 'var/lib/varnish'
  --exclude 'var/spool/squid'
  --exclude '**/site/cache'

  # fail2ban
  --exclude 'var/lib/fail2ban/fail2ban.sqlite3'
  
  # php
  --exclude 'var/lib/**/sessions/*'
  --exclude '**/sessions/sess_*'
  --exclude '**/smarty/compile'

  # Drupal
  --exclude '**/.drush'
  --exclude '**/drush-backups'

  # WordPress
  --exclude '**/.wp-cli'
  --exclude '**/wp-content/*cache*'
  --exclude '**/wp-content/*log*'
  --exclude '**/wp-content/*webp*'
  --exclude '**/wp-content/*backup*'

  # IPFS
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

#################################

SCRIPT_NAME="${0##*/}"
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_DIR="${0%/*}"

source "${SCRIPT_DIR}/backup-common.sh";
init && initUtils

######################

backupLabel="$1"
shift

while (( $# > 0 )); do
  case "$1" in
    --debug)
      DRYRUN=dryRun
      DEBUG=true
      shift
      ;;

    --dry-run)
      createArgs+=(--dry-run)
      pruneArgs+=(--dry-run)
      shift
      ;;

    # --no-nice)
    #   NICE=()
    #   shift
    #   ;;
      
    --)
      shift
      break
      ;;

    *)
      break
      ;;
  esac
done

backupArgs=( "$@" )

[[ -v 'BORG_REPO' ]] && {
  info "Using BORG_REPO: ${BORG_REPO}"
} || {
  info "Warning: BORG_REPO isn't set, loading: ~/.env.borg"

  source ~/.env.borg

  [[ -v 'BORG_REPO' ]] || {
    info "Error: Environnement BORG_REPO isn't set"

    [[ "${DEBUG-}" == "" ]] && {
      exit 2
    } || {
      info "DRYRUN: proceed anyway"
    }
  }
}

backupPrefix="{hostname}-${backupLabel}"


info "Starting backup"

# Backup 

$DRYRUN "${BORG[@]}" create ::"${backupPrefix}-{now}" \
	"${backupArgs[@]}" "${createArgs[@]}" "${excludeArgs[@]}"

borgCreateRc=$?

info "Pruning repository"

# Use the `prune` subcommand to maintain 7 daily, 4 weekly and 6 monthly
# archives of THIS machine. The '{hostname}-' prefix is very important to
# limit prune's operation to this machine's archives and not apply to
# other machines' archives also:

$DRYRUN "${BORG[@]}" prune --glob-archives "${backupPrefix}-*" "${pruneArgs[@]}" "${pruneKeepArgs[@]}"

borgPruneRc=$?

# actually free repo disk space by compacting segments

info "Compacting repository"

$DRYRUN "${BORG[@]}" compact

borgCompactRc=$?

# use highest exit code as global exit code
globalRc=$(( borgCreateRc > borgPruneRc ? borgCreateRc : borgPruneRc ))
globalRc=$(( borgCompactRc > globalRc ? borgCompactRc : globalRc ))

if [ ${globalRc} -eq 0 ]; then
  info "Backup, Prune, and Compact finished successfully"
elif [ ${globalRc} -eq 1 ]; then
  info "Backup, Prune, and/or Compact finished with warnings"
else
  info "Backup, Prune, and/or Compact finished with errors"
fi

exit ${globalRc}
