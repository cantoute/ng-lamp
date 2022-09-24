#!/bin/bash
#!/usr/bin/env bash
# had some cases where second line would not work in cron (old debian)

set -u
set -o pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_DIR="$(dirname -- "$0" )"
SCRIPT_DIR="${0%/*}"

source "${SCRIPT_DIR}/backup-common.sh";
init && initUtils

source "${SCRIPT_DIR}/backup-borg-labels.sh";

loadDotEnv() { source "~/.env.borg"; }

# your email@some.co
# only used for logrotate 
alertEmail="alert"

logFile="/var/log/backup-borg.log"
logrotateConf="/etc/logrotate.d/backup-borg"

BORG_CREATE=( "${SCRIPT_DIR}/backup-borg-create.sh" )
BACKUP_MYSQL=( "${SCRIPT_DIR}/backup-mysql.sh" )


localConf=( "${SCRIPT_DIR}/${SCRIPT_NAME_NO_EXT}-${hostname}.sh" )

exitRc=0
onErrorStop=
doLogrotateCreate=
doInit=

bbLabel=
borgCreateLabel=


borgCreateArgs=()

backupMysqlArgs=()
backupMysqlSingleArgs=()

# Debug
# logFile="/tmp/backup-borg.log2"
# logrotateConf="/tmp/backup-borg4"
# NICE=""
# DRYRUN="dryRun"

while (( $# > 0 )); do
  case "$1" in
    --nice)
      NICE+=( nice )
      shift
      ;;

    --io-nice)
      NICE+=( ionice -c3 )
      shift
      ;;

    --dry-run)
      DRYRUN=dryRun
      
      borgCreateArgs+=( --dry-run )
      backupMysqlArgs+=( --dry-run )

      shift
      ;;

    --borg-dry-run)
      # borgCreateArgs+=(--dry-run)
      # pushing it as first arg, seemed safer but brakes access to $bbLabel as $2 in wrappers (shifting)
      BORG_CREATE+=( --dry-run )

      shift
      ;;

    --mysqldump-dry-run|--mysql-dry-run)
      backupMysqlArgs+=( --dry-run )
      shift
      ;;
    
    --mysql-single-like)
      backupMysqlSingleArgs+=( --like "$2" )
      shift 2
      ;;
    
    --mysql-single-not-like)
      backupMysqlSingleArgs+=( --not-like "$2" )
      shift 2
      ;;

    --verbose)
      borgCreateArgs+=( "$1" )
      shift
      ;;

    --progress)
      borgCreateArgs+=( "$1" )
      shift
      ;;

    --exclude|--include)
      borgCreateArgs+=( "$1" "$2" )
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
      localConf=( "$2" )
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
  $DRYRUN "${NICE[@]}" "${BORG_CREATE[@]}" "$@"
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

#   local args=("$@" )
  
#   args+=(
#     --exclude 'home/postgresql/data'
#     --exclude 'home/backups/mysql-dabao'
#     --exclude 'home/bmag' 
#   )

#   # backup home in a separate repo dabao-home
#   doBorgCreate      \
#     "home" /home    \
#     "${args[@]}"

#   local rc=$?

#   return $rc
# }

doBorgCreate() {
  local rs
  local wrapper
  local wrappers=()
  local label="$1"

  borgCreateLabel="${label}"

  local bbWrappers=(
    "bb_borg_create_wrapper"
    "bb_borg_create_wrapper_${label}"
    "bb_borg_create_wrapper_${hostname}"
    "bb_borg_create_wrapper_${hostname}_${label}"
  )

  for wrapper in "${bbWrappers[@]}"; do
    [[ "$(LC_ALL=C type -t "$wrapper" )" == "function" ]] && {
      wrappers+=("$wrapper" )
    }
  done

  "${wrappers[@]}" doBorgCreateWrapped "$@" "${borgCreateArgs[@]}"

  rc=$?

  return $rc
}

doBackupMysql() {
  $DRYRUN "${NICE[@]}" "${BACKUP_MYSQL[@]}" "$@"
  return $?
}

##############################################

doBackup() {
  local exitStatus=0
  local thisStatus=0
  local split

  while (( $# > 0 )); do
    case "$1" in
      --)
        shift
        break
        ;;

      '')
        info "Warning: got empty backup label"
        exitStatus=$( max $exitStatus 1 )
        shift
        break
        ;;

      --*:*)
        info "local backup hook '${1}'"

        # removes first 2 chars and splits :
        split=(${1:2//\:/ })

        bb_hook_${split[0]} "${split[0]}" "${split[1]}"

        thisStatus=$?
        exitStatus=$( max "$thisStatus" "$exitStatus" )

        shift
        ;;

      --*)
        bbLabel="${1:2}"

        "bb_hook_${bbLabel}"

        thisStatus=$?
        exitStatus=$( max "$thisStatus" "$exitStatus" )

        shift
        ;;

      *:*)
        bbLabel="$1"
        shift

        info "local backup label '${bbLabel}'"

        # splits :
        split=(${bbLabel//\:/ })

        "bb_label_${split[0]}" "${split[0]}" "${split[1]}"

        thisStatus=$?
        exitStatus=$( max "$thisStatus" "$exitStatus" )
        ;;

      *)
        bbLabel="$1"

        "bb_label_${bbLabel}" "${bbLabel}" ""

        thisStatus=$?
        exitStatus=$( max "$thisStatus" "$exitStatus" )

        shift
        ;;
    esac


    if (( $thisStatus == 0 )); then
      info "Info: borg backup labeled '${borgCreateLabel}' succeeded"
    elif (( $thisStatus == 1 )); then
        info "Warning: backup labeled '${bbLabel}' returned status $thisStatus"
    else
      info "Error: backup labeled '${bbLabel}' returned status ${thisStatus}"
      
      
      [[ "$onErrorStop" == "" ]] || {
        echo "We stop here (--on-error-stop invoked)"
        break
      }
    fi
  done

  return $exitStatus
}

backupMysqlAndBorgCreate() {
  local exitStatus=0
  local thisStatus=
  local label

  doBackupMysql "$@" "${backupMysqlArgs[@]}"

  thisStatus=$?
  exitStatus=$( max "$thisStatus" "$exitStatus" )

  (( $thisStatus == 0 )) || info "${bbLabel}:mysqldump returned status: ${thisStatus}"

  # of course we upload backup even if dump returned errors
  label="mysql"
  doBorgCreate "$label" "$backupMysqlLocalDir"
  
  thisStatus=$?
  exitStatus=$( max "$thisStatus" "$exitStatus" )

  [[ "$thisStatus" == 0 ]] || info "$label:borgCreate returned status: ${thisStatus}"

  return $exitStatus
}

createLogrotate() {
  local conf="# created by $0 on $(nowIso)"

  conf+="\n${logFile} {
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
  [[ $DRYRUN == "" ]] || {
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

  local BORG_REPO_ORIG
  local BORG_PASSPHRASE_ORIG

  BORG_REPO_ORIG="${BORG_REPO}"

  # append repoSuffix to default repo
  export BORG_REPO="${BORG_REPO}-${repoSuffix}"

  local subRepoPassVar="BORG_PASSPHRASE_${repoSuffix}"
  
  [[ -v "${subRepoPassVar}" ]] && {

    [[ -v 'BORG_PASSPHRASE' ]] && {
      BORG_PASSPHRASE_ORIG="${BORG_PASSPHRASE}"
    }

    export BORG_PASSPHRASE="${!subRepoPassVar}"
  }

  "$@"

  exitStatus=$?

  export BORG_REPO="${BORG_REPO_ORIG}"

  [[ -v 'BORG_PASSPHRASE_ORIG' ]] && {
    export BORG_PASSPHRASE="${BORG_PASSPHRASE_ORIG}"
  }

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



###################################################
# Main

[[ -e "$logrotateConf" ]] || {
  createLogrotate || {
    info "Warning: failed to create logrotate ${logrotateConf}"
  }
}

for conf in "${localConf[@]}"; do
  [[ -f "$conf" ]] && {
    # first one we find, we source
    source "$conf"
    
    (( $? == 0 )) && {
      >&2 echo "Info: loaded local config ${conf}";
      break;
    } || {
      >&2 echo "Warning: found '${conf}' but failed to load it."
    }
  }
done

# logTo=("${NICE[@]}" )
# logTo+=(
#   tee --output-error=warn -a 
# )
# doBackup "$@" 2>&1 | "${logTo[@]}" "$logFile"



doBackup "$@" 2>&1 | logToFile "$logFile"

exitRc=$?

exit $exitRc
