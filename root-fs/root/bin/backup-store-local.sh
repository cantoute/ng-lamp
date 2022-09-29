#!/url/bin/env bash

store-local() {
  local bucket="$1" cmd="$2"; shift 2

  case "$cmd" in
    init|create|prune)
      set -- "store-local-$cmd" "$bucket" "$@"
      ;;
    
    *)
      info "Error: store-local: unknown command '$cmd' - accepts: init|create|prune"
      >&2 echo "$0 $@"
      return 2 ;;
  esac

  "$@"
}

store-local-init() {
  local bucket="$1"
  local rc=0

  $DRYRUN mkdir -p "$bucket"
  
  rc=$?
  
  if (( $rc == 0 )); then info "Info: store-local-init: successfully created $bucket"
  else info "Error: store-local-init: could not create bucket $bucket"; rc=$( max 2 $rc ); # Escalade to error
  fi

  return $rc
}

# Streams stdin to file
store-local-create() {
  local bucket="$1" # set in $STORE
  shift


  local rc storeLocalInitRc mkdirRc fileSize exitRc=0

  local path="$( joinBy '/' "$@" )"
  # local bucket="${path%/*}"
  local filename="${path##*/}"
  local name="${filename%.*}" # removes after last dot

  # abs path to final store file
  local target="$( joinBy '/' "$bucket" "$path" )"
  local targetDir="${target%/*}"
  
  # local debug=( path "$path" bucket "$bucket" filename "$filename" name "$name" target "$target" targetDir "$targetDir" )
  # info "Debug: ${debug[@]@Q}"

  [[ -d "$bucket" ]] || {
    info "Missing repo base bucket: '$bucket' we will try init the store."

    store-local "$bucket" init
    
    storeLocalInitRc=$? 
    (( $storeLocalInitRc == 0 )) || info "Error: failed to init local store '$bucket' rc $storeLocalInitRc"
    rc=$( max 2 $storeLocalInitRc ) # Error
  }

  # store-local requires existing directory
  [[ -d "$targetDir" ]] || {
    info "Missing local dir: $targetDir"

    exitRc=$( max 1 $exitRc ) # Warning

    $DRYRUN mkdir -p "$targetDir" && { $DRYRUN info "Info: created dir '$targetDir'"; } || {
      info "Error: failed to create dir '$targetDir'"

      exitRc=$( max 2 $exitRc ) # Error
    }
  }

  # On dry run we stop here
  [[ $DRYRUN == "" ]] || { $DRYRUN output '>' "$target"; cat > /dev/null; return $exitRc; }

  cat > "$target";
  
  rc=$?

  if (( $rc == 0 )); then

    fileSize=$( store-local-size "$bucket" "$path" ) && {
      info "Success: store-local-create: Stored '$target' ($fileSize)";
    } || {
      info "Error: store-local-create: could note size backup file."
      rc=$( max 2 $rc ) # Error
    }
    
  else
    info "Error: store-local-create: failed to write to '$target'. rc $rc"
    rc=$( max 2 $rc ) # Error
  fi

  return $( max $rc $exitRc )
}

store-local-size() {
  local rc bucket="$1"
  local target="$( joinBy '/' "$@" )"

  if [[ -f "$target" ]]; then
    fileSize=$( fileSize "$target" ) && {
      rc=0

      # failing humanSize will return bits
      humanSize $fileSize || printf %d $fileSize

    } || {
      info "Error: store-local-size: could note size file: '$target'"
      rc=2 # Error

      # Return nothing
    }
  elif [[ -d "$target" ]]; then
      info "Info: store-local-size: function size not implemented for directories '$target'"
  else
    # could it be symlink or dev ?
    info "Error: store-local-size: could note size: '$target'"
    rc=2 # Error
  fi

  return $rc
}

store-local-prune() {
  local bucket="$1"
  shift

  local rc=0 finds=()

  # default 10days
  local keepDays=10

  local findRc rmRc FOUND found localFind localFindDir findName

  while (( $# > 0 )); do
    case "$1" in
      --keep-days)
        keepDays="$2"
        shift 2
        ;;

      --find)
        finds+=( "$2" )
        shift 2
        ;;
      
      *)
        info "Error: store-local-prune: unknown store local prune arg '$1'"
        return 2
        ;;
    esac
  done

  (( ${#finds[@]} > 0 )) || { info "Error: store-local-prune: prune without a find pattern (--find '*' for all) is not accepted"; return 2; }

  for find in "${finds[@]}"; do
    localFind=$( joinBy '/' "$bucket" "$find" )
    localFindDir="${localFind%/*}"
    findName="${localFind##*/}"

    [[ "$localFindDir" == '' || "$localFindDir" == '/' ]] && {
      info "Error: won't prune from '$localFindDir'"
      return 2
    }

    FOUND=( "$FIND" "$localFindDir" -type f -name "$findName" -mtime +$keepDays )

    # find result into found[]
    mapfile -d $'\0' found < <( "${NICE[@]}" "${FOUND[@]}" -print0 )

    findRc=$?
    rc=$( max $findRc $rc )

    if (( ${#found[@]} == 0 )); then info "Info: store-local-prune: No file to prune."
    else
      info "Info: store-local-prune: found ${#found[@]} files to prune"

      for f in "${found[@]}"; do >&2 echo "Info: store-local-prune: pruning '$f'"; done

      # $DRYRUN "${NICE[@]}" "${FOUND[@]}" -exec rm -f {} \;
      $DRYRUN "${NICE[@]}" "${FOUND[@]}" -delete

      rmRc=$?
      rc=$( max $rmRc $rc )

      (( $rmRc == 0 )) && {
        info "Info: store-local-prune: Files deleted"
      } || {
        info "Warning: store-local-prune: Failed to delete files."
      }
    fi
  done

  return $rc
}
