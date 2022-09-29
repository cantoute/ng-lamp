#!/bin/bash

[[ -v 'INIT' ]] || {
  # Only when called directly

  SCRIPT_DIR="${0%/*}"
  SCRIPT_NAME="${0##*/}"
  SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

  . "${SCRIPT_DIR}/backup-common.sh";
  init && initUtils

  # Obsolete?
  # . "${SCRIPT_DIR}/backup-borg-labels.sh";
  # localConf=( "${SCRIPT_DIR}/${SCRIPT_NAME_NO_EXT}-${hostname}.sh" )
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
    --)                          shift; break ;;
    --log)  logFile="$2";             shift 2 ;;
    --cron) beSilentOnSuccess="true";   shift ;;

    # nice|io-nice is auto added if in PATH
    # --no-nice) NICE=();                 shift ;;
    # --io-nice) NICE+=( ionice -c3 );    shift ;;
    # --nice)    NICE+=( nice );          shift ;;

    --verbose|--progress) borgCreateArgs+=( "$1" );         shift ;;
    --exclude|--include)  borgCreateArgs+=( "$1" "$2" );  shift 2 ;;

    --do-init|--init) doInit="true";                        shift ;;
    --on-error-stop|--stop) onErrorStop="true";             shift ;;

    --dry-run) DRYRUN=dryRun; BORG_CREATE+=( --dry-run );   shift ;;
    --borg-dry-run) BORG_CREATE+=( --dry-run );             shift ;;

    --mysql-single-like|--mysql-like)
      # Takes affect only for mode 'single'
      backupBorgMysqlSingleArgs+=( --like "$2" )
      shift 2 ;;
    
    --mysql-single-not-like|--mysql-not-like)
      # Takes affect only for mode 'single'
      backupBorgMysqlSingleArgs+=( --not-like "$2" )
      shift 2 ;;

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

  $DRYRUN "${BORG_CREATE[@]}" "$@"
}

backupMysql() { $DRYRUN "${BACKUP_MYSQL[@]}" "$@"; }

borgCreate() {
  local label="$1"
  local wrapper wrappers=()

  borgCreateLabel="${label}"

  # If those functions are found
  local bbWrappers=(
    "bb_borg_create_wrapper"
    "bb_borg_create_wrapper_${label}"
    "bb_borg_create_wrapper_${hostname}"
    "bb_borg_create_wrapper_${hostname}_${label}"
  )

  for wrapper in "${bbWrappers[@]}"; do
    [[ "$( LC_ALL=C type -t "$wrapper" )" == "function" ]] && {
      wrappers+=( "$wrapper" )
    }
  done

  # Call them in front. Aka wrap.
  "${wrappers[@]}" _borgCreate "$@" "${borgCreateArgs[@]}"
}


##############################################

backupBorg() {
  local rc=0 thisRc a c r

  while (( $# > 0 )); do
    case "$1" in
      --) shift; break ;;
      -*) break ;;
      '') info "Warning: got empty backup label"; thisRc=1; shift ;;

      *)
        bbLabel="$1"; shift; # Global bbLabel

        c="${bbLabel%%\:*}" # up to first ':' is the command, the rest is argument
        [[ "$c" == "$bbLabel" ]] && { a=''; } || { a="${bbLabel#*\:}"; }
        
        r=( "bb_label_$c" "$c" "$a" )

        info "backupBorg: proceeding label '${bbLabel}' (${r[@]})"

        "${r[@]}";

        thisRc=$?
        ;;
    esac

    rc=$( max "$rc" "$thisRc" )

    if   (( $thisRc == 0 )); then
      info "Info: borg backup labeled '${bbLabel}' succeeded"
    elif (( $thisRc == 1 )); then
      info "Warning: backup labeled '${bbLabel}' returned status $thisRc"
    else
      info "Error: backup labeled '${bbLabel}' returned status ${thisRc}"

      [[ "$onErrorStop" == "" ]] || { echo "We stop here (--on-error-stop invoked)"; break; }
    fi
  done

  return $rc
}

# This function will work only for local dir mysql backup
backupBorgMysql() {
  local mysqlRc borgRc txt
  local borgLabel="mysql" # Default borg label
  local dir="$backupMysqlLocalDir"
  local args=()

  while (( $# > 0 )); do
    case "$1" in
      --label|--borg-label)
        borgLabel="$2"
        shift 2 ;;

      --dir)
        dir="$2"
        args+=( "$1" "$2" )
        shift 2 ;;

      --store) # Not tested TODO:
        backupBorgMysqlArgs+=( "$1" "$2" "$3" )
        shift 3 ;;

      *)
        args+=( "$1" )
        shift ;;
    esac
  done

  backupMysql "${args[@]}" "${backupBorgMysqlArgs[@]}"

  mysqlRc=$?
  (( $mysqlRc == 0 )) || {
    # txt=$(( $mysqlRc > 1 ? 'Error' : 'Warning' ))
    txt='Error'; (( $borgRc == 1 )) && txt='Warning';
    info "$txt: backupBorgMysql: ${bbLabel}:mysqldump returned status: ${mysqlRc}"
    info "Command: backupMysql ${args[@]} ${backupBorgMysqlArgs[@]}"
  }

  borgCreate "${borgLabel-mysql}" "$dir"
  
  borgRc=$?
  (( $borgRc == 0 )) || {
    txt='Error'; (( $borgRc == 1 )) && txt='Warning';
    info "$txt: backupBorgMysql: $borgLabel:borgCreate returned status: ${borgRc}"
    info "Command: borgCreate ${label-mysql} $dir"
  }

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

set -- main "$@" # Call main

[[ "$beSilentOnSuccess" == "true" ]] && { # Aka cron mode
  OUTPUT=`"$@" 2>&1` || {
    rc=$?;
    
    (( $rc == 1 )) && >&2 echo "Warning"
    (( $rc  > 1 )) && >&2 echo "Error"

    >&2 echo 
    
    # Get output last line
    >&2 echo "${OUTPUT##*$'\n'}"
    >&2 echo "##########################"
    infoRecap
    >&2 echo "##########################"

    echo "$OUTPUT";
    exit $rc;
  }
} || {
  "$@";

  >&2 echo "##########################"
  infoRecap
  >&2 echo "##########################"
}
