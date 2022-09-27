#!/url/bin/env bash

set -u
set -o pipefail

storeS3() {
  local cmd endpoint="$1" action="$2"; shift 2

  case "$action" in
    init)   cmd=( storeS3Init )   ;;
    create) cmd=( storeS3Create ) ;;
    prune)  cmd=( storeS3Prune )  ;;
    
    *) info "Error: storeS3: unknown command '$action' - accepts: init|create|prune"
       >&2 echo "storeS3 $@"; return 2 ;;
  esac

  "${cmd[@]}" "$endpoint" "$@"
}

storeS3Init() {
  local endpoint="$1"
  local rc=0

  local rcloneInit=( "${RCLONE[@]}" mkdir "$endpoint" )
  [[ "$DRYRUN" == "" ]] || rcloneInit+=( --dry-run )
  
  "${rcloneInit[@]}"

  rc=$?
  
  if (( $rc == 0 )); then info "Info: storeS3Init: successfully created $endpoint"
  else info "Error: storeS3Init: failed to create bucket '$endpoint'"; rc=$( max 2 $rc ); # Escalade to error
  fi

  return $rc
}

# Streams stdin to file
storeS3Create() {
  local endpoint="$1" # set in $STORE
  shift

  local rc storeS3InitRc mkdirRc fileSize exitRc=0

  local path="$( joinBy '/' "$@" )"
  local dir="${path%/*}"
  local filename="${path##*/}"
  local name="${filename%.*}" # Removes after last dot. Ex: file.sql.gz => file.sql

  # abs path to final store file
  local target="$( joinBy '/' "$endpoint" "$path" )"

  # On dry run we stop here
  # [[ $DRYRUN == "" ]] || { $DRYRUN output '>' "$localPath"; cat > /dev/null; return $exitRc; }

  local rcloneCat=( "${RCLONE[@]}" rcat "$target" )
  [[ "$DRYRUN" == "" ]] || rcloneCat+=( --dry-run )
  
  "${rcloneCat[@]}"
  
  rc=$?

  if (( $rc == 0 )); then
    fileSize=$( fileSize "$localPath" ) && {
      info "Success: storeS3Create: Stored '$localPath' ($( humanSize $fileSize ))";
    } || {
      info "Error: storeS3Create: could note size backup file."
      rc=$( max 2 $rc ) # Error
    }

    # Delete partial uploads older than 24h
    local rcloneCleanup=( "${RCLONE[@]}" backend cleanup "$endpoint" )
    [[ "$DRYRUN" == "" ]] || rcloneCleanup+=( --dry-run )
    
    "${rcloneCleanup[@]}" || {
      info ""
      cleanupRc=$?
      rc=$( max $cleanupRc $rc )
    }
  else
    info "Error: storeS3Create: failed to upload '$localPath'. rc $rc"
    rc=$( max 2 $rc ) # Error
  fi

  return $( max $rc $exitRc )
}

storeS3Prune() {
  info "Info: storeS3 prune not implemented"
  return
}
