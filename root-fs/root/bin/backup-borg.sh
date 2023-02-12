#!/bin/bash

SCRIPT_DIR="${0%/*}"
SCRIPT_NAME="${0##*/}"
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"


# your email@some.co
# only used for logrotate 
alertEmail="alert"
logFile="/var/log/backup-borg.log"
logrotateConf="/etc/logrotate.d/backup-borg"

. "${SCRIPT_DIR}/backup-common.sh" && init && initUtils || {
    >&2 echo "Error: failed to load ${SCRIPT_DIR}/backup-common.sh and init"
    exit 2
  }

. "${SCRIPT_DIR}/backup-defaults.sh" || {
    >&2 echo "Error: failed to load ${SCRIPT_DIR}/backup-defaults.sh"
    exit 2
  }

. "${SCRIPT_DIR}/backup-borg-label-mysql.sh" || {
    >&2 echo "Error: failed to load ${SCRIPT_DIR}/backup-borg-label-mysql.sh"
    exit 2
  }

# Global vars
exitRc=0
onErrorStop=
doLogrotateCreate=
doInit=
beSilentOnSuccess=

bbLabel=
backupLabel=

tryDotenv=(
  .backup.${hostname}.env
  ~/.backup.${hostname}.env
  /root/.backup.${hostname}.env
  "${SCRIPT_DIR}/.backup.${hostname}.env"
)

tryConfFiles=(
  "$SCRIPT_DIR/backup-${hostname}.sh"
  "$SCRIPT_DIR/backup-local.sh"
)

# process first group of args
while (( $# > 0 )); do
  case "$1" in
    --)                                               shift; break ;;  # Next comes a list of labels to execute
    --log)  logFile="$2";                                  shift 2 ;;
    --cron) beSilentOnSuccess="true";                        shift ;;
    --conf) loadConf="$2";                                 shift 2 ;;
    --env)  tryDotenv=( "$2" )                             shift 2 ;;

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

# Load dotenv
[[ -v 'tryDotenv' ]] && (( ${#tryDotenv[@]} > 0 )) && dotenv "${tryDotenv[@]}" || {
  info "Failed to load env in: ${tryDotenv[@]}"; exit 2;
}

tryConf() {
  while (( $# > 0 )); do
    if [[ -f "$1" ]]; then
      . "$1" && {
        >&2 echo "Info: ${SCRIPT_NAME}: Loaded conf: '$1'";
        loadedConf="$1";
        return 0;
      } || { # Seems there is an error in config file
        info "Error: failed to load conf: '$1' rc 2";
        return 2;
      };
    else
      shift;
    fi
  done
}

loadOrTryConf() {
  # To be able to trap all output for --cron mode we need to load 
  if [[ -v 'loadConf' && "$loadConf" == '' ]]; then
    . "$loadConf" && { loadedConf="$1"; } || {
        info "Error: ${SCRIPT_NAME}: Failed to load conf '$loadConf' rc 2";
        return 2;
      }
  else
    # Not finding a file isn't an error
    # Finding a file and failing to load it is an error and we exit
    tryConf "$@" || { return $?; }
  fi
}

# loadConfOutput=`loadOrTryConf "${tryConfFiles[@]}"`
# loadConfRc=$?
# (( loadConfRc == 0 )) && [[ "$loadConfOutput" == '' ]] && unset 'loadConfOutput'

if [[ -v 'beSilentOnSuccess' ]]; then
  loadOrTryConf "${tryConfFiles[@]}" >>"$infoRecapTmp" 2>&1
else
  loadOrTryConf "${tryConfFiles[@]}"
fi
loadConfRc=$?

(( loadConfRc == 0 )) || {
  info "Error: Loading conf returned rc $loadConfRc. ${tryConfFiles[@]}"
  exit $( max 2 $loadConfRc $exitRc )
}

# BORG_CREATE=( "${SCRIPT_DIR}/backup-borg-create.sh" )

###########################
# Look for local conf
#########



# Debug
# logFile="/tmp/backup-borg.log2"
# logrotateConf="/tmp/backup-borg4"
# NICE=""
# DRYRUN="dryRun"


# [[ -f "$SCRIPT_DIR/backup-${hostname}.sh" ]] && . "$SCRIPT_DIR/backup-${hostname}.sh" || {
#   [[ -f "$SCRIPT_DIR/backup-local.sh" ]] && . "$SCRIPT_DIR/backup-local.sh";
# }

autoNice

set -- main "$@" # Pass call to main


##############################################

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

###################################################
# Main

main() {
  local rc pipeRc trace=( "$SCRIPT_NAME" "${FUNCNAME[0]}": "$@" )

  backupBorg "$@" 2>&1 | logToFile "$logFile"

  pipeRc=( ${PIPESTATUS[@]} )
  rc=$( max ${pipeRc[@]} )

  (( ${pipeRc[1]} == 0 )) && { loggedToFile="$logFile"; } || { info "Warning: failed to write to file '$logFile'"; }

  if   (( $rc == 0 )); then info "Success: '${trace[@]}' finished successfully."
  elif (( $rc == 1 )); then info "Warning: '${trace[@]}' finished with warnings. rc $rc"
  else info "Error: '${trace[@]}' finished with errors. rc $rc"; fi

  return $rc
}

# Catch the output and make a short version of the full output (to read in an email)
[[ -v 'beSilentOnSuccess' && "$beSilentOnSuccess" == "true" ]] && { # Aka cron mode
  OUTPUT=`"$@" 2>&1` || {
    rc=$?;
    
    (( rc == 1 )) && >&2 echo "** Warning **"
    (( rc  > 1 )) && >&2 echo "## ERROR ##"

    >&2 echo 
    
    # Get output last line
    >&2 echo "${OUTPUT##*$'\n'}"
    >&2 echo "##########################"
    infoRecap
    >&2 echo "##########################"

    [[ -v 'loadConfOutput' ]] && {
      >&2 echo "Loading configuration gave output:"
      >&2 echo "$loadConfOutput"
      >&2 echo "##########################"
    }

    # IFS=$'\n' outputA=( $OUTPUT )
    # nb=${#outputA[@]}

    # readarray -t outputA <<<"${OUTPUT}"
    # nb=${#outputA[@]}

    nb="${OUTPUT//[^\n]}"; nb=${#nb}

    nbHead=100
    nbTail=100

    # There is a log file and nb lines is greater than nbHead + nbTail + 100
    # We truncate
    if [[ -v 'loggedToFile' ]] && (( nb > nbHead + nbTail + 100 )); then
      head -n $nbHead <( echo "$OUTPUT" )

      echo ...
      echo "##########################"
      echo "# Truncated $(( nb - nbHead - nbTail )) lines"
      echo "# Logged into '$loggedToFile'"
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

  [[ -v 'loadConfOutput' ]] && {
    >&2 echo "Loading configuration gave output:"
    >&2 echo "$loadConfOutput"
  }
}
