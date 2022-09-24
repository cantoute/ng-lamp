#!/bin/bash


##################################
# Default labels


bb_label_home() {
  doBorgCreate "home" /home --exclude "home/vmail" --exclude "$backupMysqlLocalDir" "$@"
  return $?
}

bb_label_home_no-exclude() {
  doBorgCreate "home" /home "$@"
  return $?
}

bb_label_home_vmail() {
  doBorgCreate "vmail" /home/vmail "$@"
  return $?
}

bb_label_sys() {
  doBorgCreate "sys" /etc /usr/local /root "$@"
  return $?
}

bb_label_etc() {
  doBorgCreate "sys" /etc "$@"
  return $?
}

bb_label_usr-local() {
  doBorgCreate "sys" /usr/local "$@"
  return $?
}

bb_label_var() {
  doBorgCreate "var" /var --exclude 'var/www/vhosts' "$@"
  return $?
}

bb_label_mysql() {
  local self=$1
  shift

  local args=()

  case "${1-default}" in
    single)
      # mysql:single
      args+=( --single )
      shift 1
      ;;

    all|full)
      shift 1
      ;;
  esac

  backupMysqlAndBorgCreate "${args[@]}" "$@"
  return $?
}

bb_label_sleep() {
  local sleep=$2
  shift 2

  echo "Sleeping ${sleep}s..."

  sleep $sleep
  
  return $?
}

bb_label_test() {
  # [[ -v 2 ]] && {
  #   [[ "$2" == "ok" || "$2" == "" ]] && return 0 || return 128
  # } || return 0

  [[ "$2" == "ok" ]] && {
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
