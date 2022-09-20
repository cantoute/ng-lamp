#!/bin/bash
#!/usr/bin/env bash
# had some cases where second line would not work in cron (old debian)

set -u
set -o pipefail

LC_ALL=C

umask 027
# LANG="en_US.UTF-8"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# your email@some.co
alertEmail="alert"

hostname=$(hostname -s)

logFile="/var/log/backup-borg.log"
logrotateConf="/etc/logrotate.d/backup-borg"

BORG_CREATE=("${SCRIPT_DIR}/backup-borg-create.sh")
MYSQLDUMP=("${SCRIPT_DIR}/backup-mysql.sh" "--bz2")
mysqldumpBaseDir="/home/backups/mysql-${hostname}"


localConf="${SCRIPT_DIR}/${0%.*}-${hostname}.sh"

globalExit=
onErrorStop=
doLogrotateCreate=
doInit=

DRYRUN=()

# command -v foo >/dev/null 2>&1 || { echo >&2 "I require foo but it's not installed.  Aborting."; exit 1; }

NICE=()
command -v nice >/dev/null 2>&1 && NICE+=(nice)
command -v ionice >/dev/null 2>&1 && NICE+=(ionice -c3)
#
# NICE=(nice ionice -c3)

borgCreateArgs=()
mysqldumpArgs=()

# Debug
# logFile="/tmp/backup-borg.log2"
# logrotateConf="/tmp/backup-borg4"
# NICE=""
# DRYRUN="dryRun"

while [[ $# > 0 ]]
do
  case "$1" in
    --nice)
      NICE+=(nice)
      shift
      ;;

    --io-nice)
      NICE+=(ionice -c3)
      shift
      ;;

    --dry-run)
      DRYRUN+=(dryRun)
      
      borgCreateArgs+=(--dry-run)
      mysqldumpArgs+=(--dry-run)

      shift
      ;;

    --borg-dry-run)
      # borgCreateArgs+=(--dry-run)
      # pushing it as first arg, seemed safer but brakes access to $bbLabel as $2 in wrappers (shifting)
      BORG_CREATE+=(--dry-run)

      shift
      ;;

    --mysqldump-dry-run|--mysql-dry-run)
      mysqldumpArgs+=(--dry-run)
      shift
      ;;

    --verbose)
      borgCreateArgs+=("$1")
      shift
      ;;

    --progress)
      borgCreateArgs+=("$1")
      shift
      ;;

    --exclude|--include)
      borgCreateArgs+=("$1" "$2")
      shift 2
      ;;

    --on-error-stop|--stop)
      onErrorStop="true"
      shift
      ;;

    --do-init|--init)
      doInit="true"
      shift
      ;;

    --log)
      logFile="$2"
      shift 2
      ;;

    --conf)
      localConf="$2"
      shift 2
      ;;

    --)
      shift
      break
      ;;

    *)
      info "Error: unknown argument '$1'"
      exit 1
      ;;

    # *)
    #   # not sure this is smart... as misspelled args here could be tricky to debug
    #   break
    #   ;;
  esac
done

##############################################

doBorgCreateWrapped() {
  # never call directly, only via doBorgCreate
  "${DRYRUN[@]}" "${NICE[@]}" "${BORG_CREATE[@]}" "$@"
  return $?
}

#debug
# bb_borg_create_wrapper() {
#   "$@" --exclude '**/node_modules'
#   return $?
# }

# bb_borg_create_wrapper_home() {
#   "$@" --exclude '**/node_modules_home'
#   return $?
# }

# bb_borg_create_wrapper_dell-aio() {
#   local args=(
#     --compression auto,zstd,11
#     --upload-ratelimit 30720  # ~25Mo/s
#     --upload-buffer 50        # 50Mo
#   )

#   "$@" "${args[@]}"
# }

# bb_label_dabao-home() {

#   local args=("$@")
  
#   args+=(
#     --exclude 'home/postgresql/data'
#     --exclude 'home/backups/mysql-dabao'
#     --exclude 'home/bmag' 
#   )

#   # backup home in a separate repo dabao-home
#   doBorgCreate      \
#     "home" /home    \
#     "${args[@]}"

#   local rs=$?

#   return $rs
# }

doBorgCreate() {
  local rs
  local wrapper
  local wrappers=()
  local label="$1"

  local bbWrappers=(
    "bb_borg_create_wrapper"
    "bb_borg_create_wrapper_${label}"
    "bb_borg_create_wrapper_${hostname}"
    "bb_borg_create_wrapper_${hostname}_${label}"
  )

  for wrapper in "${bbWrappers[@]}"; do
    [[ "$(LC_ALL=C type -t "$wrapper")" == "function" ]] && {
      wrappers+=("$wrapper")
    }
  done

  "${wrappers[@]}" doBorgCreateWrapped "$@" "${borgCreateArgs[@]}"

  rs=$?

  return $rs
}

doMysqldump() {
  "${DRYRUN[@]}" "${NICE[@]}" "${MYSQLDUMP[@]}" "$@"
  return $?
}

info() { printf "\n%s %s\n\n" "$( date )" "$*" >&2; }

# returns max of two numbers
max2() { printf '%d' $(( $1 > $2 ? $1 : $2 )); }

dryRun() {
  echo "DRYRUN:" "$@"
}

loadDotEnv() {
  source "$dotEnv" 
}

##############################################
# global
label=

doBackup() {
  local exitStatus=0
  local thisStatus=0
  local split

  while [[ $# > 0 ]]
  do
    case "$1" in
      --)
        shift
        break
        ;;

      --*:*)
        info "local backup hook '${1}'"

        # removes first 2 chars and splits :
        split=(${1:2//\:/ })

        bb_hook_${split[0]} "${split[0]}" "${split[1]}"

        thisStatus=$?
        exitStatus=$(max2 "$thisStatus" "$exitStatus")

        shift
        ;;

      --*)

        bb_hook_${label:2}

        thisStatus=$?
        exitStatus=$(max2 "$thisStatus" "$exitStatus")

        shift
        ;;

      *:*)
        label="$1"
        shift

        info "local backup label '${label}'"

        # splits :
        split=(${label//\:/ })

        bb_label_${split[0]} "${split[0]}" "${split[1]}"

        thisStatus=$?
        exitStatus=$(max2 "$thisStatus" "$exitStatus")
        ;;

      *)
        bbLabel=$1
        bb_label_${bbLabel}

        thisStatus=$?
        exitStatus=$(max2 "$thisStatus" "$exitStatus")

        shift
        ;;
    esac

    if [[ 0 != $thisStatus ]];
    then
      info "Error: backup labeled '${bbLabel}' returned status ${thisStatus}"

      [[ "true" == "$onErrorStop" ]] && {
        echo "We stop here (--on-error-stop invoked)"

        break
      }
    fi
  done

  return $exitStatus
}

mysqldumpAndBorgCreate() {
  local exitStatus=0
  local thisStatus=

  doMysqldump "$@" "${mysqldumpArgs[@]}"

  thisStatus=$?
  exitStatus=$(max2 "$thisStatus" "$exitStatus")

  [[ "$thisStatus" == 0 ]] || info "${bbLabel}:mysqldump returned status: ${thisStatus}"

  # of course we upload backup even if dump returned errors
  doBorgCreate "mysql" "$mysqldumpBaseDir"
  
  thisStatus=$?
  exitStatus=$(max2 "$thisStatus" "$exitStatus")

  [[ "$thisStatus" == 0 ]] || info "${bbLabel}:borgCreate returned status: ${thisStatus}"

  return $exitStatus
}

createLogrotate() {
  local conf="# created by $0 on $(now)"
  conf+="
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
  [[ ${#DRYRUN[@]} == 0 ]] || {
    echo "DryRun: not creating file ${logrotateConf}"
    echo "${conf}"

    return
  }

  if [[ "$doLogrotateCreate" == "true" ]];
  then 
    info "Creating ${logrotateConf}"
    printf "%s" "$conf" > "$logrotateConf"
    local exitStatus=$?

    return $exitStatus
  fi
}

subRepo() {
  local repoSuffix="$1"
  shift

  local exitStatus=

  [[ -v 'BORG_REPO' ]] || {
    info "Error: subRepo requires BORG_REPO"
    return 2
  }

  local BORG_REPO_ORIG="${BORG_REPO}"

  # append repoSuffix to default repo
  export BORG_REPO="${BORG_REPO}-${repoSuffix}"

  "$@"

  exitStatus=$?

  export BORG_REPO="${BORG_REPO_ORIG}"

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
  local args=

  [[ "$2" == "single" ]] && args='--single'
  shift 2

  mysqldumpAndBorgCreate $args "$@"
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

# trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM


###################################################
# Main

[[ -e "$logrotateConf" ]] || {
  createLogrotate || {
    info "Warning: failed to create logrotate ${logrotateConf}"
  }
}

[[ -f "$localConf" ]] && {
  source "$localConf"

  echo "Info: loaded local config ${localConf}"
}

# logTo=("${NICE[@]}")
# logTo+=(
#   tee --output-error=warn -a 
# )
# doBackup "$@" 2>&1 | "${logTo[@]}" "$logFile"

# takes 0 or n filenames where the stdin will be copied to (appended)
logToFile() {
  if [[ $# > 0 ]]
  then
    # assuming all args are names of files we append to
    local file TEE=(tee --output-error=warn)
    for file in "$@"; do TEE+=( -a "$file" ); done

    ## consider `ionice -c3` for disk output niceness
    "${NICE[@]}" "${TEE[@]}"
  else
    # simply pipe stdin to stdout
    cat
  fi
}

doBackup "$@" 2>&1 | logToFile "$logFile"

globalExit=$?

exit $globalExit
