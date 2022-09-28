#!/url/bin/env bash

store-local() {
  local endpoint="$1" cmd="$2"; shift 2

  case "$cmd" in
    init|create|prune)
      set -- "store-local-$cmd" "$endpoint" "$@"
      ;;
    
    *)
      info "Error: store-local: unknown command '$cmd' - accepts: init|create|prune"
      >&2 echo "$0 $@"
      return 2 ;;
  esac

  "$@"
}

store-local-init() {
  local endpoint="$1"
  local rc=0

  $DRYRUN mkdir -p "$endpoint"
  
  rc=$?
  
  if (( $rc == 0 )); then info "Info: store-local-init: successfully created $endpoint"
  else info "Error: store-local-init: could not create endpoint $endpoint"; rc=$( max 2 $rc ); # Escalade to error
  fi

  return $rc
}

# Streams stdin to file
store-local-create() {
  local endpoint="$1" # set in $STORE
  shift


  local rc storeLocalInitRc mkdirRc fileSize exitRc=0

  local path="$( joinBy '/' "$@" )"
  # local endpoint="${path%/*}"
  local filename="${path##*/}"
  local name="${filename%.*}" # removes after last dot

  # abs path to final store file
  local target="$( joinBy '/' "$endpoint" "$path" )"
  local targetDir="${target%/*}"
  
  # local debug=( path "$path" endpoint "$endpoint" filename "$filename" name "$name" target "$target" targetDir "$targetDir" )
  # info "Debug: ${debug[@]@Q}"

  [[ -d "$endpoint" ]] || {
    info "Missing repo base endpoint: '$endpoint' we will try init the store."

    store-local "$endpoint" init
    
    storeLocalInitRc=$? 
    (( $storeLocalInitRc == 0 )) || info "Error: failed to init local store '$endpoint' rc $storeLocalInitRc"
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
    fileSize=$( fileSize "$target" ) && {
      info "Success: store-local-create: Stored '$target' ($( humanSize $fileSize ))";
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

store-local-prune() {
  local endpoint="$1"
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
    localFind=$( joinBy '/' "$endpoint" "$find" )
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
