#!/bin/bash

umask 027
LANG="en_US.UTF-8"

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

# Initialize our own variables:
verbose=false

MYSQLDUMP=$(which mysqldump)
TIME="$(which time) --portability"
NICE=$(which nice)
BZ2="$(which bzip2) -z"
GZIP="$(which gzip) -c"
FIND="$(which find)"

DRYRUN=

COMPRESS="cat -"

dateStamp=$(date +%F_%H%M)

srcHost=$(hostname -s)

outPath="/home/backups/mysql-${srcHost}"

fullDumpArgs="-A --events --single-transaction"
singleDumpArgs="--skip-lock-tables --single-transaction"

# More safety, by turning some bugs into errors.
# Without `errexit` you don’t need ! and can replace
# PIPESTATUS with a simple $?, but I don’t do that.
set -o errexit -o pipefail -o noclobber -o nounset
# set -o pipefail -o noclobber -o nounset

set -o errexit -o nounset -o xtrace

GLOBIGNORE=*:?

# stop on error - if backup fails old ones aren't deleted
# set -e



# -allow a command to fail with !’s side effect on errexit
# -use return value from ${PIPESTATUS[0]}, because ! hosed $?
! getopt --test > /dev/null 
if [[ ${PIPESTATUS[0]} -ne 4 ]]; then
    echo 'I’m sorry, `getopt --test` failed in this environment.'
    exit 1
fi

OPTIONS=sdto:vngbc
LONGOPTS=single,dry-run,time,out-path:,verbose,nice,gzip,bz2,create-dirs

# -regarding ! and PIPESTATUS see above
# -temporarily store output to be able to check for errors
# -activate quoting/enhanced mode (e.g. by writing out “--options”)
# -pass arguments only via   -- "$@"   to separate them correctly
! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@")
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    # e.g. return value is 1
    #  then getopt has complained about wrong arguments to stdout
    exit 2
fi
# read getopt’s output this way to handle the quoting right:
eval set -- "$PARSED"

dryrun() {
    if [[ ! -t 0 ]]
    then
        cat
    fi
    printf -v cmd_str '%q ' "$@"; echo "DRYRUN: Not executing $cmd_str" >&2
}

checkDirs() {
  local args=("$@")

  # for d in "${args[@]}"
  #   do
      # if not is a dir
      d=$1
      if [[ -d "$d" ]]; then
        [[ $verbose = true ]] && {
          echo "$d exists, nothing to do.";
          echo;
        }
      else
        $DRYRUN mkdir -p "${d}";
        $DRYRUN chmod 700 "${d}";
      fi
    # done;
  
  return 0;
}

single=false time=false dryRun=false verbose=false nice=false gzip=false bz2=false createDirs=false
# now enjoy the options in order and nicely split until we see --

while true; do
  case "$1" in
    -c|--create-dirs)
      createDirs=true
      shift
      ;;
    -s|--single)
      single=true
      shift
      ;;
    -t|--time)
      time=true
      shift
      ;;
    -d|--dry-run)
      dryRun=true
      shift
      ;;
    -v|--verbose)
      verbose=true
      shift
      ;;
    -n|--nice)
      nice=true
      shift
      ;;
    -o|--out-path)
      outPath="$2"
      shift 2
      ;;
    -g|--gzip)
      gzip=true
      shift
      ;;
    -b|--bz2)
      bz2=true
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Error: unhandled argument '$1'"
      exit 3
      ;;
  esac
done

# handle non-option arguments
# if [[ $# -ne 1 ]]; then
#     echo "$0: A single input file is required."
#     exit 4
# fi

[[ $dryRun = true ]] && {
  DRYRUN="dryrun"
}

[[ $single = true ]] \
  && outPath="${outPath}/single" \
  || outPath="${outPath}/full"


[[ $time = true ]] && {
  MYSQLDUMP="$TIME $MYSQLDUMP"
  FIND="$TIME $FIND"
}


if [[ $gzip = true ]]; then
  COMPRESS=$GZIP
else
  if [[ $bz2 = true ]]; then
    COMPRESS=$BZ2
  fi
fi

# [[ ($gzip = true || $bz2 = true)  && $nice = true ]] && {
#   COMPRESS="$NICE $COMPRESS"
# }

[[ $verbose = true ]] && {
  echo "verbose: $verbose, dryRun: $dryRun, single: $single, outPath: $outPath, createDirs: $createDirs, nice: $nice, gzip: $gzip, bz2: $bz2"
  echo
}

[[ $createDirs = true ]] && {
  dirs2check=("${outPath}")
  checkDirs "${dirs2check[@]}"
}

runBackup() {
  local mysqldumpArgs=$fullDumpArgs
  local db=

  [[ $1 = '--db' ]] \
    && {
      db=$2
      mysqldumpArgs="$singleDumpArgs $db"
      shift
      shift
    }

  local outFile=$1
  local COMPRESS=

  if [[ $gzip = true ]]; then
    outFile="${outFile}.gz"
    COMPRESS="$GZIP"
  else
    if [[ $bz2 = true ]]; then
      outFile="${outFile}.bz2"
      COMPRESS="$BZ2"
    fi
  fi

  echo "Backing up into ${outFile}"

  if [[ $gzip = true || $bz2 = true ]]; then
    [[ $nice = true ]] && COMPRESS="$NICE $COMPRESS"

    [[ $dryRun = true ]] \
      && echo "DRYRUN: Not executing $MYSQLDUMP $mysqldumpArgs | $COMPRESS > ${outFile}" \
      || {
        $MYSQLDUMP $mysqldumpArgs | $COMPRESS > "${outFile}"
      }
  else
    [[ $dryRun = true ]] \
      && echo "DRYRUN: Not executing $MYSQLDUMP $mysqldumpArgs > ${outFile}" \
      || {
        $MYSQLDUMP $mysqldumpArgs > "${outFile}"
      }
  fi
}

if [[ $single = true ]];
then
  echo "Doing single database backups..."

  dbList=$(mysql -Br --silent <<<
    "
      SHOW databases
      WHERE \`Database\`
        NOT IN ('information_schema', 'performance_schema', 'mysql')
        AND \`Database\` NOT LIKE '%trash%'
        AND \`Database\` NOT LIKE '%nobackup%'
        ;
    "
  )

  for db in $dbList
  do
    echo
    echo "Processing '${db}'... "

    outFile="${outPath}/mysqldump_${srcHost}_${db}_$(date +%F_%H%M).sql"

    runBackup --db "${db}" "${outFile}"

    echo Done
  done;

  echo
  echo "Single database backups done"
else
  echo "Doing full dump (all databases)"

  outFile="${outPath}/mysqldumpall_${srcHost}_${dateStamp}.sql"

  runBackup $outFile

  echo
  echo "Full dump done" 
fi

deleteOldBackups() {
  echo
  echo "Deleting old backups"

  if [[ $single = true ]]; then
      # delete single database backup older than 3 days
      $DRYRUN $FIND "${outPath}" -type f -name 'mysqldump_*.sql*' -mtime +3 -exec rm {} \;
  else
      # delete full backups older then 30 days
      $DRYRUN $FIND "${outPath}" -type f -name 'mysqldumpall_*.sql*' -mtime +31 -exec rm {} \;
  fi

  echo "Done"
}

deleteOldBackups

echo
