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

  local args=()

  case "${bbArg}" in
    all|full|'') ;;

    single) # mysql:single
      args+=( single "${backupBorgMysqlSingleArgs[@]}" )
      ;;
    
    *) info "Error: unknown argument: '$self:$bbArg'"; return 2 ;;
  esac

  backupBorgMysql "${args[@]}" "$@"
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
