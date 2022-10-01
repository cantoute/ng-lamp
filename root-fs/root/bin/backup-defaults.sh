#!/usr/bin/env bash

createArgs=(
  --verbose
  --list
  --stats
  --show-rc
  --filter AME
  --compression auto,zstd,11
  --upload-ratelimit 30000
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

  # Misc
  --exclude '**/.ipfs/data'
  --exclude '**/.bitcoin'
  --exclude '**/downloads'
  --exclude '**/Downloads'

  # Node
  --exclude '**/node_modules'
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


##################################
# Default labels

bb_label_home() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "home" /home "$@"
}

bb_label_home-light() {
  local self="$1" bbArg="$2"; shift 2

  # backupCreate "home" /home --exclude "home/vmail" --exclude "$backupMysqlLocalDir" "$@"
  bb_label_home "$self" "$bbArg" --exclude "home/vmail" --exclude "$backupMysqlLocalDir" "$@"
}

bb_label_home-vmail() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "vmail" /home/vmail "$@"
}

bb_label_sys() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "sys" /etc /usr/local /root "$@"
}

bb_label_var() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "var" /var "$@"
}

bb_label_etc() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "sys" /etc "$@"
}

bb_label_usr-local() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "sys" /usr/local "$@"
}


# Usage
# backup-cron.sh -- mysql:hourly:single:-user_no_backup_%:10 
# would backup all databases matching NOT LIKE 'user_no_backup_%'
# storing in STORE[] with path prefix 'hourly' default in /home/backups/mysql-${hostname}/hourly/
# default STORE=( local  ) /home/backups/mysql-${hostname}
bb_label_mysql() {
  local self="$1" bbArg="$2"; shift 2
  local s="$bbArg"
  local dir=hourly mode=single keepDays=0 db= rc=0
  local backupArgs=() myArgs=()

  [[ -v 'STORE_MYSQL' ]] && (( ${#STORE_MYSQL[@]} > 0 )) && backupArgs+=( --store "${STORE_MYSQL[@]}" )

  [[ "$s" == "" ]] || { # First arg is path prefix
    dir="${s%%:*}"; s=${s#"$dir"}; s=${s#:}

    [[ "$s" == "" ]] || { # arg2: mode all|db|single (single )
      mode="${s%%:*}"; s=${s#"$mode"}; s=${s#:}

      case "$mode" in
        db|single)
          [[ "$s" == "" ]] || {
            db="${s%%:*}"; s=${s#"$db"};s=${s#:}
          }
          ;;
      esac

      [[ "$s" == "" ]] || {
        keepDays="${s%%:*}"; s=${s#"$keepDays"};s=${s#:}

        while [[ "$s" != "" ]]; do
          local s2="${s%%:*}"
          myArgs+=( "$s2" ); s=${s#"$s2"}; s=${s#:}
        done
      }
    }
  }

  (( keepDays > 1 )) || { keepDays=-; info "Warning: keeping minimum 1 day. disabling prune"; rc=$( max 1 $rc ); }
  backupArgs+=(
    --keep-days $keepDays
  )

  case "$mode" in
    all|prune) ;;

    db) # In single mode becomes like Required TODO
      [[ "$db" == "" ]] || myArgs+=( ${db//,/ } )
      ;;
    
    single) # In single mode db becomes like
      [[ "$db" == "" ]] || myArgs+=( --like "$db" )
      [[ -v 'mysqlSingleArgs' ]] && myArgs+=( "${mysqlSingleArgs[@]}" )
      ;;

    *) info "Error: unknown mode: '$mode'"; return 2 ;;
  esac

  backupMysql "${backupArgs[@]}" -- "$dir" "$mode" "${myArgs[@]}" "$@"

  backupMysqlRc=$?

  return $( max $backupMysqlRc $rc )

  # backupBorgMysql "$dir" "$mode" "$@"
}

bb_label_mysql-skip-lock() {
  local self="$1" bbArg="$2"; shift 2

  bb_label_mysql "$self" "$bbArg" --skip-lock-tables
}


#########
# Misc
###

bb_label_sleep() {
  local self="$1" sleep="$2"; shift 2

  [[ "$sleep" == "" ]] && sleep=60

  info "Sleeping ${sleep}s..."

  sleep $sleep
}

bb_label_test() {
  local self="$1" bbArg="$2"; shift 2

  [[ "$bbArg" == "ok" ]] || { return 128; }
}
