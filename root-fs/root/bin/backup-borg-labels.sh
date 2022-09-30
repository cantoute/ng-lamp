#!/bin/bash


##################################
# Default labels


bb_label_home() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "home" /home --exclude "home/vmail" --exclude "$backupMysqlLocalDir" "$@"
}

bb_label_home_no-exclude() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "home" /home "$@"
}

bb_label_home_vmail() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "vmail" /home/vmail "$@"
}

bb_label_sys() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "sys" /etc /usr/local /root "$@"
}

bb_label_etc() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "sys" /etc "$@"
}

bb_label_usr-local() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "sys" /usr/local "$@"
}

bb_label_var() {
  local self="$1" bbArg="$2"; shift 2

  backupCreate "var" /var --exclude 'var/www/vhosts' "$@"
}

bb_label_mysql() {
  local self="$1" bbArg="$2"; shift 2
  local s="$bbArg"
  local dir=hourly mode=single keepDays=10 db= rc=0

  [[ "$s" == "" ]] || {
    dir="${s%%:*}"; s=${s#"$dir"}; s=${s#:}

    [[ "$s" == "" ]] || {
      mode="${s%%:*}"; s=${s#"$mode"}; s=${s#:}

      [[ "$s" == "" ]] || {
        keepDays="${s%%:*}"; s=${s#"$keepDays"};s=${s#:}
        [[ "$s" == "" ]] || {
          db="${s%%:*}"; s=${s#"$db"};s=${s#:}
        }
      }
    }
  }


  (( $keepDays > 1 || $keepDays == -1 )) || { keepDays=1; info "Warning: keeping minimum 1 day"; rc=$( max 1 $rc ); }

  local backupArgs=( --keep-days $keepDays )
  local myArgs=()

  case "$mode" in
    all|prune) ;;

    db) # In single mode becomes like Required TODO
      [[ "$db" == "" ]] || myArgs+=( ${db//,/ } )
      ;;
    
    single) # In single mode db becomes like
      [[ "$db" == "" ]] || myArgs+=( --like "$db" )
      ;;

    *) info "Error: unknown mode: '$mode'"; return 2 ;;
  esac

  backupMysql "${backupArgs[@]}" -- "$dir" "$mode" "${myArgs[@]}" "$@"

  backupMysqlRc=$?

  return $( max $backupMysqlRc $rc )

  # backupBorgMysql "$dir" "$mode" "$@"
}

bb_label_sleep() {
  local sleep=$2
  shift 2

  [[ "$sleep" == "" ]] && sleep=60

  info "Sleeping ${sleep}s..."

  sleep $sleep
}

bb_label_test() {
  local self="$1" bbArg="$2"; shift 2

  [[ "$bbArg" == "ok" ]] || { return 128; }
}
