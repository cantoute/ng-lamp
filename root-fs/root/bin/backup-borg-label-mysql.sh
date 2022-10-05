#!/usr/bin/env bash

# backupMysqlLocalDir=
backupMysqlArgs=() # Always appended
backupMysqlAllArgs=() # Applies only for mode 'all'
backupMysqlDbArgs=()
backupMysqlSingleArgs=() # Args that only apply for single mode
backupMysqlPruneArgs=( --keep-days 10 )

# Set in backup-common.sh
# Best to set it in backup-$hostname.sh
[[ -v 'backupMysqlLocalDir' ]]  || backupMysqlLocalDir="/home/backups/${hostname}-mysql"

[[ -v 'BACKUP_MYSQL' ]] || BACKUP_MYSQL=( "${SCRIPT_DIR}/backup-mysql.sh" )
# [[ -v 'BACKUP_MYSQL_STORE' ]] || {
#   [[ -v 'backupMysqlLocalDir' ]] && BACKUP_MYSQL_STORE="local:$backupMysqlLocalDir"
# }

##################################

# backup-cron.sh -- mysql:hourly:single:-user_no_backup_%:10
# would backup all databases matching NOT LIKE 'user_no_backup_%'
# storing in BACKUP_MYSQL_STORE with path prefix 'hourly' default in /home/backups/${hostname}-mysql/hourly/
# default BACKUP_MYSQL_STORE=local:/home/backups/${hostname}-mysql
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

# Usage mysql-store:BACKUP_MYSQL_STORE_antony:daily:single:antony%:10
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
        info "Error:  ${FUNCNAME[0]}: no database to backup: db:'$db'"
        rc=$( max 2 $rc ) # Error
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

########################
# Label my-user
#######

bb_label_my-user() {
  local self="$1" bbArg="$2"; shift 2
  local IFS user users repo s="$bbArg" rc=0 mysqlRc myStore dir keep like # subMode

  # Processing bbArg user:dir:keep
  user="${s%%:*}"; s=${s#"$user"}; s=${s#:}
  [[ "$user" == "" ]] && { info "Error: $self:$bbArg param1(user) is required"; return 2; }

  dir="${s%%:*}"; s=${s#"$dir"}; s=${s#:}
  keep="${s%%:*}"; s=${s#"$keep"}; s=${s#:}

  IFS=,
  users=( $user )
  unset IFS

  # Backup in loop all mysql users databases to then later backup all their home directories
  for user in "${users[@]}"; do
    # trying env BACKUP_MYSQL_STORE_$user STORE_$user or creates a local store in user ~/backup-mysql
    [[ -v "BACKUP_MYSQL_STORE_${user//-/_}" ]] && myStore="BACKUP_MYSQL_STORE_${user//-/_}" || {
      [[ -v "STORE_${user//-/_}" ]] && myStore="STORE_${user//-/_}" || {
        BACKUP_MYSQL_STORE_userHome="local:$( getUserHome "$user" )/backup-mysql"
        myStore="BACKUP_MYSQL_STORE_userHome"
      }
    }

    like="${user}_%"

    # Backup mysql via label mysql-store
    bb_label_mysql-store "$self" "${myStore}:${dir}:single:${like}:${keep}" "$@"

    mysqlRc=$?
    rc=$( max $mysqlRc $rc )

    [[ "$myStore" == 'BACKUP_MYSQL_STORE_userHome' ]] && unset "$myStore"
  done

    # Backup user via label user
  bb_label_user "user" "$( joinBy , "${users[@]}" )"

  userRc=$?
  rc=$( max $userRc $rc )


  [[ -v 'rc' ]] || {
    info "Error: Didn't backup any user. : ${FUNCNAME[0]} $@"
    rc=2
  }

  return $rc
}

bb_label_my-user-skip-lock() {
  local self="$1" bbArg="$2"; shift 2

  bb_label_my-user "$self" "$bbArg" "$@" --skip-lock-tables
}


# Calls script backup-mysql using 
backupMysql() {
  local rc db=() dir="$1" mode="$2"; shift 2
  
  [[ -v 'backupMysqlArgs' ]] && set -- "${backupMysqlArgs[@]}" "$@"

  case "$mode" in
    all)
      [[ -v 'backupMysqlAllArgs'   ]] && set -- "${backupMysqlAllArgs[@]}"   "$@"
      [[ -v 'backupMysqlArgs'      ]] && set -- "${backupMysqlArgs[@]}"      "$@"
      ;;

    prune)
      [[ -v 'backupMysqlPruneArgs' ]] && set -- "${backupMysqlPruneArgs[@]}" "$@"
      [[ -v 'backupMysqlArgs'      ]] && set -- "${backupMysqlArgs[@]}"      "$@"
      ;;

    db)
      while (( $# > 0 )); do
        case "$1" in
          -*) break ;;
           *) db+=( "$1" ); shift ;;
        esac
      done

      (( ${#db[@]} > 0 )) || { info "Error: ${FUNCNAME[0]}: mode 'db' requires database names to backup. None was given"; return 2; }
      
      [[ -v 'backupMysqlDbArgs' ]] && set -- "${backupMysqlDbArgs[@]}" "$@"
      [[ -v 'backupMysqlArgs'   ]] && set -- "${backupMysqlArgs[@]}"   "$@"

      set -- "${db[@]}" "$@" # Db has to come as fist args
      ;;
    
    single)
      [[ -v 'backupMysqlSingleArgs' ]] && set -- "${backupMysqlSingleArgs[@]}" "$@"
      [[ -v 'backupMysqlArgs'       ]] && set -- "${backupMysqlArgs[@]}"       "$@"
      ;;

    *) info "Error: unknown mode: '$mode'"; return 2 ;;
  esac

  set -- "${BACKUP_MYSQL[@]}" "$dir" "$mode" "$@"

  info "Info: Starting ${FUNCNAME[0]} $@"

  $DRYRUN "$@";
  rc=$?

  (( rc == 0 )) && info "Success: ${FUNCNAME[0]} succeeded"
  (( rc == 1 )) && info "Warning: ${FUNCNAME[0]} returned warnings rc $rc"
  (( rc >  1 )) && info "Error: ${FUNCNAME[0]} returned rc $rc"

  return $rc
}