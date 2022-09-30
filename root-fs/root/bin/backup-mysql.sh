#!/bin/bash

# debug
#set -o xtrace

exitRc=0

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="${0%/*}"
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

source "${SCRIPT_DIR}/backup-common.sh";

########################################################
# defaults
#

backupMysqlMode='all'

BACKUP=( backupAll )
DUMP=( dump )



init && initUtils && {
  [[ -v 'STORE' ]] || STORE=( 'local' "$backupMysqlLocalDir" )

  initStore 
} || { >&2 echo "Failed to init"; exit 2; }


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
  # --skip-lock-tables
  --routines --triggers
)

# all
dumpAllArgs=(
  --events
  --all-databases
)

# Aka store path prefix
# will be appended ( all ) or ( single ) accordingly
storePath=()

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

backupPrune() {
  local find pruneArgs keepDays=10 var dir="$1"
  shift

  while (( $# > 0 )); do
    case "$1" in
      --keep-days)
        keepDays="$2"
        shift 2 ;;
      
      *) break ;;
    esac
  done

  info "Info: backupMysql: called prune in '$dir' backups (keeping ${keepDays} days)"

  set -- --find "$dir/dump-$hostname-*.sql$compressExt" --keep-days $keepDays "$@"

  store --store "${STORE[@]}" prune "$@";
}

# backupMysqlPrune "$backupMysqlMode"
# pruneRc=$?
# exitRc=$( max $pruneRc $exitRc )


#########
# Backup folder size

backupSize() {
  store --store "${STORE[@]}" size "$@"
}

dump() {
  local rc

  # >&2 echo "Executing: " $DRYRUN "$MYSQLDUMP" "$@"

  $DRYRUN "$MYSQLDUMP" "$@"

  rc=$?

  # Escalade to error.
  (( $rc == 1 )) && rc=2

  return $rc
}

backupAll() {
  local name="$( backupMysqlName all )"
  local dir="$1"; shift

  while (( $# > 0 )); do
    case "$1" in
      --) shift; break ;;
      *)  break ;;
    esac
  done

  dump "${dumpArgs[@]}" "${dumpAllArgs[@]}" "$@" |
    onEmptyReturn 2 store create "$dir" "${name}.sql"

  return $( max ${PIPESTATUS[@]} )
}

backupDb() {
  local rc=0
  local dumpRc
  local dbNames=()
  local dir="$1"; shift
        
  while (( $# > 0 )); do
    case "$1" in
      --) shift; break ;;
      -*)
        break
        ;;

      *)
        dbNames+=( ${1//,/ } )
        shift
        ;;
    esac
  done

  local nb=${#dbNames[@]}

  if   (( $nb == 0 )); then info "Warning: backupMysql: no database to backup"; rc=$( max 1 $rc )
  elif (( $nb == 1 )); then info "Info: backupMysql: Backing up 1 database: ${dbNames[@]@Q}"
  else info "Info: Backing up ${#dbNames[@]} databases: ${dbNames[@]@Q}"; fi

  for db in "${dbNames[@]}"; do info "Info: Backing up database: '$db'"

    dump "${dumpArgs[@]}" "${dumpDbArgs[@]}" "$@" "$db" |
      onEmptyReturn 2 store create "$dir" "$( backupMysqlName "$db" ).sql"

    dumpRc=$?
    rc=$( max $dumpRc $rc )
  done

  return $rc
}

# Get database list from local server and calls backupDb dbNames[]
backupSingle() {
  local dbNames=() like=() notLike=()
  local nl dir="$1"; shift

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

      --) shift; break ;;
      *)  break ;;
    esac
  done

  # Add notLike as like with a '-' 
  for nl in "${notLike[@]}"; do like+=( "-$nl" ); done

  # Get a list of databases from local server
  dbNames+=( $( mysqlListDbLike "${like[@]}" ) )

  (( ${#dbNames[@]} )) || { info "Warning: backupMysql: no database to backup"; return 1; }

  backupDb "$dir" "${dbNames[@]}" -- "$@"
}

# Main
backupMysql() {
  local rc pruneRc sizeRc rc=0 keepDays=10

  while (( $# > 0 )); do
    case "$1" in
      --store)
        STORE=( "$2" "$3" )
        shift 3 ;;

      --keep-days)
        keepDays="$2";
        shift 2 ;;

      --debug) shift; DRYRUN="dryRun" ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  local dir="$1"; shift
  
  if (( $# > 0 )); then
    case "$1" in
      db)
        shift
        backupMysqlMode=db
        BACKUP=( backupDb )
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

  info "Info: backupMysql: Starting ${BACKUP[@]} $dir $@"

  "${BACKUP[@]}" "$dir" "$@"

  backupRc=$?

  rc=$( max $backupRc $rc )

  (( $rc == 0 )) || {
    info "backupMysql: Mysql backup returned status $rc. Skipping prune.";
    return $rc
  }

  (( keepDays > 0 )) && {
    backupPrune "$dir" --keep-days $keepDays
    pruneRc=$?; rc=$( max $pruneRc $rc )
  }

  info "Info: Total bucket size"
  backupSize
  sizeRc=$?; rc=$( max $sizeRc $exitRc )

  info "Info: Size of '$dir'"
  backupSize "$dir"
  sizeRc=$?; rc=$( max $sizeRc $rc )

  return $rc
}

#################
# backup-mysql

startedAt=$( nowIso )

trace=( "$SCRIPT_NAME" "$@" )

backupMysql "$@"

backupMysqlRc=$?
exitRc=$( max $backupMysqlRc $exitRc )

if (( $exitRc == 0 )); then
  info "Success: Backup completed successfully";
  # info "Success: $0 completed successfully rc: $exitRc";
elif (( $exitRc == 1 )); then
  info "Warning: '${trace[@]}' ended with warnings";
else
  info "Error: '${trace[@]}' failed rc: $exitRc";
fi


exit $exitRc
