#!/bin/bash

# set -u
# set -o pipefail

# storeLocalTotal=0
# declare -ix storeLocalTotal=0
# storeLocalTotal=0

init() {
  [[ -v 'INIT' ]] && { >&2 echo "Warning: init already loaded"; return; }
  INIT=init

  umask 027

  LC_ALL=C
  # LANG="en_US.UTF-8"

  hostname=$( hostname -s )

  # for now hard coded
  # TODO: accept a arg to set --local-dir
  backupMysqlLocalDir="/home/backups/mysql-${hostname}"

  MYSQLDUMP="$( which mysqldump )"
  FIND="$( which find )"
  TIME="$( which time ) --portability"

  COMPRESS_BZIP=( "$( which bzip2 )" -z )
  COMPRESS_GZIP=( "$( which gzip )" -c )

  COMPRESS=()
  compressExt=

  # auto compress default bzip2 gzip none
  if (command -v bzip2 >/dev/null 2>&1); then
    COMPRESS=( "${COMPRESS_BZIP[@]}" )
    compressExt='.bz2'
  elif( command -v gzip >/dev/null 2>&1); then
    COMPRESS=( "${COMPRESS_GZIP[@]}" )
    compressExt='.gz'
  else
    COMPRESS=()
    compressExt=
  fi

  # auto nice and ionice if they can be found in path
  NICE=()
  command -v nice >/dev/null 2>&1   && NICE+=( nice )
  command -v ionice >/dev/null 2>&1 && NICE+=( ionice -c3 )

  BORG=( borg )

  DRYRUN=

  # storeLocalTotal=0
}

initUtils() {
  info() { >&2 printf "\n%s %s\n\n" "$( LC_ALL=C date )" "$*"; }

  # Ex: DRYRUN=dryRun
  dryRun() { >&2 echo "DRYRUN: $@"; }

  now()    { date +"%Y-%m-%dT%H-%M-%S%z"; } # avoiding ':' for filenames
  nowIso() { date --iso-8601=seconds; }

  # returns max of two numbers
  # max2() { printf '%d' $(( $1 > $2 ? $1 : $2 )); }
  max2() { max "$@"; }

  # max of n numbers
  max() {
    (( $# > 0 )) || {
      echo "Error: max takes minimum one argument"
      return 1
    }

    local max=$1
    shift

    for n in $@; do max=$(( $n > $max ? $n : $max )); done

    printf '%d' $max
  }

  # sum of integers
  # Ex: sum 1 2 -3 #0
  sum() { printf "%d" "$((${@/%/+}0))"; }

  # Ex: join_by , a b c #a,b,c
  # https://stackoverflow.com/questions/1527049/how-can-i-join-elements-of-an-array-in-bash
  function joinBy {
    local d="${1-}" f="${2-}"

    shift 2 && printf %s "$f" "${@/#/$d}"
  }

  fileSize() { stat -c%s "$1" ; }

  # arg1: filename (required)
  humanSize() {
    local format
    local number=$1

    (( $number > 1024 )) && { format='%.1f'; } || { format='%f'; }

    # human format
    local humanSize="$( numfmt --to=iec-i --suffix=B --format="$format" $number )" && {
      printf "%s" "$humanSize";
    } || { info "Warning: not a number (or missing 'numfmt' in path?)"; printf "%s" $number; }
  }

  ##
  # usage
  # echo "" | on-empty-return 2 cat > /tmp/should-not-create-file || {
  #    >&2 echo "test failed, file is untouched (status $?)";
  # }
  #
  # outputs to stderr
  # Error: stdin is empty. (on-empty-return)
  # test failed, file untouched not touched (status 2)
  #
  # cmd1 | on-empty-return 2 cmd2 args
  # to output direct to file use cat
  # cmd1 | on-empty-return 2 cat > 'file'
  #
  # if cmd1 output is empty, cmd2 won't be executed and will return code 2
  # otherwise it'll return status code of cmd2 (assuming we have 'set -o pipefail')
  #
  # arg1: returned status on empty - optional default: 1
  onEmptyReturn() {
    local readRc
    local line
    local emptyRc=1
    
    # if first arg is a number we consume it
    local re='^[0-9]+$'; [[ ${1-} =~ $re ]] && { emptyRc=$1; shift; }

    IFS='' read -r line
    readRc=$?

    [ -n "${line:+_}" ] || {
      >&2 echo "Error: stdin is empty, not piping. (${0##*/})"
      return $emptyRc
    }

    { printf '%s\n' "$line"; cat; } | "$@";

    return $( max $readRc ${PIPESTATUS[@]} )
  }


  # takes 0 or n filenames where the stdin will be copied to (appended)
  logToFile() {
    (( $# == 0 )) && { cat; } || {
      local TEE=( tee --output-error=warn )
      local file

      # assuming all args are names of files we append to
      for file in "$@"; do TEE+=( -a "$file" ); done

      "${NICE[@]}" "${TEE[@]}"
    }
  }

  compress() {
    (( ${#COMPRESS[@]} == 0 )) && COMPRESS=( cat );

    "${COMPRESS[@]}"
  }

  store() {
    local rc
    local cmd="$1"
    shift

    case "$cmd" in
      init|prune)
        "${STORE[@]}" "$cmd" "$@" 
        rc=$?
        ;;

      create)
        local path="$1"
        local name="$2"
        shift 2
        
        cat | "${COMPRESS[@]}" | "${STORE[@]}" "$cmd" "$path" "${name}${compressExt}" "$@"
        rc=$( max ${PIPESTATUS[@]} )
        ;;

      *)
        info "Error: storeLocal: unknown command '$cmd' - accepts init|create|prune"
        rc=2
        ;;
    esac

    return $rc
  }

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
        info "Error: storeLocal: unknown command '$cmd' - accepts init|create|prune"
        return 2
        ;;
    esac

    run+=( "$dir" "$@" )

    "${run[@]}"
  }

  storeLocalInit() {
    local dir="$1"
    local mkdirRc
    local rc=0

    $DRYRUN mkdir -p "$dir"
    
    mkdirRc=$?

    rc=$( max $mkdirRc $rc )
    
    (( $mkdirRc == 0 )) && { info "Info: successfully created $dir";  } || {
      info "Error: could not create dir $dir"

      (( $mkdirRc == 1 )) && rc=$( max 2 $rc ) # Escalade to error
    }

    return $rc
  }

  # Streams stdin to file
  storeLocalCreate() {
    local storeDir="$1" # set in $STORE
    local path="$2"
    local filename="$3"
    shift 3

    local rc
    local mkdirRc
    local exitRc=0
    local fileSize

    local dir="$storeDir/$path"
    local file="$dir/$filename"

    # cat > /dev/null; # end of the story
    # echo "> $filename"

    [[ -d "$storeDir" ]] || {
      info "Missing repo base dir: $storeDir"

      storeLocal "$storeDir" init
      
      local storeInitRc=$?
      
      if (( $storeInitRc == 0 )); then
        info "Local store init succeed: '$storeDir'"
      else
        info "Error: failed to init local store '$storeDir' rc = $?";
      fi
    }

    [[ -d "$dir" ]] || {
      info "Missing local dir: $dir"

      exitRc=$( max 1 $exitRc ) # warning

      $DRYRUN mkdir -p "$dir" && {
        info "Info: created dir '$dir'"
      } || {
        info "Error: failed to create dir '$dir'"

        exitRc=$( max 2 $exitRc ) # error
      }
    }

    # On dry run we stop here
    [[ $DRYRUN == "" ]] || {
      $DRYRUN output '>' "$file"; cat > /dev/null;
      return $exitRc
    }

    cat > "$file";
    
    rc=$?

    (( $rc == 0 )) && fileSize=$( fileSize "$file" ) && {
      info "Success: stored '$file' ($( humanSize $fileSize ))"
    } || {
      info "Error: could note size backup to file."

      # Error returning rc=1
      # We escalade to 2, not able to size on local drive is a backup error.
      rc=$( max 2 $rc )
    }

    return $( max $rc $exitRc )
  }
}
