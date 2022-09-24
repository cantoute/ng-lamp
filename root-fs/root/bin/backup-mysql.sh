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

init && initUtils || {
  >2& echo "Failed to init"
  exit 2;
}

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
# meaning I'de recommend running at least one daily backup-all
dumpDbArgs=(
  # single
  --skip-lock-tables
)

dumpAllArgs=(
  # all
  --events
  --all-databases
)

########################################################
# defaults
#

BACKUP=( backup-all )
DUMP=( dump )


STORE=( store-local "${backupMysqlLocalDir}" )


########################################################
# Utils

# trap Ctrl-C
trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM


# generates backup name ex: dump-my-host-name-2022-09-22T19-42+0200
# take 1 optional arg (default to 'all')
backupMysqlName() {
  local name="${1-all}"
  
  printf "%s" "dump-${hostname}-${name}-$(now)"
}


# List mysql databases that are like
# accepts
# mysqlListDbLike db1 -db2 db3
# mysqlListDbLike db1,-db2 db3
# mysqlListDbLike "db1,-db2 db3"
mysqlListDbLike() {
  local mysqlExecSql=(mysql -Br --silent)
  local andWhere=(1)
  local like=(
    # some default db to never backup in mode=single
    -information_schema
    -performance_schema
    -mysql
    '-%trash%'
    '-%nobackup%'
  )

  # db names don't have spaces so safe to split on spaces as no ""
  like+=(${@//,/ })

  local Database="\`Database\`"

  for db in "${like[@]}"; do
    [[ "$db" == -* ]] && {
      # db name starts with '-' => NOT LIKE
      andWhere+=("${Database} NOT LIKE '${db:1}'")
    } || {
      andWhere+=("${Database} LIKE '${db}'")
    }
  done

  local sql="
    SHOW DATABASES
      WHERE
        $(joinBy ' AND ' "${andWhere[@]}")
        ;"

  echo "$sql" | "${mysqlExecSql[@]}"

  # echo ${like[@]}
  # echo $sql

  return $?
}


dump() {
  local rc

  >&2 echo "Executing: " $DRYRUN "${NICE[@]}" "$MYSQLDUMP" "$@"

  $DRYRUN "${NICE[@]}" "$MYSQLDUMP" "$@"

  rc=$?

  [[ $rc == 1 ]] && rc=2

  return $rc
}

backup-db() {
  local rc=0
  local dumpDbRc
  local dbNames=()

  while (( $# > 0 )); do
    case "$1" in
      --)
        shift
        break
        ;;
      
      *)
        dbNames+=(${1//,/ })
        shift
    esac
  done


  local plural=
  (( "${#dbNames[@]}" > 1 )) && {
    plural="s"
  }

  info "Info: backing up database$plural: ${dbNames[@]@Q}"

  # info "Info: backing up db ${dbNames[@]@Q}"

  # store "single" "$(backupMysqlName "$dbName")" compress dump "$dbName" "${dumpDbArgs[@]}" "$@"

  for db in "${dbNames[@]}"; do
    info "Info: Backing up database: '$db'"
    dump "${dumpArgs[@]}" "${dumpDbArgs[@]}" "$@" "$db" |
      onEmptyReturn 2 store "single" "$(backupMysqlName "$db").sql"

    dumpRc=$?
    rc=$( max $dumpRc $rc )

  done

  # info "Info: stored a total of $( humanSize $storeLocalTotal )"

  return $rc
}


backup-single() {
  local rc
  local like=()
  local dbNames=()

  while [[ $# > 0 ]]; do
    case "$1" in
      --like)
        like+=("$2")
        shift 2
        ;;

      --not-like)
        local notLikes=(${2//,/ })
        shift 2

        for notLike in ${notLikes[@]}; do
          like+=("-$notLike")
        done
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

  dbNames+=( $( mysqlListDbLike "${like[@]}" ) )

  (( ${#dbNames[@]} > 0 )) || {
    info "Warning: no database to backup"
    return 1
  }

  backup-db "${dbNames[@]}" -- "$@"

  rc=$?

  return $rc
}

backup-all() {
  local name="$(backupMysqlName 'all')"

  while [[ $# > 0 ]]; do
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
    onEmptyReturn 2 store "all" "${name}.sql"

  return $?
}

backup() {
  while [[ $# > 0 ]]; do
    case "$1" in
      --debug)
        shift
        DRYRUN="dryRun"
        ;;

      single|--single)
        shift

        BACKUP=( backup-single )
        ;;

      all|full|--full)
        shift

        BACKUP=( backup-all ) # default
        ;;

      db)
        shift
        local dbNames=()
        
        while [[ $# > 0 ]]; do
          case "$1" in
            -*)
              break
              ;;

            *)
              dbNames+=("${1}")
              shift
              ;;
          esac
        done

        BACKUP=( backup-db "${dbNames[@]}" -- )
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
  
  info "Starting ${BACKUP[@]} $@"

  "${BACKUP[@]}" "$@"

  rc=$?

  return $rc
}

#################
# Main

startedAt=$( nowIso )

backup "$@"

backupRc=$?
exitRc=$( max $exitRc $backupRc )

[[ $exitRc == 0 ]] && {
  info "Success: '$SCRIPT_NAME' succeeded"
} || {
  [[ $exitRc == 1 ]] && {
    info "Warning: '$SCRIPT_NAME' ended with warnings rc: $exitRc"
  } || {
    info "Error: '$SCRIPT_NAME' failed with rc: $exitRc"
  }
}

exit $exitRc
