#!/usr/bin/env bash

# set -o errexit -o pipefail -o noclobber -o nounset
set -u
set -eE

set -o errexit
set -o pipefail

RESTIC_PASSWORD=toto

# set -o nounset

# don't override files
set  -o noclobber

# set -o xtrace

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
RESTIC="$(which restic)"
# RESTIC="echo restic"

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
resticRepo="/tmp/toto"
resticPath=""

export RESTIC_PASSWORD="toto"

nice=""

trapSig() {
  echo "signal"
}

trapError() {
  local status=$?

  [ $status -eq 0 ] || {
    echo "Error!!! $status"
    exit $status
  }
}

# trap '[ "$?" -eq 0 ] || echo hi' EXIT

trap trapError ERR  SIGINT
# trap trapSig SIGINT

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
    -r|--repo)
      resticRepo="$2"
      shift 2
      ;;
    -p|--path)
      resticPath="$2"
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
  local cmp="$1"

  case "$cmp" in
    gzip|--gzip)
      shift;
      $nice $GZIP -c
      ;;
    bz2|--bz2)
      shift;
      $nice $BZ2 -z
      ;;
    none|--none|--)
      shift;
      cat -
      ;;
    *)
      cat -
      ;;
    # *)
    #   # shift;
    #   # echo "Warning: unhandled compress argument '$1'. Not compressing."
    #   # cat -
    #   ;;
  esac
  
  # echo "is this executed"
  # cat -
}

storeRestic() {
  local repo="$1"
  local path="$2"
  local fileName="$3"
  local fileExt="$4"
  shift 4;

  echo "Uploading to repo:${repo} path:${path}/${fileName}${fileExt}"
  
  (
    # cat - > /dev/null
    $nice $RESTIC -r "${repo}" backup --stdin --stdin-filename "${path}/${fileName}${fileExt}"
  ) || {
    local error=$?
    echo "Error: Failed to send to restic"
    return $error
  } && {
    echo "restic success"
  }
  
  # "$@" > "$fileName"
  
  # | $nice $RESTIC backup --stdin --stdin-filename "$1"

  # echo "$@"
}

backup() {
  local repo="$1"
  local path="$2"
  local fileName="$3"
  local fileExt="$4"
  local tmp="$5"
  shift 5;
  
      # local tmp=$(mktemp --tmpdir="${tmpdir}" "mysqldump-${hostName}-${timestamp}${fileExt}.XXXXXX")
      # tmpFiles+=( "${tmp}" )

  # Sending to restic the compressed output of dump
  
    # compress $compression "$@"

  # cat - >> "$tmp";
  storeRestic "$repo" "$path" "$fileName" "$fileExt" || { 
    local status=$?
    echo status $status
    echo "Storing to restic failed ${status}"
    
    return $status
  } && {
    echo "Sent to restic"
  }

  # {
  #   cat "$tmp" | storeRestic "$fileName" || {
  #     echo "failed %% ${tmp}"
  #   }
  # }
}

viaTmp() {
  local tmp="$1"
  shift;

  # tee -a "$tmp" || {
  #   echo "Error: not deleting tmp file ${tmp}"
  # } && {
  #   wait
  #   rm -f "$tmp"
  # }

  cat - >> "$tmp" && {
      cat "$tmp" || {
      echo "failed %% ${tmp}"
      return $status
    }
  }

  
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
      local fileName="mysqldump-${hostName}-full"
      local path
      
      [ "$resticPath" -eq "" ] || {
        path="$resticPath"
      } && {
        path="/mysql/full"
      }
      
      cmd="$nice $MYSQLDUMP $dumpArgs $fullDumpArgs"
      echo $cmd;

      local tmp=$(mktemp --tmpdir="${tmpdir}" "${fileName}-${timestamp}${fileExt}.XXXXXX")
      tmpFiles+=( "${tmp}" )

      echo "temp file ${tmp}"

      

      # local compress
      # [$compression -eq 'none '] || {
      #   compress="compress ${compression}"
      # }

      local args="${dumpArgs} ${fullDumpArgs}"

      $nice $MYSQLDUMP $args \
        | compress "${compression}" \
        | backup "$resticRepo" "$path" "${fileName}" "${fileExt}" "$tmp"

      # (
      #   backup "${bucket}/${fileName}${fileExt}" \
      #     $compress \
      #     $nice $MYSQLDUMP $dumpArgs $fullDumpArgs
      # ) && {

      #   # for tmp in ${tmpFiles[@]}; do
      #   #   echo "deleting temp file ${tmp}"
      #   #   rm -f "$tmp"
      #   # done

      #   echo Success
      # } || {
      #   ######
      #   # Backup somehow failed
      #   ######
      #   error=$?

      #   echo "Error: backup failed with status ${error}"

      #   # echo "Temp files where not deleted"

      #   # for t in ${tmpFiles[@]}; do
      #   #   echo "tmp: ${t}"
      #   # done
        
      #   exit $error;
      # }
      
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