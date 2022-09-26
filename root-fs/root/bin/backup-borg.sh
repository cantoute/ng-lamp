#!/bin/bash

set -u
set -o pipefail

[[ -v 'INIT' ]] || {

  SCRIPT_DIR="${0%/*}"
  SCRIPT_NAME="${0##*/}"
  SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

  source "${SCRIPT_DIR}/backup-common.sh";
  init && initUtils

  source "${SCRIPT_DIR}/backup-borg-labels.sh";

  loadDotEnv() { source "~/.env.borg"; }

  localConf=( "${SCRIPT_DIR}/${SCRIPT_NAME_NO_EXT}-${hostname}.sh" )
}

# your email@some.co
# only used for logrotate 
alertEmail="alert"

logFile="/var/log/backup-borg.log"
logrotateConf="/etc/logrotate.d/backup-borg"

BORG_CREATE=( "${SCRIPT_DIR}/backup-borg-create.sh" )
BACKUP_MYSQL=( "${SCRIPT_DIR}/backup-mysql.sh" )

exitRc=0
onErrorStop=
doLogrotateCreate=
doInit=
beSilentOnSuccess=

bbLabel=
borgCreateLabel=

# Debug
# logFile="/tmp/backup-borg.log2"
# logrotateConf="/tmp/backup-borg4"
# NICE=""
# DRYRUN="dryRun"

while (( $# > 0 )); do
  case "$1" in
    --mysql-single-like|--mysql-like)
      # Takes affect only for --single
      backupMysqlSingleArgs+=( --like "$2" )
      shift 2 ;;
    
    --mysql-single-not-like|--mysql-not-like)
      # Takes affect only for --single
      backupMysqlSingleArgs+=( --not-like "$2" )
      shift 2 ;;

    --verbose)
      borgCreateArgs+=( "$1" )
      shift ;;

    --progress)
      borgCreateArgs+=( "$1" )
      shift ;;

    --exclude|--include)
      borgCreateArgs+=( "$1" "$2" )
      shift 2 ;;

    --on-error-stop|--stop)
      onErrorStop="true"
      shift ;;

    --do-init|--init)
      doInit="true"
      shift
      ;;

    --log)
      logFile="$2"
      shift 2 ;;

    --conf)
      localConf=( "$2" )
      shift 2 ;;

    --cron)
      beSilentOnSuccess="true"
      shift ;;

    --dry-run)
      DRYRUN=dryRun
      borgCreateArgs+=(  --dry-run )
      backupMysqlArgs+=( --dry-run )
      shift ;;

    --borg-dry-run)
      BORG_CREATE+=( --dry-run )
      shift ;;

    --mysqldump-dry-run|--mysql-dry-run)
      backupMysqlArgs+=( --dry-run )
      shift ;;

    # Now done automatically
    --nice) NICE+=( nice ); shift ;;
    --io-nice) NICE+=( ionice -c3 ) shift ;;

    --) shift; break ;;

    *)
      info "Error: unknown argument '$1'. Did you forget '--' that should precede label names?"
      exit 1
      ;;
  esac
done

##############################################

# Don't call directly, use borgCreate
_borgCreate() {
  # >&2 echo "BORG_REPO: $BORG_REPO"
  # >&2 echo "BORG_PASSPHRASE: $BORG_PASSPHRASE"

  $DRYRUN "${NICE[@]}" "${BORG_CREATE[@]}" "$@"
}

_backupMysql() { $DRYRUN "${NICE[@]}" "${BACKUP_MYSQL[@]}" "$@"; }

borgCreate() {
  local label="$1"
  local wrapper wrappers=()

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


##############################################

backupBorg() {
  local exitRc=0
  local thisRc=0
  local split

  while (( $# > 0 )); do
    case "$1" in
      --) shift; break ;;
      -*) break ;;
      '') info "Warning: got empty backup label"; exitRc=$( max 1 $exitRc ) shift; break ;;

      *:*)
        bbLabel="$1"; shift

        info "local backup label '${bbLabel}'"

        # splits :
        split=( ${bbLabel//\:/ } )

        "bb_label_${split[0]}" "${split[0]}" "${split[1]}"

        thisRc=$?
        exitRc=$( max "$thisRc" "$exitRc" )
        ;;

      *)
        bbLabel="$1"; shift

        "bb_label_${bbLabel}" "${bbLabel}" ""

        thisRc=$?
        exitRc=$( max "$thisRc" "$exitRc" )
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

backupBorgMysql() {
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

###################################################
# Main
main() {
  local rc trace=( "$SCRIPT_NAME" "$@" )

  backupBorg "$@" 2>&1 | logToFile "$logFile"

  rc=$( max ${PIPESTATUS[@]} )

  if   (( $rc == 0 )); then info "Success: '${trace[@]}' finished successfully. rc $rc"
  elif (( $rc == 1 )); then info "Warning: '${trace[@]}' finished with warnings. rc $rc"
  else info "Error: '${trace[@]}' finished with errors. rc $rc"; fi

  return $rc
}

set -- main "$@"

[[ "$beSilentOnSuccess" == "true" ]] && {
  OUTPUT=`"$@" 2>&1` || { rc=$?; echo "$OUTPUT"; exit $rc; }
} || {
  "$@"
}
