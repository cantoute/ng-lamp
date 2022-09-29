#!/url/bin/env bash

set -u
set -o pipefail

store-rclone() {
  local bucket="$1" cmd="$2"; shift 2

  case "$cmd" in
    init|create|prune|size)
      set -- "store-rclone-$cmd" "$bucket" "$@"
      ;;
    
    *)
      info "Error: store-rclone: unknown command '$action' - accepts: init|create|prune"
      >&2 echo "$0 $@";
      return 2 ;;
  esac

  "$@"
}

store-rclone-init() {
  local bucket="$1"
  local rc=0

  local rcloneInit=( "${RCLONE[@]}" mkdir "$bucket" )
  [[ "$DRYRUN" == "" ]] || rcloneInit+=( --dry-run )
  
  "${rcloneInit[@]}"

  rc=$?
  
  if (( $rc == 0 )); then info "Info: store-rclone-init: successfully created $bucket"
  else info "Error: store-rclone-init: failed to create bucket '$bucket'"; rc=$( max 2 $rc ); # Escalade to error
  fi

  return $rc
}

# Streams stdin to file
store-rclone-create() {
  local bucket="$1" # set in $STORE
  shift

  local rc mkdirRc fileSize exitRc=0

  local path="$( joinBy '/' "$@" )"
  local dir="${path%/*}"
  local filename="${path##*/}"
  local name="${filename%.*}" # Removes after last dot. Ex: file.sql.gz => file.sql

  # abs path to final store file
  local target="$( joinBy '/' "$bucket" "$path" )"


  set -- "${RCLONE[@]}" rcat "$target"

  [[ "$DRYRUN" == "" ]] || set -- --dry-run "$@"
  
  # On dry run we stop here
  [[ $DRYRUN == "" ]] || { $DRYRUN "$@"; cat > /dev/null; return $exitRc; }
  
  "$@"
  
  rc=$?

  if (( $rc == 0 )); then
    # info "Success: rclone stored '$target'";
    # fileSize=$( fileSize "$localPath" ) && {
    #   info "Success: store-rclone-create: Stored '$localPath' ($( humanSize $fileSize ))";
    # } || {
    #   info "Error: store-rclone-create: could note size backup file."
    #   rc=$( max 2 $rc ) # Error
    # }

    # store-rclone-cleanup "$bucket" || {
    #   info ""
    #   cleanupRc=$?
    #   rc=$( max $cleanupRc $rc )
    # }
    rc=$rc
  else
    rc=$( max 2 $rc ) # Error
    info "Error: store-rclone-create: failed to upload '$target'. rc $rc"
  fi

  return $( max $rc $exitRc )
}

# Delete partial uploads older than 24h
store-rclone-cleanup() {
  local bucket="$1";

  set -- "${RCLONE[@]}" backend cleanup "$@"

  [[ "$DRYRUN" == "" ]] || set -- --dry-run "$@"

  "$@"
}

store-rclone-prune() {
  info "Info: store-rclone prune not implemented"
  return
}

store-rclone-size() {
  local rc bucket="$1"
  local target="$( joinBy '/' "$@" )"

  set -- "${RCLONE[@]}" size --max-depth=2 "$target"

  "$@"
}
