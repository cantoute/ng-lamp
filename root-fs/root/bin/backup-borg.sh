#!/bin/bash

[[ -v 'INIT' ]] || {
  # Only when called directly

  SCRIPT_DIR="${0%/*}"
  SCRIPT_NAME="${0##*/}"
  SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

  . "${SCRIPT_DIR}/backup-common.sh" && init && initUtils || {
    >&2 echo "Error: failed to load ${SCRIPT_DIR}/backup-common.sh and init"
    exit 2
  }
}

# your email@some.co
# only used for logrotate 
alertEmail="alert"

logFile="/var/log/backup-borg.log"
logrotateConf="/etc/logrotate.d/backup-borg"

# BORG_CREATE=( "${SCRIPT_DIR}/backup-borg-create.sh" )
BACKUP_MYSQL=( "${SCRIPT_DIR}/backup-mysql.sh" )

exitRc=0
onErrorStop=
doLogrotateCreate=
doInit=
beSilentOnSuccess=

bbLabel=
backupLabel=

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

    --verbose|--progress) borgCreateArgs+=( "$1" );         shift ;;
    --exclude|--include)  borgCreateArgs+=( "$1" "$2" );  shift 2 ;;

    --do-init|--init) doInit="true";                        shift ;;
    --on-error-stop|--stop) onErrorStop="true";             shift ;;

    --dry-run|-n) DRYRUN=dryRun; BORG_CREATE+=( --dry-run ); shift ;;
    --borg-dry-run) BORG_CREATE+=( --dry-run );              shift ;;

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
# _borgCreate() {
#   # >&2 echo "BORG_REPO: $BORG_REPO"
#   # >&2 echo "BORG_PASSPHRASE: $BORG_PASSPHRASE"

#   $DRYRUN "${BORG_CREATE[@]}" "$@"
# }

backupMysql() {
  local rc
  set -- "${BACKUP_MYSQL[@]}" "$@"
  info "Info: Starting backupMysql: $@"
  $DRYRUN "$@";
  rc=$?

  (( rc == 0 )) && info "Success: backupMysql succeeded"
  (( rc == 1 )) && info "Warning: backupMysql returned warnings"
  (( rc >  1 )) && info "Error: backupMysql returned rc $rc"

  return $rc
}

backupCreate() {
  local rc=0 createRc pruneRc compactRc backupPrefix
  backupLabel="$1"; shift

  info "Info: Starting backup label: $backupLabel"

  borgCreate "$backupLabel" "$@"
  
  createRc=$?
  (( createRc == 1 )) && info "Warning: Create: ${backupLabel} finished with warnings"
  (( createRc > 1  )) && info "Error: Create: ${backupLabel} finished with error rc $createRc"

  info "Pruning label: $backupLabel"
  
  borgPrune "$backupLabel"
  
  pruneRc=$?
  (( pruneRc == 1 )) && info "Warning: Prune: ${backupLabel} finished with warnings"
  (( pruneRc > 1  )) && info "Error: Prune: ${backupLabel} finished with error rc $pruneRc"

  info "Compacting repository $BORG_REPO"
  
  borgCompact
  
  compactRc=$?
  (( compactRc == 1 )) && info "Warning: Compact: ${backupLabel} finished with warnings"
  (( compactRc > 1  )) && info "Error: Compact: ${backupLabel}  finished with error rc $compactRc"

  return $( max $createRc $pruneRc $compactRc )
}

borgCreate() {
  local bbWrappers wrapper wrappers=() backupLabel="$1"
  shift

  # If those functions are found
  bbWrappers=(
    "bb_borg_create_wrapper"
    "bb_borg_create_wrapper_${backupLabel%%\:*}"
    "bb_borg_create_wrapper_${hostname}"
    "bb_borg_create_wrapper_${hostname}_${backupLabel%%\:*}"
  )

  for wrapper in "${bbWrappers[@]}"; do
    [[ "$( LC_ALL=C type -t "$wrapper" )" == "function" ]] && {
      wrappers+=( "$wrapper" )
    }
  done

  # Append createArgs[] and excludeArgs[] to our arguments
  set -- create ::"{hostname}-${backupLabel}-{now}" "$@" "${createArgs[@]}" "${excludeArgs[@]}"

  # Wrappers can append or manipulate $@ or change env var
  $DRYRUN "${wrappers[@]}" "${BORG[@]}" "$@"
}

borgPrune() {
  local backupLabel="$1"; shift

  set -- prune --glob-archives "{hostname}-${backupLabel}-*" "${pruneArgs[@]}" "${pruneKeepArgs[@]}"

  $DRYRUN "${BORG[@]}" "$@"
}

borgCompact() {
  $DRYRUN "${BORG[@]}" compact "$@"
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

        info "Info: ${FUNCNAME[0]}: Executing label '${bbLabel}' (${r[@]})"

        "${r[@]}";

        thisRc=$?
        ;;
    esac

    rc=$( max "$rc" "$thisRc" )

    if   (( $thisRc == 0 )); then
      info "Success: borg backup labeled '${bbLabel}' succeeded"
    elif (( $thisRc == 1 )); then
      info "Warning: backup labeled '${bbLabel}' returned rc 1"
    else
      info "Error: backup labeled '${bbLabel}' returned rc ${thisRc}"

      [[ "$onErrorStop" == "" ]] || { echo "We stop here (--on-error-stop invoked)"; break; }
    fi
  done

  return $rc
}

# This function will work only for local dir mysql backup
backupBorgMysql() {
  local mysqlRc borgRc txt RUN
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

  RUN=( backupMysql "${args[@]}" "${backupBorgMysqlArgs[@]}" )
  "${RUN[@]}"

  mysqlRc=$?
  (( $mysqlRc == 0 )) || {
    # txt=$(( mysqlRc > 1 ? 'Error' : 'Warning' )) # that one killed me
    txt='Error'; (( $borgRc == 1 )) && txt='Warning';
    info "$txt: ${FUNCNAME[0]}: ${bbLabel}:${RUN[0]} rc ${mysqlRc}"
    info "Command: ${RUN[@]}"
  }

  RUN=( backupCreate "${borgLabel-mysql}" "$dir" )
  "${RUN[@]}"
  
  borgRc=$?
  (( $borgRc == 0 )) || {
    txt='Error'; (( $borgRc == 1 )) && txt='Warning';
    info "$txt: ${FUNCNAME[0]}: ${bbLabel}:${RUN[0]} rc ${borgRc}"
    info "Command: backupCreate ${label-mysql} $dir"
  }

  return $( max $mysqlRc $borgRc )
}

###################################################
# Main

main() {
  local rc trace=( "$SCRIPT_NAME" "$@" )

  backupBorg "$@" 2>&1 | logToFile "$logFile"

  local pipeRc=(${PIPESTATUS[@]})

  rc=$( max ${pipeRc[@]} )

  (( ${pipeRc[1]} == 0 )) || info "Warning: failed to write to file '$logFile'"

  if   (( $rc == 0 )); then info "Success: '${trace[@]}' finished successfully."
  elif (( $rc == 1 )); then info "Warning: '${trace[@]}' finished with warnings. rc $rc"
  else info "Error: '${trace[@]}' finished with errors. rc $rc"; fi

  return $rc
}

set -- main "$@" # Pass call to main

[[ "$beSilentOnSuccess" == "true" ]] && { # Aka cron mode
  OUTPUT=`"$@" 2>&1` || {
    rc=$?;
    
    (( rc == 1 )) && >&2 echo "Warning"
    (( rc  > 1 )) && >&2 echo "Error"

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
