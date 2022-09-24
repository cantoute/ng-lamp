#!/bin/bash


##################################
# Default labels


bb_label_home() {
  local self="$1"
  local bbArg="$2"
  shift 2

  doBorgCreate "home" /home --exclude "home/vmail" --exclude "$backupMysqlLocalDir" "$@"
}

bb_label_home_no-exclude() {
  doBorgCreate "home" /home "$@"
  return $?
}

bb_label_home_vmail() {
  local self="$1"
  local bbArg="$2"
  shift 2

  doBorgCreate "vmail" /home/vmail "$@"
}

bb_label_sys() {
  local self="$1"
  local bbArg="$2"
  shift 2

  doBorgCreate "sys" /etc /usr/local /root "$@"
}

bb_label_etc() {
  local self="$1"
  local bbArg="$2"
  shift 2

  doBorgCreate "sys" /etc "$@"
}

bb_label_usr-local() {
  local self="$1"
  local bbArg="$2"
  shift 2

  doBorgCreate "sys" /usr/local "$@"
}

bb_label_var() {
  local self="$1"
  local bbArg="$2"
  shift 2

  doBorgCreate "var" /var --exclude 'var/www/vhosts' "$@"
}

bb_label_mysql() {
  local self="$1"
  local bbArg="$2"
  shift 2

  local args=()

  case "${bbArg}" in
    all|full|'')
      ;;

    single)
      # mysql:single
      args+=( --single "${backupMysqlSingleArgs[@]}" )
      ;;
    
    *)
      info "Error: unknown argument: '$self:$bbArg'"
      return 2
      ;;
  esac

  backupMysqlAndBorgCreate "${args[@]}" "$@"

  return $?
}

bb_label_sleep() {
  local sleep=$2
  shift 2

  [[ "$sleep" == "" ]] && sleep=60

  info "Sleeping ${sleep}s..."

  sleep $sleep
  
  return $?
}

bb_label_test() {
  local self="$1"
  local bbArg="$2"
  shift 2

  # [[ -v 2 ]] && {
  #   [[ "$2" == "ok" || "$2" == "" ]] && return 0 || return 128
  # } || return 0

  [[ "$bbArg" == "ok" ]] && {
    return 0
  } || {
    return 128
  } 


  # [[  ! -v 2 || (-v 2 && ("$2" == "ok" || "$2" == ""))  ]] && {
  #   return 0
  # } || return 128
}


# error handling: (Ctrl-C)

# trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM
