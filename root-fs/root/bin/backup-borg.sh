#!/bin/bash

[[ -v 'INIT' ]] || {
  # Only when called directly

  SCRIPT_DIR="${0%/*}"
  SCRIPT_NAME="${0##*/}"
  SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

  . "${SCRIPT_DIR}/backup-common.sh" && init && initDefaults || {
    >&2 echo "Error: failed to load ${SCRIPT_DIR}/backup-common.sh and init"
    exit 2
  }
}

##############################################

backupMysql() {
  local rc preArgs=() args=() dir="$1" mode="$2"; shift 2
  
  [[ -v 'backupMysqlArgs' ]] && set -- "${backupMysqlArgs[@]}" "$@"

  case "$mode" in
    all)
      [[ -v 'backupMysqlAllArgs'   ]] && set -- "${backupMysqlAllArgs[@]}"   "$@"
      [[ -v 'backupMysqlArgs'      ]] && set -- "${backupMysqlArgs[@]}"      "$@"
      ;;

    prune)
      [[ -v 'backupMysqlPruneArgs' ]] && set -- "${backupMysqlPruneArgs[@]}" "$@"
      [[ -v 'backupMysqlArgs'      ]] && set -- "${backupMysqlArgs[@]}"      "$@"
      ;;

    db)
      while (( $# > 0 )); do
        case "$1" in
          -*) break ;;
           *) db+=( "$1" ); shift ;;
        esac
      done

      (( ${#db[@]} > 0 )) || { info "Error: backupMysql: mode 'db' requires database names to backup."; return 2; }
      
      [[ -v 'backupMysqlDbArgs' ]] && set -- "${backupMysqlDbArgs[@]}" "$@"
      [[ -v 'backupMysqlArgs'   ]] && set -- "${backupMysqlArgs[@]}"   "$@"

      set -- "${db[@]}" "$@" # Db has to come as fist args
      ;;
    
    single)
      [[ -v 'backupMysqlSingleArgs' ]] && set -- "${backupMysqlSingleArgs[@]}" "$@"
      [[ -v 'backupMysqlArgs'       ]] && set -- "${backupMysqlArgs[@]}"       "$@"
      ;;

    *) info "Error: unknown mode: '$mode'"; return 2 ;;
  esac

  set -- "${BACKUP_MYSQL[@]}" "$dir" "$mode" "$@"

  info "Info: Starting backupMysql: $@"

  $DRYRUN "$@";
  rc=$?

  (( rc == 0 )) && info "Success: backupMysql succeeded"
  (( rc == 1 )) && info "Warning: backupMysql returned warnings rc $rc"
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
        backupMysqlArgs+=( "$1" "$2" "$3" )
        shift 3 ;;

      *)
        args+=( "$1" )
        shift ;;
    esac
  done

  RUN=( backupMysql "${args[@]}" "${backupMysqlArgs[@]}" )
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

tryConf() {
  while (( $# > 0 )); do
    if [[ -f "$1" ]]; then
      . "$1" && {
        info "Info: ${SCRIPT_NAME}: Loaded conf: '$1'";
        tryConfLoaded="$1"
        return;
      } || { # Seems there is an error in config file
        info "Error: failed to load conf: '$1' rc 2";
        return 2;
      };
    else
      shift;
    fi
  done
}

###################################################
# Main

main() {
  local rc trace=( "$SCRIPT_NAME" "${FUNCNAME[0]}": "$@" )

  # To be able to trap all output for --cron mode we need to load 
  if [[ -v 'loadConf' && "$loadConf" == '' ]]; then
    . "$loadConf" || {
      info "Error: ${SCRIPT_NAME}: Failed to load conf '$loadConf' rc 2";
      return 2;
    }
  else
    # Not finding a file isn't an error
    # Finding a file and failing to load it is an error and we exit
    tryConf "${tryConf[@]}" || { return $?; }
  fi

  backupBorg "$@" 2>&1 | logToFile "$logFile"

  local pipeRc=(${PIPESTATUS[@]})

  rc=$( max ${pipeRc[@]} )

  (( ${pipeRc[1]} == 0 )) && { loggingToFile="$logFile"; } || { info "Warning: failed to write to file '$logFile'"; }

  if   (( $rc == 0 )); then info "Success: '${trace[@]}' finished successfully."
  elif (( $rc == 1 )); then info "Warning: '${trace[@]}' finished with warnings. rc $rc"
  else info "Error: '${trace[@]}' finished with errors. rc $rc"; fi

  return $rc
}


# your email@some.co
# only used for logrotate 
alertEmail="alert"

logFile="/var/log/backup-borg.log"
logrotateConf="/etc/logrotate.d/backup-borg"

# BORG_CREATE=( "${SCRIPT_DIR}/backup-borg-create.sh" )
[[ -v 'BACKUP_MYSQL' ]] || BACKUP_MYSQL=( "${SCRIPT_DIR}/backup-mysql.sh" )

exitRc=0
onErrorStop=
doLogrotateCreate=
doInit=
beSilentOnSuccess=

bbLabel=
backupLabel=


###########################
# Look for local conf
#########

tryConf=(
  "$SCRIPT_DIR/backup-${hostname}.sh"
  "$SCRIPT_DIR/backup-local.sh"
)

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
    --conf) loadConf="$2";            shift 2 ;;

    --verbose|--progress) createArgs+=( "$1" );              shift ;;
    --exclude|--include)  createArgs+=( "$1" "$2" );       shift 2 ;;

    --do-init|--init)       doInit="true";                   shift ;;
    --on-error-stop|--stop) onErrorStop="true";              shift ;;

    --dry-run|-n) DRYRUN=dryRun; createArgs+=( --dry-run );  shift ;;
    --borg-dry-run) createArgs+=( --dry-run );               shift ;;

    --mysql-single-like|--mysql-like)
      # Takes affect only for mode 'single'
      backupMysqlSingleArgs+=( --like "$2" )
      shift 2 ;;
    
    --mysql-single-not-like|--mysql-not-like)
      # Takes affect only for mode 'single'
      backupMysqlSingleArgs+=( --not-like "$2" )
      shift 2 ;;

    *)
      info "Error: unknown argument '$1'. Did you forget '--' that should precede label names?"
      exit 2
      ;;
  esac
done


# [[ -f "$SCRIPT_DIR/backup-${hostname}.sh" ]] && . "$SCRIPT_DIR/backup-${hostname}.sh" || {
#   [[ -f "$SCRIPT_DIR/backup-local.sh" ]] && . "$SCRIPT_DIR/backup-local.sh";
# }

set -- main "$@" # Pass call to main

[[ -v 'beSilentOnSuccess' && "$beSilentOnSuccess" == "true" ]] && { # Aka cron mode
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

    # IFS=$'\n' outputA=( $OUTPUT )
    # nb=${#outputA[@]}

    # readarray -t outputA <<<"${OUTPUT}"
    # nb=${#outputA[@]}

    nb="${OUTPUT//[^\n]}"; nb=${#nb}

    nbHead=100
    nbTail=100

    # There is a log file and nb lines is greater than nbHead + nbTail + 100
    # We truncate
    if [[ -v 'loggingToFile' ]] && (( nb > nbHead + nbTail + 100 )); then
      head -n $nbHead <( echo "$OUTPUT" )

      echo ...
      echo "##########################"
      echo "# Truncated $(( nb - nbHead - nbTail )) lines"
      echo "# Logged into '$loggingToFile'"
      echo "##########################"
      echo ...

      tail -n $nbTail <( echo "$OUTPUT" )
    else
      echo "$OUTPUT"
    fi

    exit $rc;
  }
} || {
  "$@";

  >&2 echo "##########################"
  infoRecap
  >&2 echo "##########################"
}
