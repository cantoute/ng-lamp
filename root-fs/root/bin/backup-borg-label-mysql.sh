#!/usr/bin/env bash


backupMysqlLocalDir=
backupMysqlArgs=() # Always appended
backupMysqlAllArgs=() # Applies only for mode 'all'
backupMysqlDbArgs=()
backupMysqlSingleArgs=() # Args that only apply for single mode
backupMysqlPruneArgs=( --keep-days 10 )

# Set in backup-common.sh
# [[ -v 'backupMysqlLocalDir' ]]  || backupMysqlLocalDir="/home/backups/${hostname}-mysql"

BACKUP_MYSQL_STORE="local:$backupMysqlLocalDir"


# Usage mysql-store:BACKUP_MYSQL_STORE_antony:daily:single:antony%:10
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


########################
# Label my-user
#######

bb_label_my-user() {
  local self="$1" bbArg="$2"; shift 2
  local user repo s="$bbArg" rc=0 mysqlRc store dir keep like # subMode

  user="${s%%:*}"; s=${s#"$user"}; s=${s#:}
  [[ "$user" == "" ]] && { info "Error: $self:$bbArg param1(user) is required"; return 2; }

  dir="${s%%:*}"; s=${s#"$dir"}; s=${s#:}
  keep="${s%%:*}"; s=${s#"$keep"}; s=${s#:}

  [[ -v "BACKUP_MYSQL_STORE_${user//-/_}" ]] && store="BACKUP_MYSQL_STORE_${user//-/_}" || {
    [[ -v "STORE_${user//-/_}" ]] && store="STORE_${user//-/_}" || {
      BACKUP_MYSQL_STORE_userHome="local:$( getUserHome "$user" )/backup-mysql"
      store="BACKUP_MYSQL_STORE_userHome"
    }
  }

  # subMode="${self#my-user}"

  # # Allow '-skip-lock' only
  # case "$subMode" in
  #   -skip-lock|'') ;;
  #   *) subMode=''; info "Info: ${FUNCNAME[0]}: unknown subMode: '$subMode' self: '$self' bbArg: '$bbArg'" ;;
  # esac

  like="${user}_%"

  # Backup mysql via label mysql-store
  bb_label_mysql-store "$self" "${store}:${dir}:single:${like}:${keep}" "$@"

  mysqlRc=$?
  rc=$( max $mysqlRc $rc )

  # Backup user via label user
  bb_label_user "user" "${user}"

  userRc=$?
  rc=$( max $userRc $rc )

  [[ "$store" == 'BACKUP_MYSQL_STORE_userHome' ]] && unset "$store"

  return $rc
}

bb_label_my-user-skip-lock() {
  local self="$1" bbArg="$2"; shift 2

  bb_label_my-user "$self" "$bbArg" "$@" --skip-lock-tables
}
