#!/bin/bash

set -u

# important
# set -e
set -o pipefail

# dont allow override existing files
set -o noclobber

# debug
#set -o xtrace

exitRc=0
fileExt=

umask 027

LC_ALL=C

hostname=$(hostname -s)

MYSQLDUMP="$(which mysqldump)"
FIND="$(which find)"
# TIME="$(which time) --portability"
BZIP2=( "$(which bzip2)" -z )
GZIP=( "$(which gzip)" -c )

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

localStoreDir="/home/backups/mysql-${hostname}"

dumpCommonArgs=(
  --default-character-set=utf8mb4 # or die in hell if one used utf8mb4 (aka emoji)
  --single-transaction
  --extended-insert
  --order-by-primary
  --quick # aka swap ram for speed
)

dumpDbArgs=(
  --skip-lock-tables
)

dumpAllArgs=(
  -A --events
)

#defaults

# default backups all
backupMode=( backup-all )
STORE=( store-local ${localStoreDir-/home/backups/mysql-${hostname}} )
COMPRESS=("${BZIP2[@]}")
fileExt=".bz2"

# some helpers and error handling:
now() { date +"%Y-%m-%dT%H-%M%z" ; }
info() { printf "\n%s %s\n\n" "$( date )" "$*" >&2; }
trap 'echo $( date ) Backup interrupted >&2; exit 2' INT TERM

DRYRUN=
dryRun() {
  # cat > /dev/null
  >&2 echo "DRYRUN: $@";
}

# returns max of two numbers
max2() { printf '%d' $(( $1 > $2 ? $1 : $2 )); }



dump() {
  local rc

  >&2 echo "Executing: " $DRYRUN "${NICE[@]}" "$MYSQLDUMP" "$@"

  $DRYRUN "${NICE[@]}" "$MYSQLDUMP" "$@"

  rc=$?

  [[ $rc == 1 ]] && rc=2

  return $rc
}

compress() {

  "${COMPRESS[@]}"
  
  return $?
}

store() {
  local path="$1"
  local name="$2"
  shift 2

  "${STORE[@]}" "$path" "$name.sql$fileExt"

  return $?
}

store-local() {
  local storeDir="$1"
  local path="$2"
  local filename="$3"
  shift 3

  local rc
  local exitRc=0

  local dir="$storeDir/$path"
  local file="$dir/$filename"

  # cat > /dev/null; # end of the story
  # echo "> $filename"

  [[ -d "$dir" ]] || {
    info "Local dir doesn't exist: $dir"

    exitRc=$(max2 $exitRc 1) # warning

    # lets try create it

    $DRYRUN mkdir -p "$dir" && {
      info "Info: successfully created $dir"
    } || {
      local mkdirRc=$?

      exitRc=$(max2 $exitRc $mkdirRc)

      info "Error: could not create dir $dir"

      exit $exitRc
    }
  }

  info "Info: storing to local '$file'"

  if [[ $DRYRUN == "" ]]; then
    cat > "$file"
  else
    cat > /dev/null
    $DRYRUN "output > '$file'"
  fi

  rc=$?

  [[ $rc == 0 ]] && {
    info "Success: stored"
  } || {
    info "Error: failed to write backup to file."

    # returned rc=1
    # in here rc=1 => warning
    rc=2
  }

  exitRc=$(max2 $rc $exitRc)
  return $exitRc
}

# dumpOne() {
#   local dbName="$1"
#   shift

#   # database name has to come as first argument
#   dump "$dbName" "${dumpCommonArgs[@]}" "${dumpDbArgs[@]}" "$@"

#   return $?
# }

backup-db() {
  local rc=0
  local dumpDbRc
  local dbNames=()

  while [[ $# > 0 ]]; do
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

  info "Info: backing up db ${dbNames[@]@Q}"

  # store "single" "$(backupName "$dbName")" compress dump "$dbName" "${dumpDbArgs[@]}" "$@"

  for db in "${dbNames[@]}"; do
    dump "${dumpCommonArgs[@]}" "${dumpDbArgs[@]}" "$@" "$db" | compress | store "single" "$(backupName "$db")"

    dumpRc=$?
    rc=$(max2 $rc $dumpRc)
  done

  return $rc
}

# Ex: joinBy , a b c #a,b,c
# https://stackoverflow.com/questions/1527049/how-can-i-join-elements-of-an-array-in-bash
function joinBy {
  local d="${1-}" f="${2-}"

  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  fi
}

# List mysql databases that are like
# accepts
# mysqlListDbLike db1 -db2 db3
# mysqlListDbLike db1,-db2 db3
# mysqlListDbLike "db1,-db2 db3"
mysqlListDbLike() {
  local mysqlExecSql="mysql -Br --silent"
  local andWhere=(1)
  local like=(
    # some default db to never backup in mode=single
    -information_schema
    -performance_schema
    -mysql
    '-%trash%'
    '-%nobackup%'
    # db names don't have spaces so safe to split on spaces as no ""
    ${@//,/ }
  )

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

  echo "$sql" | $mysqlExecSql

  # echo ${like[@]}
  # echo $sql

  return $?
}

backup-single() {
  local rc=0
  local dbNames=()

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

  dbNames=("$(mysqlListDbLike)")

  echo "${dbNames[@]}"

  backup-db "${dbNames[@]}" -- "$@"

  # for db in "${dbNames[@]}"; do

  # done

  return $rc
}

# generates backup name
backupName() {
  local name="${1-all}"
  
  printf "%s" "dump-${hostname}-${name}-$(now)"
}

backup-all() {
  local name="$(backupName)"

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

  dump "${dumpCommonArgs[@]}" "${dumpAllArgs[@]}" "$@" --all-databases | compress | store "all" "${name}"

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

        backupMode=( backup-single )
        ;;

      all|full|--full)
        shift

        backupMode=( backup-all ) # default
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

        backupMode=( backup-db "${dbNames[@]}" -- )
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
  
  info "Starting ${backupMode[@]}"

  "${backupMode[@]}" "$@"

  rc=$?

  return $rc
}



startedAt=$( date --iso-8601=seconds )


backup "$@"

backupRc=$?
exitRc=$(max2 $exitRc $backupRc)

[[ $exitRc == 0 ]] && {
  info "Success: backup succeeded"
} || {
  [[ $exitRc == 1 ]] && {
    info "Warning: backup ended with warnings rc: $exitRc"
  } || {
    info "Error: backup failed with rc: $exitRc"
  }
}

exit $exitRc

