#!/bin/bash

set -u

# important
# set -e
set -o pipefail

# dont allow override existing files
set -o noclobber

# debug
#set -o xtrace

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="${0%/*}"

SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

source "${SCRIPT_DIR}/backup-common.sh";

init && initUtils || { >&2 echo "Failed to init"; exit 2; }

exitRc=0

# debug
# NICE=( dryRun )


########
# Usage
#
# backup-mysql.sh proceeds a mysqldump --all-databases
#
# backup-mysql.sh db db1 db2,db3 -- -any-extra-param-to-mysql-dump
#
#


dumpArgs=(
  # aka common args for all backups
  --default-character-set=utf8mb4 # or die in hell if one used utf8mb4 (aka emoji)
  --single-transaction
  --extended-insert
  --order-by-primary
  --quick # aka swap ram for speed
)

# on single db backup avoid locking users and accept the risk
# meaning I'de recommend running at least one daily backupAll
# single
dumpDbArgs=(
  --skip-lock-tables
)

# all
dumpAllArgs=(
  --events
  --all-databases
)

# Aka store path prefix
# will be appended ( all ) or ( single ) accordingly
storePath=()

backupPruneArgs=()
backupPruneArgs_db=(     --keep-days 2 )
backupPruneArgs_all=(    --keep-days 2 )
backupPruneArgs_single=( --keep-days 2 )


########################################################
# defaults
#

backupMysqlMode='all'

BACKUP=( backupAll )
DUMP=( dump )
STORE=( storeLocal "$backupMysqlLocalDir" )

########################################################
# Utils

# trap Ctrl-C
trap '>&2 echo $( date ) Backup interrupted; exit 2' INT TERM


# generates backup name ex: dump-my-host-name-2022-09-22T19-42+0200
# take 1 optional arg (default to 'all')
backupMysqlName() {
  local name="${1-all}"
  
  printf "%s" "dump-$hostname-$name-$( now )"
}


# List mysql databases that are like
# accepts
# mysqlListDbLike db1 -db2 db3
# mysqlListDbLike db1,-db2 db3
# mysqlListDbLike "db1,-db2 db3"
mysqlListDbLike() {
  local mysqlExecSql=( mysql -Br --silent )
  local andWhere=( 1 )
  local like=(
    # some default db to never backup in mode=single
    -information_schema
    -performance_schema
    -mysql
    '-%trash%'
    '-%nobackup%'
  )

  # db names don't have spaces so safe to split on spaces as no ""
  like+=( ${@//,/ } )

  for db in "${like[@]}"; do
      # db name starting with '-' => NOT LIKE
    [[ "$db" == -* ]] && { andWhere+=("\`Database\` NOT LIKE '${db:1}'"); } || {
      andWhere+=("\`Database\` LIKE '${db}'")
    }
  done

  echo "SHOW DATABASES WHERE $( joinBy ' AND ' "${andWhere[@]}" );" |
    "${mysqlExecSql[@]}"
}


dump() {
  local rc

  # >&2 echo "Executing: " $DRYRUN "${NICE[@]}" "$MYSQLDUMP" "$@"

  $DRYRUN "${NICE[@]}" "$MYSQLDUMP" "$@"

  rc=$?

  # Escalade to error.
  (( $rc == 1 )) && rc=2

  return $rc
}

backupAll() {
  local name="$( backupMysqlName all )"

  while (( $# > 0 )); do
    case "$1" in
      --)
        shift
        break
        ;;

      *)
        break
        ;;
    esac
  done

  dump "${dumpArgs[@]}" "${dumpAllArgs[@]}" "$@" |
    onEmptyReturn 2 store create "all" "${name}.sql"

  return $( max ${PIPESTATUS[@]} )
}

backupDb() {
  local rc=0
  local dumpRc
  local dbNames=()

  while (( $# > 0 )); do
    case "$1" in
      --)
        shift
        break
        ;;
      
      *)
        # split on commas
        dbNames+=(${1//,/ })
        shift
    esac
  done

  local nb=${#dbNames[@]}

  if   (( $nb == 0 )); then info "Warning: backupMysql: no database to backup"; rc=$( max 1 $rc )
  elif (( $nb == 1 )); then info "Info: backupMysql: Backing up 1 database: ${dbNames[@]@Q}"
  else info "Info: Backing up ${#dbNames[@]} databases: ${dbNames[@]@Q}"; fi

  for db in "${dbNames[@]}"; do info "Info: Backing up database: '$db'"

    dump "${dumpArgs[@]}" "${dumpDbArgs[@]}" "$@" "$db" |
      onEmptyReturn 2 store create "single" "$( backupMysqlName "$db" ).sql"

    dumpRc=$?
    rc=$( max $dumpRc $rc )
  done

  return $rc
}

# Get database list from local server and calls backupDb dbNames[]
backupSingle() {
  local dbNames=()
  local like=()
  local nl notLike=()

  while (( $# > 0 )); do
    case "$1" in
      --like)
        # split on comma or space
        like+=( ${2//,/ } )
        shift 2
        ;;

      --not-like)
        # split on comma or space
        notLike+=( ${2//,/ } )
        shift 2
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

  # Add notLike as like with a '-' 
  for nl in "${notLike[@]}"; do like+=( "-$nl" ); done

  # Get a list of databases from local server
  dbNames+=( $( mysqlListDbLike "${like[@]}" ) )

  (( ${#dbNames[@]} > 0 )) || { info "Warning: backupMysql: no database to backup" return 1; }

  backupDb "${dbNames[@]}" -- "$@"
}

# Main
backupMysql() {
  local backupRc
  local rc=0

  # backupMysqlMode="$1"
  # shift

  if (( $# > 0 )); then
    case "$1" in
      db)
        shift
        backupMysqlMode=db
        local dbNames=()
        
        while (( $# > 0 )); do
          case "$1" in
            -*)
              break
              ;;

            *)
              dbNames+=( "$1" )
              shift
              ;;
          esac
        done

        BACKUP=( backupDb "${dbNames[@]}" -- )
      ;;

      single)
        shift
        backupMysqlMode=single
        BACKUP=( backupSingle )
        ;;

      all)
        shift
        backupMysqlMode=all
        BACKUP=( backupAll )
        ;;

      *) ;; # Assuming default all following args are kept
    esac
  fi

  while (( $# > 0 )); do
    case "$1" in
      --dir|--store-local-dir)
      # TODO : wrap store load?
        backupMysqlLocalDir="$2"
        shift 2

        STORE=( storeLocal "${backupMysqlLocalDir}" )

        #TODO : use this
        # STORE_LOCAL=( storeLocal "${backupMysqlLocalDir}" )
        ;;

      --debug) shift; DRYRUN="dryRun";;
      --) shift; break;;
      *) break;;
    esac
  done
  
  storePath+=( "$backupMysqlMode" )

  info "backupMysql: Starting ${BACKUP[@]} $@"

  "${BACKUP[@]}" "$@"

  backupRc=$?

  rc=$( max $backupRc $rc )

  (( $rc == 0 )) || { info "backupMysql: Mysql backup returned non-zero status. Skipping old backups delete."; }

  return $rc
}

#################
# backup-mysql

startedAt=$( nowIso )

trace=( "$SCRIPT_NAME" "$@" )

backupMysql "$@"

backupMysqlRc=$?
exitRc=$( max $backupMysqlRc $exitRc )

if   (( $exitRc  > 1 )); then info "Error: '${trace[@]}' failed with rc: $exitRc";
  exit $exitRc;
elif (( $exitRc == 1 )); then info "Warning: '${trace[@]}' ended with warnings rc: $exitRc";
  exit $exitRc;
elif (( $exitRc == 0 )); then info "Success: '${trace[@]}' completed successfully rc: $exitRc";
fi

# No errors, we can prune.


backupMysqlPrune() {
  local find pruneArgs modeArgs var mode="$1"
  shift

  info "Info: backupMysql: called prune for '$mode' backups."

  case $mode in
    all|db|single)
      pruneArgs=( "${backupPruneArgs[@]}" )

      # add args for $mode
      modeArgs="backupPruneArgs_${mode}"
      
      [[ -v "$modeArgs" ]] && {
        var="${modeArgs}[@]"
        pruneArgs+=( "${!var}" )
      }

      # limit to
      find="$mode/dump-$hostname-*.sql$compressExt"
      pruneArgs+=( --find "$find" )

      store prune "${pruneArgs[@]}";

      pruneRc=$?
      exitRc=$( max $pruneRc $exitRc )
      ;;

    *)
      info "Warning: backupMysql: Skipping backupMysql prune unknown: '$backupMysqlMode'"
      exitRc=$( max 1 $exitRc )
      ;;
  esac
}

backupMysqlPrune "$backupMysqlMode"

exit $exitRc
