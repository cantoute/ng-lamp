#!/url/bin/env bash

storeLocal() {
  local run
  local dir="$1"
  local cmd="$2"
  shift 2

  case "$cmd" in
    init)
      run=( storeLocalInit )
      ;;

    create)
      run=( storeLocalCreate )
      ;;

    prune)
      run=( storeLocalPrune )
      ;;
    
    *)
      info "Error: storeLocal: unknown command '$cmd' - accepts: init|create|prune"
      >&2 echo "storeLocal $@"
      return 2
      ;;
  esac

  "${run[@]}" "$dir" "$@"
}

storeLocalInit() {
  local dir="$1"
  local rc=0

  $DRYRUN mkdir -p "$dir"
  
  rc=$?
  
  if (( $rc == 0 )); then info "Info: storeLocalInit: successfully created $dir"
  else info "Error: storeLocalInit: could not create dir $dir"; rc=$( max 2 $rc ); # Escalade to error
  fi

  return $rc
}

# Streams stdin to file
storeLocalCreate() {
  local storeDir="$1" # set in $STORE
  shift

  local rc storeLocalInitRc mkdirRc fileSize exitRc=0

  local path="$( joinBy '/' "$@" )"
  local dir="${path%/*}"
  local filename="${path##*/}"
  local name="${filename%.*}" # removes after last dot

  # abs path to final store file
  local localPath="$( joinBy '/' "$storeDir" "$path" )"
  local localDir="${localPath%/*}"

  # local debug=( path "$path" dir "$dir" filename "$filename" name "$name" localPath "$localPath" localDir "$localDir" )
  # info "Debug: ${debug[@]@Q}"

  [[ -d "$storeDir" ]] || {
    info "Missing repo base dir: '$storeDir' we will try init the store."

    storeLocal "$storeDir" init
    
    storeLocalInitRc=$? 
    (( $storeLocalInitRc == 0 )) || info "Error: failed to init local store '$storeDir' rc $storeLocalInitRc"
    rc=$( max 2 $storeLocalInitRc ) # Error
  }

  # storeLocal requires directory to exist
  [[ -d "$localDir" ]] || {
    info "Missing local dir: $localDir"

    exitRc=$( max 1 $exitRc ) # Warning

    $DRYRUN mkdir -p "$localDir" && { $DRYRUN info "Info: created dir '$localDir'"; } || {
      info "Error: failed to create dir '$localDir'"

      exitRc=$( max 2 $exitRc ) # Error
    }
  }

  # On dry run we stop here
  [[ $DRYRUN == "" ]] || { $DRYRUN output '>' "$localPath"; cat > /dev/null; return $exitRc; }

  cat > "$localPath";
  
  rc=$?

  if (( $rc == 0 )); then
    fileSize=$( fileSize "$localPath" ) && {
      info "Success: storeLocalCreate: Stored '$localPath' ($( humanSize $fileSize ))";
    } || {
      info "Error: storeLocalCreate: could note size backup file."
      rc=$( max 2 $rc ) # Error
    }
  else
    info "Error: storeLocalCreate: failed to write to '$localPath'. rc $rc"
    rc=$( max 2 $rc ) # Error
  fi

  return $( max $rc $exitRc )
}

storeLocalPrune() {
  local storeDir="$1"
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
        info "Error: storeLocalPrune: unknown store local prune arg '$1'"
        return 2
        ;;
    esac
  done

  (( ${#finds[@]} > 0 )) || { info "Error: storeLocalPrune: prune without a find pattern (--find '*' for all) is not accepted"; return 2; }

  for find in "${finds[@]}"; do
    localFind=$( joinBy '/' "$storeDir" "$find" )
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

    if (( ${#found[@]} == 0 )); then info "Info: storeLocalPrune: No file to prune."
    else
      info "Info: storeLocalPrune: found ${#found[@]} files to prune"

      for f in "${found[@]}"; do >&2 echo "Info: storeLocalPrune: pruning '$f'"; done

      # $DRYRUN "${NICE[@]}" "${FOUND[@]}" -exec rm -f {} \;
      $DRYRUN "${NICE[@]}" "${FOUND[@]}" -delete

      rmRc=$?
      rc=$( max $rmRc $rc )

      (( $rmRc == 0 )) && {
        info "Info: storeLocalPrune: Files deleted"
      } || {
        info "Warning: storeLocalPrune: Failed to delete files."
      }
    fi
  done

  return $rc
}
