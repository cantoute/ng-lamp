#!/bin/bash

set -u

# dont allow override existing files
set -o noclobber

# debug
#set -o xtrace

umask 027
LANG="en_US.UTF-8"

hostname=$(hostname -s)

createDirsExit=
backupExit=
deleteExit=
checkBackupExit=
globalExit=0

MYSQLDUMP=$(which mysqldump)
TIME="$(which time) --portability"
BZIP2="$(which bzip2) -z"
GZIP="$(which gzip) -c"
FIND="$(which find)"

DRYRUN=
COMPRESS=
NICE=

backupMode="full"

backupBaseDir="/home/backups/mysql-${hostname}"
filenamePrefix="mysqldump_${hostname}_"
filenameSuffix=

verbose=

# keep full backup for N days
keepFull=3
keepSingle=$keepFull

commonArgs=
# preserve real utf8 (aka don't brake extended utf8 like emoji)
commonArgs+=" --default-character-set=utf8mb4"
commonArgs+=" --single-transaction"
commonArgs+=" --extended-insert"
commonArgs+=" --order-by-primary"
commonArgs+=" --quick" # aka swap ram for speed

fullDumpArgs="${commonArgs}"
fullDumpArgs+=" -A --events"

singleDumpArgs="${commonArgs}"
singleDumpArgs+=" --skip-lock-tables"

now() { date +%F_%H%M ; }
started=$(now)

# some helpers and error handling:
info() { printf "\n%s %s\n\n" "$( date )" "$*" >&2; }
trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM

dryRun() { echo "DRYRUN: $@"; }

# returns max of two numbers
max2() { printf '%d' $(( $1 > $2 ? $1 : $2 )); }

# OPTIONS=sdto:vngbc
# LONGOPTS=single,dry-run,time,out-path:,verbose,nice,gzip,bz2,create-dirs

time=
verbose=
createDirs=

doCreateDirs() {
  local exitStatus=0
  local dir=

  for mode in "single" "full";
  do
    dir="$backupBaseDir/$mode"
    if [[ -d "$dir" ]]; then
      info "$dir exists, nothing to do.";
    else
      $DRYRUN mkdir -p "${dir}" && \
        $DRYRUN chmod 700 "${dir}" && {
          info "Created dir '$dir'" 
        } || {
          exitStatus=$(max2 $? $exitStatus)

          info "Failed to create dir $dir"
        }
    fi
  done
  
  return $exitStatus;
}

storeBackup() {
  local dstFile=$1
  local compress=$2
  shift 2

  [[ "$compress" == "" ]] && {
    "$@" > "$dstFile"
  } || {
    "$@" | $compress > "$dstFile"
  }
}

doMysqldump() {
  local mysqldumpArgs=
  local db=
  local exitStatus=

  local name="$1"
  local mode="$2"
  shift 2

  local dir="$backupBaseDir/$mode"
  local filePath="$dir/$name"

  case "$mode" in
    single)
      mysqldumpArgs="$singleDumpArgs $1"
      shift
      ;;

    full)
      mysqldumpArgs="$fullDumpArgs"
      ;;
  esac

  info "Backing up ${filePath}"

  $DRYRUN storeBackup "${filePath}" "$NICE $COMPRESS" $NICE $MYSQLDUMP $mysqldumpArgs

  exitStatus=$?

  return $exitStatus
}

listDb() {
  local exitStatus
  local where

  [[ -v BACKUP_MYSQL_LIST_DB_WHERE ]] && where="$BACKUP_MYSQL_LIST_DB_WHERE"

  local sql="
    SHOW DATABASES
      WHERE
        \`Database\` NOT IN ('information_schema', 'performance_schema', 'mysql')
        AND \`Database\` NOT LIKE '%trash%'
        AND \`Database\` NOT LIKE '%nobackup%'
        $where
        ;
    "

  echo "$sql" | mysql -Br --silent

  exitStatus=$?
  return $exitStatus
}

backupSingle() {
  local exitStatus=0
  local thisExit
  local name
  local dbList="$@"

  info "Doing single database backups of ${dbList}"

  for db in $dbList
  do
    info "Processing '${db}'... "

    name="${filenamePrefix}${db}_$(now).sql${filenameSuffix}"

    doMysqldump "${name}" 'single' "${db}"

    thisExit=$?
    exitStatus=$(max2 $thisExit $exitStatus)

    [[ $thisExit == 0 ]] && {
      info "Done"
    } || {
      info "Error: doMysqldump '${name}' 'single' '${db}' exit status $thisExit"
    }
  done;

  [[ $exitStatus == 0 ]] && {
    info "All single database backups done"
  } || {
    info "All single database backups done (with errors)"
  }

  return $exitStatus
}

backupFull() {
  local exitStatus=
  local now=$(now)
  local name="${filenamePrefix}-full-${now}.sql${filenameSuffix}"

  info "Doing full dump (all databases)"

  doMysqldump "$name" 'full' && {
    exitStatus=$?

    info Done
  } || {
    exitStatus=$?

    info "Error: doMysqldump '${name}' 'full' exit status $exitStatus" >&2 ;
  }

  return $exitStatus
}

deleteOldBackups() {
  local exitStatus=
  local dir=
  local keep=
  local mode="$1"
  shift

  case "$mode" in
    all)
      dir="$backupBaseDir"
      keep=$(max2 $keepSingle $keepFull)
      ;;
    
    single)
      dir="$backupBaseDir/$mode"
      keep=$keepSingle
      ;;

    full)
      dir="$backupBaseDir/$mode"
      keep=$keepFull
      ;;
    *)
      info "Error: delete mode not known '$mode'"
      ;;
  esac

  if [[ "$dir" != "" && "$filenamePrefix" != "" ]]
  then
    info "Deleting backups older than ${keepSingle} days in ${dir} having prefix ${filenamePrefix}"

    $FIND "${dir}" -type f -name "${filenamePrefix}*.sql*" -mtime +$keep
    
    $DRYRUN $FIND "${dir}" -type f -name "${filenamePrefix}*.sql*" -mtime +$keep -exec rm {} \;

    exitStatus=$?
    return $exitStatus
  else
    info "Error: deleteOldBackups"

    exitStatus=1
    return $exitStatus
  fi
}

# Check we have a file that is less than 1 day old in backup dir
checkBackup() {
  local existStatus
  local mode
  local dir

  [[ $# > 0 ]] && {
    mode="$1"
    shift

    dir="$backupBaseDir/$mode"
  } || {
    dir="$backupBaseDir"
  }

  if [ "`find "$dir" -type f -ctime -1 -name "${filenamePrefix}*.sql*"`" ];
  then
    info "Info: check found backup less than 1 day old in ${dir}"
    exitStatus=0
  else
    info "Error: check didn't find backup less than 1 day old  in ${backupBaseDir}"
    exitStatus=2
  fi

  return $exitStatus
}


###########################################################
# Process args

while [[ $# > 0 ]]
do
  case "$1" in
    --create-dirs)
      createDirs="true"
      shift
      ;;

    --single)
      backupMode="single"
      shift
      ;;

    --full)
    # default
      backupMode="full"
      shift
      ;;

    --time)
      time="true"
      shift
      ;;

    --dry-run)
      DRYRUN="dryRun"
      shift
      ;;

    -v|--verbose)
      verbose="true"
      shift
      ;;

    --nice)
      NICE+=" nice"
      shift
      ;;

    --io-nice)
      NICE+=" ionice -c3"
      shift
      ;;

    --base-dir)
      backupBaseDir="$2"
      shift 2
      ;;

    -g|--gzip)
      COMPRESS="$GZIP"
      filenameSuffix=".gz"
      shift
      ;;

    -b|--bz2)
      COMPRESS="$BZIP2"
      filenameSuffix=".bz2"
      shift
      ;;

    --no-compress)
      COMPRESS=""
      filenameSuffix=""
      shift
      ;;

    --)
      shift
      break
      ;;

    *)
      break
      ;;
  esac
done

[[ "$time" == "true" ]] && {
  MYSQLDUMP="$TIME $MYSQLDUMP"
  FIND="$TIME $FIND"
}


[[ "$verbose" == "true" ]] && {
  echo "verbose: $verbose, backupMode: $backupMode, backupBaseDir: $backupBaseDir, createDirs: $createDirs, NICE: $NICE, COMPRESS: $COMPRESS, $outputFileSuffix"
  echo
}

################################
# Create dirs

[[ "$createDirs" == "true" ]] && {
  doCreateDirs || {
    createDirsExit=$?
    info "Failed to create backup dirs."

    globalExit=$(max2 $createDirsExit $globalExit)
  }

  # we create dir and stop
  exit $globalExit
}

#################################
# Main

main() {
  case "$backupMode" in
    single)
      local dbList="$(listDb)"
      local listDbExit=$?

      globalExit=$(max2 $listDbExit $globalExit)
      
      if [[ $listDbExit != 0 ]]
      then
        info "Error: failed to get list of db to backup."
      else
        backupSingle $dbList
        backupExit=$?
        globalExit=$(max2 $backupExit $globalExit)
      fi
      ;;

    full)
      backupFull
      
      backupExit=$?
      globalExit=$(max2 $backupExit $globalExit)
      ;;

    *)
      info "Error: unknown mode '$backupMode'"
      exit 3
  esac

  if [[ "$backupExit" == 0 ]];
  then
    deleteOldBackups $backupMode

    deleteExit=$?
    globalExit=$(max2 $backupExit $globalExit)
  else
    info "There were some errors during backup process, skipping deleting older backups."
  fi
}

main

###################################
# Check existing backups

checkBackup $backupMode

checkBackupExit=$?
globalExit=$(max2 $checkBackupExit $globalExit)

exit $globalExit
