#!/bin/bash

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="${0%/*}"
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

# source "${SCRIPT_DIR}/backup-common.sh";

#############
# Defaults
######

pgUsername=postgres
pgHostname=localhost

# backupPgAuth=( -h "$pgHostname" -U "$pgUsername" )
backupPgAuth=()

tryConfFiles=(
  "$SCRIPT_DIR/backup-${hostname}.sh"
  "$SCRIPT_DIR/backup-local.sh"
)

#############################################################################

. "${SCRIPT_DIR}/backup-common.sh" && init && initUtils || {
    >&2 echo "Error: failed to load ${SCRIPT_DIR}/backup-common.sh and init"
    exit 2
  }

[[ -v 'backupPgLocalDir' ]] || backupPgLocalDir="/home/backups/${hostname}-pg"

. "${SCRIPT_DIR}/backup-defaults.sh" || {
    >&2 echo "Error: failed to load ${SCRIPT_DIR}/backup-defaults.sh"
    exit 2
  }

############################################################################

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

backup-pg-wrap() {
  local cmd="$1"; shift
  
  set -- "$cmd" "${backupPgAuth[@]}" "$@"

  if [[ "$USER" == "$pgUsername" ]]; then
    "$@"
  else
    sudo -u "$pgUsername" -- "$@"
  fi
}

backup-pg-backup-name() {
  (( $# )) || set -- 'unnamed'
  
  printf "%s" "dump-$hostname-$( joinBy - "$@" )-$( now )"
}

backup-pg-list-db-like() {
  local like db inc=() exc=() andWhere=() sql list rc
  local psql=( backup-pg-wrap psql -At )

  like="$( joinBy , "$@" )"

  for db in ${like//,/ }; do
    case "$db" in
      -*) exc+=( "datname NOT LIKE '${db:1}'" ) ;;
	     *) inc+=( "datname     LIKE '$db'    " ) ;;
    esac
	done

  andWhere+=( 'not datistemplate' )
  andWhere+=( 'datallowconn'      )

  (( ${#inc[@]} )) && andWhere+=( "( $( joinBy ' OR  ' "${inc[@]}" ) )" )
  (( ${#exc[@]} )) && andWhere+=( "( $( joinBy ' AND ' "${exc[@]}" ) )" )

  (( ${#andWhere[@]} )) || andWhere+=( true )

  sql="select datname from pg_database where $( joinBy ' AND ' "${andWhere[@]}" ) order by datname;"

  # >&2 echo "$sql"

  list=`"${psql[@]}" -c "$sql" postgres`
  rc=$?

  (( rc == 0 )) && printf %s "$list" || {
    >&2 "${FUNCNAME[0]}: Error like:'$like' returned rc $rc (will be raised as error min 2)"
    rc=$( max 2 $rc ) # Error
  }

  return $rc
}

backup-pg-db() {
  local dir="$1"; shift
  local dump=( backup-pg-wrap pg_dump -Fp )
  local name=( ) db pipeRc thisRc rc=() schemaOnly

  while (( $# > 0 )); do
    case "$1" in
      --schema|-s) 
                  dump+=( -s );
                  name+=( 'schema-only' );
                  schemaOnly=' schema-only';
                  shift ;;

           --name) name=( "$2" );          shift 2 ;;
               -*) dump+=( "$1"     );   shift ;;
               --) shift;                break ;;
                *) break ;;
    esac
  done

  >&2 echo "adfsasadf $@ ${@//,/ }"

  for db in ${@//,/ }
  do
    info "Schema-only backup of '$db'"

    # [[ ! -v 'name' ]] && name="${dir//\//_}"
    # [[ "$name" == '' ]] && name="$db" || name="${db}-${name}"
    
    # >&2 echo "${dump[@]}" "$db"
    "${dump[@]}" "$db" |
      onEmptyReturn 2 store create "$dir" "$( backup-pg-backup-name "$db" "${name[@]}" ).sql"
    
    pipeRc=( ${PIPESTATUS[@]} )
    thisRc=$( max ${pipeRc[@]} )

    (( ${pipeRc[0]} == 0 )) || {
      info "${FUNCNAME[0]}: [!!ERROR!!] Failed to backup database $db - pg_dump rc ${pipeRc[0]}"
      info "Call: ${dump[@]} $db"
      thisRc=$( max 2 $thisRc ) # Error
    }

    rc+=( $thisRc )

    (( thisRc == 0 )) && { info "${FUNCNAME[0]}: Success: Backed up${schemaOnly-} db:'$db'"; }
    (( thisRc == 1 )) && { info "${FUNCNAME[0]}: Warning: Backing up${schemaOnly-} db:'$db' rc $thisRc"; }
    (( thisRc  > 1 )) && { info "${FUNCNAME[0]}: Error: Failed to backup${schemaOnly-} db:'$db' rc $thisRc"; }

    # if ! pg_dump -Fp -s -h "$pgHostname" -U "$pgUsername" "$DATABASE" | gzip > $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz.in_progress; then
    #   echo  1>&2
    # else
    #   mv $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz.in_progress $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz
    # fi
  done

  (( ${#rc[@]} )) || {
    info "${FUNCNAME[0]}: No database was backed up"
    rc=( 2 )
  }

  return $( max ${rc[@]} )
}

backup-pg-all() {
  local dir="$1"; shift
  local dump=( backup-pg-wrap pg_dumpall "$@" )
  local name=()

  while (( $# > 0 )); do
    case "$1" in
               --)                                 shift; break ;;
      --schema|-s) dump+=( -s ); name+=( 'schema-only' ); shift ;;
           --name) name=( "$2" );                       shift 2 ;;
               -*) dump+=( "$1" );                        shift ;;
                *)                                        break ;;
    esac
  done

  # echo 
  "${dump[@]}" |
    onEmptyReturn 2 store create "$dir" "$( backup-pg-backup-name 'all' "${name[@]}" ).sql"
}

################################################
# backup config

while (( $# )); do
  case "$1" in
    --store)
      case "$2" in
        *:*) STORE="$2";        shift 2 ;;
          *) STORE="${2}:${3}"; shift 3 ;;
      esac ;;
      
    --conf) loadConf="$2"; shift 2 ;;
    --) shift; break ;;
     *) break ;;
  esac
done

if [[ -v 'beSilentOnSuccess' ]]; then
  loadOrTryConf "${tryConfFiles[@]}" >>"$infoRecapTmp" 2>&1
else
  loadOrTryConf "${tryConfFiles[@]}"
fi
loadConfRc=$?
rc=$( max $loadConfRc ${rc-0} )

[[ -v 'BACKUP_PG_STORE' || -v 'STORE' ]] || {
  [[ -v 'backupPgLocalDir' ]] && BACKUP_PG_STORE="local:${backupPgLocalDir}"
}

[[ -v 'STORE' ]] || { [[ -v 'BACKUP_PG_STORE' ]] && STORE="$BACKUP_PG_STORE"; }

initStore

trace=( "$SCRIPT_NAME" "$@" )

backupPgMode="$1"
shift

case "$backupPgMode" in
  all|db|single|list-db-like|backup-name)
    backup-pg-$backupPgMode "$@"
    rc=$?
    ;;

  globals)
    backup-pg-all "$@" -g
    rc=$?
    ;;

  *) info "${SCRIPT_NAME}: Error: unknown backup mode: '$backupPgMode'"
    rc=2 ;;
esac


(( rc == 0 )) && { info "$SCRIPT_NAME: Success: ( ${trace[@]} )"; }
(( rc == 1 )) && { info "$SCRIPT_NAME: Warning: Backup return some warnings ( ${trace[@]} ) rc $rc"; }
(( rc  > 1 )) && {
    info "$SCRIPT_NAME: Error: at leas one backup failed ( ${trace[@]} ) rc $rc";
    info "Call: ${trace[@]}"
  }


exit $rc
