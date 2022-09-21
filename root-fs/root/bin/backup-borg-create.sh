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
  --one-file-system # Don't backup mounted fs
  --exclude-caches # See https://bford.info/cachedir/
  --exclude '**/.config/borg/security' # creates annoying warnings
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

NICE=()
# auto nice
command -v nice >/dev/null 2>&1 && NICE+=(nice)
command -v ionice >/dev/null 2>&1 && NICE+=(ionice -c3)

BORG=(borg)

#export BORG_REPO=
#export BORG_PASSPHRASE=
DRYRUN=
dryRun() { 
  # echo "DRYRUN:" "${@@Q}";
  echo "DRYRUN:" "$@";
}

borg() { 
  # echo "DRYRUN:" "${@@Q}";
  echo "DRYRUN:" "$@";
}

# some helpers and error handling:
info() { printf "\n%s %s\n\n" "$( date )" "$*" ; }
trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM

######################

backupLabel="$1"
shift

while [[ $# > 0 ]]; do
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

    --no-nice)
      NICE=()
      shift
      ;;
      
    --)
      shift
      break
      ;;

    *)
      break
      ;;
  esac
done

backupArgs=("$@")

[[ -v 'BORG_REPO' ]] && {
  echo "BORG_REPO: ${BORG_REPO}"
} || {
  echo "Warning: BORG_REPO isn't set"
  echo "Loading: ~/.env.borg"

  source ~/.env.borg

  [[ -v 'BORG_REPO' ]] || {
    echo "Error: Environnement BORG_REPO isn't set"

    [[ "${DEBUG-}" == "" ]] && {
      exit 2
    } || {
      echo "DRYRUN: proceed anyway"
    }
  }
}

backupPrefix="{hostname}-${backupLabel}"


info "Starting backup"

# Backup 

$DRYRUN ${NICE[@]} ${BORG[@]} create ::"${backupPrefix}-{now}" \
	"${backupArgs[@]}" "${createArgs[@]}" "${excludeArgs[@]}"

borgCreateRc=$?

info "Pruning repository"

# Use the `prune` subcommand to maintain 7 daily, 4 weekly and 6 monthly
# archives of THIS machine. The '{hostname}-' prefix is very important to
# limit prune's operation to this machine's archives and not apply to
# other machines' archives also:

$DRYRUN ${NICE[@]} ${BORG[@]} prune --glob-archives "${backupPrefix}-*" "${pruneArgs[@]}" "${pruneKeepArgs[@]}"

borgPruneRc=$?

# actually free repo disk space by compacting segments

info "Compacting repository"

$DRYRUN ${NICE[@]} ${BORG[@]} compact

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
