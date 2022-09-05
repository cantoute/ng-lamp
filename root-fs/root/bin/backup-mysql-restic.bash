#!/usr/bin/env bash

# set -o errexit -o pipefail -o noclobber -o nounset
set -u
set -eE

set -o errexit
set -o pipefail


# set -o nounset

# don't override files
set  -o noclobber

set -o xtrace

GLOBIGNORE=*:?
umask 027
LANG="en_US.UTF-8"

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

####
MYSQLDUMP=$(which mysqldump)
TIME="$(which time) --portability"
NICE=$(which nice)
BZ2="$(which bzip2)"
GZIP="$(which gzip)"
# RESTIC="$(which restic)"
RESTIC="echo restic"

# TMPDIR="$TMPDIR"

# Initialize our own variables:
tmpdir="/tmp"
tmpFiles=("init")

verbose=0
hostName=$(hostname -s)
timestamp=$(date +%F_%H%M)

dumpArgs="--single-transaction --quick --compact --extended-insert --order-by-primary"
fullDumpArgs="-A --events"
singleDumpArgs="--skip-lock-tables"

fileExt=".sql"

compression="none"
dumpType="full"
bucket="."

nice=""


trapError() {
  local status=$?

  [ $status -eq 0 ] || {
  echo "Error!!! $status"
  exit $status
  }
}

trap '[ "$?" -eq 0 ] || echo hi' EXIT

trap trapError ERR EXIT




# while [ "$1" != " " ]
# while true
for arg in "$@"
do
  case "$1" in
    -b|--bz2|--bzip2)
      compression="bz2"
      fileExt="${fileExt}.bz2"
      shift
      ;;
    # -d|--dry-run)
    #   dryRun=true
    #   shift
    #   ;;
    -g|--gz|--gzip)
      compression="gzip"
      fileExt="${fileExt}.gz"
      shift
      ;;
    -n|--nice)
      nice=$NICE
      shift
      ;;
    -s|--single)
      # Creates files for each database
      dumpType="single"
      shift
      ;;
    -t|--target)
      target="$2"
      shift 2
      ;;
    -v|--verbose)
      verbose=1
      shift
      ;;
    --skip-lock-tables)
      dumpArgs="${dumpArgs} --skip-lock-tables"
      shift
      ;;
    --)
      shift
      break
      ;;
    '')
      break
      ;;
    *)
      echo "Error: unhandled argument '$1'"
      exit 3
      ;;
  esac
done



# Ex: compress gzip mysqldump
compress() {

  case "$1" in
    gzip|--gzip)
      shift;
      "$@" | $nice $GZIP -c
      ;;
    bz2|--bz2)
      shift;
      "$@" | $nice $BZ2 -z
      ;;
    --|none|--none)
      shift;
      "$@"
      ;;
    *)
      # echo "Warning: unhandled compress argument '$1'. Not compressing."
      "$@"
      ;;
  esac
}

storeRestic() {
  local endPoint="$1"
  shift;

  echo "saving to restic ${endPoint}"
  
  (
    "$@" > /dev/null
  ) || {
    local error=$?
    echo "Error: Failed to send to restic"
    exit $error
  }
  
  # "$@" > "$endPoint"
  
  # | $nice $RESTIC backup --stdin --stdin-filename "$1"

  # echo "$@"
}

backup() {
  local endPoint="$1"
  shift;
  
  # Sending to restic the compressed output of dump
  storeRestic "$endPoint"  "$@" 
    # compress $compression "$@"
}

tmpWrap() {
  local tmp="$1"
  shift;

  "$@" | tee -a "$tmp";
  
  # wait; echo DONE


  # [[ -r "$tmp" ]] && {

  #     2&< echo "dddddkkkkkktmp $tmp";
  # } || {
  #     echo "Tmp file '$tmp' is not writable."
  #     exit 2
  # }

  # ("$@" >> "$tmp") && {
  #   cat "$tmp"
  # }
  # >2& echo "tee output to $tmp"
  
  # "$@" | tee "$tmp"

      # >&2 echo "kkkkkktmp $tmp";

      # >&2 echo "tmp $tmp";
      # "$@" > /dev/null
      # echo "tmp: $tmp"
      # "$@"
#   || {
# echo yoyo
#     # return $?
#   }
  



  # "$@" > /dev/null

}

main() {
  case "$dumpType" in
    full)
      fileName="${hostName}-full"
      
      cmd="$nice $MYSQLDUMP $dumpArgs $fullDumpArgs"
      echo $cmd;

      # local tmp=$(mktemp --tmpdir="${tmpdir}" "mysqldump-${hostName}-${timestamp}${fileExt}.XXXXXX")
      # tmpFiles+=( "${tmp}" )

      local compress
      [$compression -eq 'none '] || {
        compress="compress ${compression}"
      }

      (
        backup "${bucket}/${fileName}${fileExt}" \
          $compress \
          $nice $MYSQLDUMP $dumpArgs $fullDumpArgs
      ) && {

        # for tmp in ${tmpFiles[@]}; do
        #   echo "deleting temp file ${tmp}"
        #   rm -f "$tmp"
        # done

        echo Success
      } || {
        ######
        # Backup somehow failed
        ######
        error=$?

        echo "Error: backup failed with status ${error}"

        # echo "Temp files where not deleted"

        # for t in ${tmpFiles[@]}; do
        #   echo "tmp: ${t}"
        # done
        
        exit $error;
      }
      
      ;;
    single)

      ;;
  esac
}

main;


# mysqldump ${mysql_args} \
#     --force \
#     --single-transaction \
#     --quick \
#     --compact \
#     --extended-insert \
#     --order-by-primary \
#     --ignore-table="${1}.sessions"