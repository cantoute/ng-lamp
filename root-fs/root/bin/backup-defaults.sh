#!/usr/bin/env bash

[[ -v 'loadDotenv' && "$loadDotenv" == 'true' ]] && {
  tryDotenv=(
    .backup.${hostname}.env
    ~/.backup.${hostname}.env
    /root/.backup.${hostname}.env
    "${SCRIPT_DIR}/.backup.${hostname}.env"
  )
  dotenv "${tryDotenv[@]}" || { info "Failed to load env in: ${tryDotenv[@]}"; exit 2; }
}

# Are set in backup-defaults.sh
# [[ -v 'hostname' ]]             || hostname=$( hostname -s )
# [[ -v 'backupMysqlLocalDir' ]]  || backupMysqlLocalDir="/home/backups/${hostname}-mysql"

BACKUP_MYSQL_STORE="local:$backupMysqlLocalDir"

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

backupMysqlLocalDir=
backupMysqlArgs=() # Always appended
backupMysqlAllArgs=() # Applies only for mode 'all'
backupMysqlDbArgs=()
backupMysqlSingleArgs=() # Args that only apply for single mode
backupMysqlPruneArgs=( --keep-days 10 )

##################################
# Default labels

bb_label_home() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "$self" /home "$@"
}

bb_label_home-users() {
  local self="$1" bbArg="$2"; shift 2

  # backupCreate "home" /home --exclude "home/vmail" --exclude "$backupMysqlLocalDir" "$@"
  bb_label_home "$self" "$bbArg" --exclude "home/vmail" --exclude "$backupMysqlLocalDir" "$@"
}

bb_label_home-vmail() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "$self" /home/vmail "$@"
}

bb_label_sys() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "$self" /etc /usr/local /root "$@"
}

bb_label_var() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "$self" /var "$@"
}

bb_label_etc() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "$self" /etc "$@"
}

bb_label_usr-local() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "$self" /usr/local "$@"
}


# Usage mysql:BACKUP_MYSQL_STORE_antony:daily:single:antony%:10
# backup-cron.sh -- mysql:hourly:single:-user_no_backup_%:10 
# would backup all databases matching NOT LIKE 'user_no_backup_%'
# storing in BACKUP_MYSQL_STORE with path prefix 'hourly' default in /home/backups/${hostname}-mysql/hourly/
# default BACKUP_MYSQL_STORE=local:/home/backups/${hostname}-mysql
bb_label_mysql-store() {
  local self="$1" bbArg="$2"; shift 2
  local s="$bbArg" s2 store dir mode keepDays db dbA=() rc=0
  local args=() labelArgs=()

  store="${s%%:*}"; s=${s#"$store"}; s=${s#:};
  dir="${s%%:*}"; s=${s#"$dir"}; s=${s#:}
  mode="${s%%:*}"; s=${s#"$mode"}; s=${s#:}

  case "$mode" in
    db|single) db="${s%%:*}"; s=${s#"$db"}; s=${s#:} ;;
  esac
  
  keepDays="${s%%:*}"; s=${s#"$keepDays"}; s=${s#:}

  while [[ "$s" != "" ]]; do
    s2="${s%%:*}"
    labelArgs+=( "$s2" ); s=${s#"$s2"}; s=${s#:}
  done

  [[ "$mode" == '' ]] && mode=all

  [[ "$dir" == '' ]] && dir="$mode"

  [[ "$keepDays" == '' ]] && keepDays=10

  args=()
  case "$mode" in
    all|prune) ;;

    db)
      [[ "$db" == "" ]] && {
        info "Warning:  ${FUNCNAME[0]}: empty db: '$db'"
      } || myArgs+=( "$db" )
      ;;
    
    single) # In single mode db becomes like
      [[ "$db" == "" ]] || args+=( --like "$db" )
      ;;
    *) info "Error: unknown mode: '$mode'"; return 2 ;;
  esac

  (( keepDays > 1 )) && {
    args+=(
      --keep-days $keepDays
    )
  } || {
    keepDays=-1; info "Warning: keeping minimum 1 day. disabling prune";
    rc=$( max 1 $rc ); # Warning
  }

  # If store not defined we try to load default
  [[ "$store" == '' ]] && {
    [[ -v 'BACKUP_MYSQL_STORE' ]] && store='BACKUP_MYSQL_STORE' || {
      [[ -v 'STORE' ]] && store='STORE'
    }
  }

  [[ -v 'store' && -v "$store" ]] && _STORE="${!store}"

  [[ -v '_STORE' ]] && { set -- "$@" --store "${_STORE}"; } || {
    info "Error: ${FUNCNAME[0]}: No STORE to use. store='$store'";
  }

  set -- "$dir" "$mode" "${dbA[@]}" "${args[@]}" "$@" "${labelArgs[@]}"

  backupMysql "$@"

  backupMysqlRc=$?
  return $( max $backupMysqlRc $rc )
}

bb_label_mysql() {
  local self="$1" bbArg="$2"; shift 2

  bb_label_mysql-store "$self" ":$bbArg" "$@"
}

bb_label_mysql-skip-lock() {
  bb_label_mysql "$@" --skip-lock-tables
}

bb_label_mysql-store-skip-lock() {
  bb_label_mysql-store "$@" --skip-lock-tables
}


# %user:%repo
bb_label_user() {
  local self="$1" bbArg="$2"; shift 2
  local user repo s="$bbArg" varParts varName

  user="${s%%:*}"; s=${s#"$user"}; s=${s#:};
  [[ "$user" == "" ]] && { info "Error: $self:$bbArg param1(user) is required"; return 2; }

  repo="${s%%:*}"; s=${s#"$repo"}; s=${s#:};

  [[ -v "BORG_REPO_${repo}_${user}" ]] && repo="${repo}_${user}" || {
    [[ -v "BORG_REPO_${user}" ]] && repo="${user}"
  }

  set -- backupCreate "${self}-${user}" "$( getUserHome "$user" )" "$@"

  >&2 echo "$@"

  if [[ -v 'repo' && "$repo" != "" ]]; then
    usingRepo "$repo" "$@"
  else "$@"; fi
}

bb_label_my-user() {
  local self="$1" bbArg="$2"; shift 2
  local user repo s="$bbArg" rc=0 mysqlRc store dir keep subMode

  user="${s%%:*}"; s=${s#"$user"}; s=${s#:}
  [[ "$user" == "" ]] && { info "Error: $self:$bbArg param1(user) is required"; return 2; }

  dir="${s%%:*}"; s=${s#"$dir"}; s=${s#:}
  keep="${s%%:*}"; s=${s#"$keep"}; s=${s#:}

  [[ -v "BACKUP_MYSQL_STORE_${user}" ]] && store="BACKUP_MYSQL_STORE_${user}" || {
    [[ -v "STORE_${user}" ]] && store="STORE_${user}" || {
      BACKUP_MYSQL_STORE_userHome="local:$( getUserHome "$user" )/backup-mysql"
      store="BACKUP_MYSQL_STORE_userHome"
    }
  }

  subMode="${self#my-user}"

  # Allow '-skip-lock' only
  case "$subMode" in
    -skip-lock|'') ;;
    *) subMode=''; info "Warning: ${FUNCNAME[0]}: unknown subMode: '$subMode' self: '$self' bbArg: '$bbArg'" ;;
  esac

  set --  bb_label_mysql-store${self#my-user} "mysql${self#my-user}" "${store}:${dir}:single:${user}%:${keep}" "$@"

  "$@"

  mysqlRc=$?
  rc=$( max $mysqlRc $rc )


  bb_label_user "user" "${user}"
  userRc=$?
  rc=$( max $userRc $rc )

  return $rc
}

bb_label_my-user-skip-lock() {
  local self="$1" bbArg="$2"; shift 2

  bb_label_my-user "$self" "$bbArg" "$@"
}

#########
# Misc
###

bb_label_sleep() {
  local self="$1" sleep="$2"; shift 2

  [[ "$sleep" == '' ]] && sleep=60

  info "Sleeping ${sleep}s..."

  sleep $sleep
}

bb_label_test() {
  local self="$1" bbArg="$2"; shift 2

  [[ "$bbArg" == 'ok' ]] || { return 128; }
}
