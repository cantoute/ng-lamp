#!/bin/bash

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
    
    --mysql-single-like|--mysql-like)
      # Takes affect only for --single
      backupMysqlSingleArgs+=( --like "$2" )
      shift 2
      ;;
    
    --mysql-single-not-like|--mysql-not-like)
      # Takes affect only for --single
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
      info "Error: unknown argument '$1'. Did you forget '--' that should precede label names?"
      exit 1
      ;;

    # *)
    #   # not sure this is smart... as misspelled args here could be tricky to debug
    #   break
    #   ;;
  esac
done

##############################################

# Don't call directly, use borgCreate
_borgCreate() {
  # >&2 echo "BORG_REPO: $BORG_REPO"
  # >&2 echo "BORG_PASSPHRASE: $BORG_PASSPHRASE"

  $DRYRUN "${NICE[@]}" "${BORG_CREATE[@]}" "$@"
}

borgCreate() {
  local wrappers=()
  local label="$1"
  local wrapper

  borgCreateLabel="${label}"

  local bbWrappers=(
    "bb_borg_create_wrapper"
    "bb_borg_create_wrapper_${label}"
    "bb_borg_create_wrapper_${hostname}"
    "bb_borg_create_wrapper_${hostname}_${label}"
  )

  for wrapper in "${bbWrappers[@]}"; do
    [[ "$( LC_ALL=C type -t "$wrapper" )" == "function" ]] && {
      wrappers+=("$wrapper" )
    }
  done

  "${wrappers[@]}" _borgCreate "$@" "${borgCreateArgs[@]}"
}

_backupMysql() { $DRYRUN "${NICE[@]}" "${BACKUP_MYSQL[@]}" "$@"; }

##############################################

backupBorg() {
  local exitRc=0
  local thisRc=0
  local split

  while (( $# > 0 )); do
    case "$1" in
      --)
        shift
        break
        ;;

      -*)
        break
        ;;

      '')
        info "Warning: got empty backup label"
        exitRc=$( max $exitRc 1 )
        shift
        break
        ;;

      *:*)
        bbLabel="$1"
        shift

        info "local backup label '${bbLabel}'"

        # splits :
        split=(${bbLabel//\:/ })

        "bb_label_${split[0]}" "${split[0]}" "${split[1]}"

        thisRc=$?
        exitRc=$( max "$thisRc" "$exitRc" )
        ;;

      *)
        bbLabel="$1"

        "bb_label_${bbLabel}" "${bbLabel}" ""

        thisRc=$?
        exitRc=$( max "$thisRc" "$exitRc" )

        shift
        ;;
    esac

    if   (( $thisRc == 0 )); then info "Info: borg backup labeled '${borgCreateLabel}' succeeded"
    elif (( $thisRc == 1 )); then info "Warning: backup labeled '${bbLabel}' returned status $thisRc"
    else info "Error: backup labeled '${bbLabel}' returned status ${thisRc}"
      [[ "$onErrorStop" == "" ]] || { echo "We stop here (--on-error-stop invoked)"; break; }
    fi
  done

  return $exitRc
}

# Obsolete
backupMysqlAndBorgCreate() { backupMysql "$@"; }

backupMysql() {
  local mysqlRc
  local borgRc
  local label="mysql"
  local dir="$backupMysqlLocalDir"
  local args=()

  while (( $# > 0 )); do
    case "$1" in
      --label|--borg-label)
        label="$2"
        shift 2
        ;;

      --dir)
        dir="$2"
        args+=( "$1" "$2" )
        shift 2
        ;;

      *)
        args+=( "$1" )
        shift
        ;;
    esac
  done

  _backupMysql "${args[@]}" "${backupMysqlArgs[@]}"

  mysqlRc=$?
  (( $mysqlRc == 0 )) || info "${bbLabel}:mysqldump returned status: ${mysqlRc}"

  borgCreate "${label-mysql}" "$dir"
  
  borgRc=$?
  (( $borgRc == 0 )) || info "$label:borgCreate returned status: ${borgRc}"

  return $( max $mysqlRc $borgRc )
}

createLogrotate() {
  local conf="# created by $0 on $( nowIso )"

  conf+="
${logFile} {
    daily
    rotate 14
    compress
    delaycompress
    nocreate
    nomissingok     # default

    # generate an error on missing
    # 24h without any logs is not normal
    notifempty
    errors ${alertEmail}
}
"

  [[ $DRYRUN == "" ]] || {
    echo "DryRun: not creating file ${logrotateConf}"
    echo "$conf"

    return
  }

  info "Info: missing '${logrotateConf}' use --logrotate-conf"

  >&2 echo "$conf" 

  # printf "%s" "$conf" > "$logrotateConf"
}


# Will look for vars BORG_REPO-$1
# and will restaure default BORG_REPO BORG_PASSPHRASE before terminating
usingRepo() {
  local repo="$1"
  shift

  local BORG_REPO_ORIG
  local BORG_PASSPHRASE_ORIG
  local rc
  local var

  [[ -v 'BORG_REPO' ]]       && BORG_REPO_ORIG="$BORG_REPO"
  [[ -v 'BORG_PASSPHRASE' ]] && BORG_PASSPHRASE_ORIG="$BORG_PASSPHRASE"

  var="BORG_REPO_${repo}"
  [[ -v "$var" ]] && export BORG_REPO="${!var}"

  var="BORG_PASSPHRASE_${repo}"
  [[ -v "$var" ]] && export BORG_PASSPHRASE="${!var}"

  "$@"

  rc=$?

  # Restore previous values
  [[ -v 'BORG_REPO_ORIG' ]]       && export BORG_REPO="${BORG_REPO_ORIG}"             || unset BORG_REPO
  [[ -v 'BORG_PASSPHRASE_ORIG' ]] && export BORG_PASSPHRASE="${BORG_PASSPHRASE_ORIG}" || unset BORG_PASSPHRASE

  return $rc
}

subRepo() {
  local repoSuffix="$1"
  shift

  local exitRc=

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

  exitRc=$?

  export BORG_REPO="${BORG_REPO_ORIG}"

  [[ -v 'BORG_PASSPHRASE_ORIG' ]] && {
    export BORG_PASSPHRASE="${BORG_PASSPHRASE_ORIG}"
  }

  return $exitRc
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

  exitRc=$?

  # unset
  export BORG_REPO=
  export BORG_PASSPHRASE=

  return $exitRc
}

swapRepo() {
  local repo="$1"
  local pass="$2"
  shift 2

  local exitRc=

  local BORG_REPO_SWITCHED="${BORG_REPO-unset}"
  local BORG_PASSPHRASE_SWITCHED="${BORG_PASSPHRASE-unset}"

  export BORG_REPO="${repo}"
  export BORG_PASSPHRASE="${pass}"
  
  # do
  "$@"

  exitRc=$?


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

  return $exitRc
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

      # should we stop at first conf found?
      # break;
    } || {
      >&2 echo "Warning: found '${conf}' but failed to load it."
    }
  }
done

# logTo=("${NICE[@]}" )
# logTo+=(
#   tee --output-error=warn -a 
# )
# backupBorg "$@" 2>&1 | "${logTo[@]}" "$logFile"

call=( "$SCRIPT_NAME" "$@" )

backupBorg "$@" 2>&1 | logToFile "$logFile"

rc=$( max ${PIPESTATUS[@]} )

if   (( $rc == 0 )); then info "Success: '${call[@]}' finished successfully. rc $rc"
elif (( $rc == 1 )); then info "Warning: '${call[@]}' finished with warnings. rc $rc"
else info "Error: '${call[@]}' finished with errors. rc $rc"; fi

exit $rc
