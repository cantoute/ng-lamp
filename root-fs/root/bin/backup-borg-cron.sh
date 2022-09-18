#!/bin/bash
#!/usr/bin/env bash
# had some cases where second line would not work in cron (old debian)

set -u
set -o pipefail

umask 027
# LANG="en_US.UTF-8"

# your email@some.co
alertEmail="alert"

hostname=$(hostname -s)

logFile="/var/log/backup-borg.log"
logrotateConf="/etc/logrotate.d/backup-borg"

borgCreate="/root/bin/backup-borg.sh"
mysqldump="/root/bin/backup-mysql.sh --bz2"
mysqldumpBaseDir="/home/backups/mysql-${hostname}"

NICE="nice ionice -c3"

dotEnv=~/.env.borg
localConf="$0-local.sh"
# localConf=~/projects/ng-lamp/ng-lamp/root-fs/root/bin/backup-borg-cron-serv01.sh


globalExit=
onErrorStop=
doLogrotateCreate=
doInit=
DRYRUN=
NICE=

borgCreateArgs=
mysqldumpArgs=


# Debug
# logFile="/tmp/backup-borg.log2"
# logrotateConf="/tmp/backup-borg4"
# NICE=""
# DRYRUN="dryRun"

doBackup() {
  local exitStatus=0
  local thisStatus=0
  local label
  local split

  for label in "$@"
  do
    case "$label" in

      --)
        shift

        break
        ;;

      --*:*)
        shift

        info "local backup hook '${label}'"

        # removes first 2 chars and splits :
        split=(${label:2//\:/ })

        bb_hook_${split[0]} "${split[0]}" "${split[1]}"

        thisStatus=$?
        exitStatus=$(max2 "$thisStatus" "$exitStatus")
        ;;

      --*)
        shift

        bb_hook_${label:2}

        thisStatus=$?
        exitStatus=$(max2 "$thisStatus" "$exitStatus")
        ;;

      *:*)
        shift

        info "local backup label '${label}'"

        # splits :
        split=(${label//\:/ })

        bb_label_${split[0]} "${split[0]}" "${split[1]}"

        thisStatus=$?
        exitStatus=$(max2 "$thisStatus" "$exitStatus")
        ;;

      *)

        shift


        bb_label_${label}

        thisStatus=$?
        exitStatus=$(max2 "$thisStatus" "$exitStatus")
        ;;
    esac

    if [[ 0 != $thisStatus ]];
    then
      info "Error: backup labeled '${label}' returned status ${thisStatus}"

      [[ "true" == "$onErrorStop" ]] && {
        echo "We stop here (--on-error-stop invoked)"

        break
      }
    fi
  done

  return $exitStatus
}

mysqldumpAndBorgCreate() {
  local thisStatus=
  local exitStatus=0

  local args="$@"

  # [[ ]]

  doMysqldump "$@" $mysqldumpArgs

  thisStatus=$?
  exitStatus=$(max2 "$thisStatus" "$exitStatus")

  [[ "$thisStatus" == 0 ]] || info "${label}:mysqldump returned status: ${thisStatus}"

  # of course we upload backup even if dump returned errors
  doBorgCreate "mysql" "$mysqldumpBaseDir"
  
  thisStatus=$?
  exitStatus=$(max2 "$thisStatus" "$exitStatus")

  [[ "$thisStatus" == 0 ]] || info "${label}:borgCreate returned status: ${thisStatus}"

  return $exitStatus
}

createLogrotate() {
  if [[ ! -e "$logrotateConf" ]];
  then
    local now=$(date)
    local conf="
# created by $0 on $now

${logFile} {
  daily
  delaycompress
  rotate 14
  compress
  notifempty
  # generate an error on missing
  # 24h without any logs is not normal
  nocreate
  nomissingok #default
  errors ${alertEmail}
}
"

    if [[ "$DRYRUN" == "" || "$doLogrotateCreate" == "true" ]];
    then 
      info "Creating ${logrotateConf}"
      printf "%s" "$conf" > "$logrotateConf"
      local exitStatus=$?

      return $exitStatus
    else
      echo "DryRun: not creating file ${logrotateConf}"
      echo "${conf}"
    fi
  fi
}

max() {
  local numbers="$@"
  local max="`printf "%d\n" "${numbers[@]}" | sort -rn | head -1`"

  printf '%d' "$max"
}

max2() {
  printf '%d' $(( "$1" > "$2" ? "$1" : "$2" ))
}

doBorgCreate() {
  $DRYRUN $NICE $borgCreate "$@" $borgCreateArgs
  return $?
}

doMysqldump() {
  $DRYRUN $NICE $mysqldump "$@"
  return $?
}

info() { printf "\n%s %s\n\n" "$( date )" "$*" >&2; }

dryRun() {
  echo "DRYRUN: $@"
}

loadDotEnv() {
  source "$dotEnv" 
}

subRepo() {
  local repoSuffix="$1"
  shift

  local exitStatus=

  # Load defaults
  loadDotEnv

  # append repoSuffix to default repo
  setRepo "${BORG_REPO}-${repoSuffix}" "$BORG_PASSPHRASE" "$@"

  exitStatus=$?

  return $exitStatus
}

setRepo() {
  case "$1" in
    --dot-env)
      loadDotEnv
      shift
      ;;
    *)
      BORG_REPO="$1"
      BORG_PASSPHRASE="$2"
      shift 2
      ;;
  esac

  export BORG_REPO
  export BORG_PASSPHRASE

  echo "Info: set BORG_REPO: ${BORG_REPO}"

  "$@"

  exitStatus=$?

  # unset
  export BORG_REPO=
  export BORG_PASSPHRASE=

  return $exitStatus
}

swapRepo() {
  local repo="$1"
  local pass="$2"
  shift 2

  local exitStatus=

  local BORG_REPO_SWITCHED="${BORG_REPO-unset}"
  local BORG_PASSPHRASE_SWITCHED="${BORG_PASSPHRASE-unset}"

  export BORG_REPO="${repo}"
  export BORG_PASSPHRASE="${pass}"
  
  # do
  "$@"

  exitStatus=$?


  [[ "${BORG_REPO_SWITCHED}" != "${BORG_REPO}" ]] && {
    [[ "$BORG_REPO_SWITCHED" == "unset" ]] && {
      export BORG_REPO=
      echo "Info: cleared BORG_REPO"
    } || {
      export BORG_REPO="$BORG_REPO_SWITCHED"
      echo "Info: restored BORG_REPO: ${BORG_REPO}"
    }
  }

  [[ "${BORG_PASSPHRASE_SWITCHED}" != "${BORG_PASSPHRASE}" ]] && {
    [[ "$BORG_PASSPHRASE_SWITCHED" == "unset" ]] && {
      export BORG_PASSPHRASE=
      echo "Info: cleared BORG_PASSPHRASE"
    } || {
      export BORG_REPO="$BORG_PASSPHRASE_SWITCHED"
      echo "Info: restored BORG_PASSPHRASE"
    }
  }

  return $exitStatus
}
##################################
# Default labels

bb_label_sys() {
 doBorgCreate "$label" /etc /usr/local /root "$@"
 return $?
}

bb_label_home() {
  doBorgCreate "home" /home --exclude "home/vmail" --exclude "$mysqldumpBaseDir" "$@"
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

bb_label_sys_no-var() {
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
  local single=

  [[ "$2" == "single" ]] && single='--single'
  shift 2

  mysqldumpAndBorgCreate $single "$@"
  return $?
}

bb_label_sleep() {
  local sleep=$2

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

trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM


###################################################
# Main

while true;
do
  case "$1" in
    --dry-run)
      DRYRUN="dryRun"
      borgCreateArgs+=" --dry-run"
      mysqldumpArgs+=" --dry-run"
      shift
      ;;
    --verbose|--progress)
      borgCreateArgs+=" $1"
      shift
      ;;
    --borg-dry-run)
      borgCreateArgs+=" --dry-run"
      shift
      ;;
    --on-error-stop|--stop)
      onErrorStop="true"
      shift
      ;;
    --do-init|--init)
      doInit="true"
      shift
      ;;
    --log-file|--log)
      logFile="$2"
      shift 2
      ;;
    --local-conf|--local)

      localConf="$2"
      shift 2
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

# createLogrotate || {
#   info "Warning: failed to create logrotate ${logrotateConf}"
# }

[[ -f "$localConf" ]] && {
  source "$localConf"

  echo "Info: loaded local config ${localConf}"
}

doBackup "$@" 2>&1 | $NICE tee -a "$logFile"

globalExit=$?

exit $globalExit
