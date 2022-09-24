#!/bin/bash

# set -u
# set -o pipefail

# storeLocalTotal=0


# declare -ix storeLocalTotal=0

storeLocalTotal=0

init() {
  [[ ${INIT-} == "" ]] || {
    return 1
  }

  INIT=done

  umask 027

  LC_ALL=C
  # LANG="en_US.UTF-8"

  startedAt=$( date --iso-8601=seconds )

  hostname=$(hostname -s)

  # for now hard coded
  # TODO: accept a arg to set --local-dir
  backupMysqlLocalDir="/home/backups/mysql-${hostname}"

  MYSQLDUMP="$(which mysqldump)"
  FIND="$(which find)"
  TIME="$(which time) --portability"

  COMPRESS_BZIP2=("$(which bzip2)" -z)
  COMPRESS_GZIP=("$(which gzip)" -c)

  COMPRESS=()
  compressExt=

  # auto compress default bzip2 gzip none
  if (command -v bzip2 >/dev/null 2>&1); then
    COMPRESS=( "${COMPRESS_BZIP2[@]}" )
    compressExt='.bz2'
  elif( command -v gzip >/dev/null 2>&1); then
    COMPRESS=( "${COMPRESS_GZIP[@]}" );
    compressExt='.gz';
  else
    COMPRESS=()
    compressExt=
  fi

  # auto nice and ionice if they can be found in path
  NICE=()
  command -v nice >/dev/null 2>&1 && NICE+=( nice )
  command -v ionice >/dev/null 2>&1 && NICE+=( ionice -c3 )

  DRYRUN=()

  # storeLocalTotal=0
}

initUtils() {

  # DRYRUN=(dryRun)
  dryRun() {
    # cat > /dev/null;
    >&2 echo "DRYRUN: $@";
  }

  info() { >&2 printf "\n%s %s\n\n" "$( date )" "$*"; }

  now() { date +"%Y-%m-%dT%H-%M-%S%z" ; } # avoid ':' in filenames
  nowIso() { date --iso-8601=seconds ; }

  # returns max of two numbers
  # max2() { printf '%d' $(( $1 > $2 ? $1 : $2 )) ; }

  max2() { max "$@" ; }

  # max of n numbers
  max() {
    [[ $# > 0 ]] || {
      echo "Error: max takes minimum one argument"
      return 1
    }

    local max=$1
    shift

    for n in $@; do
      max=$(( $n > $max ? $n : $max ))
    done

    printf '%d' $max
  }

  sum() { printf "%d" "$((${@/%/+}0))" ; }

  # Ex: join_by , a b c #a,b,c
  # https://stackoverflow.com/questions/1527049/how-can-i-join-elements-of-an-array-in-bash
  function joinBy {
    local d="${1-}" f="${2-}"

    if shift 2; then
      printf %s "$f" "${@/#/$d}"
    fi
  }

  fileSize() { stat -c%s "$1" ; }

  # arg1: filename (required)
  humanSize() {
    local format
    local number=$1

    (( $number > 1024 )) && {
      format='%.1f'
    } || {
      format='%f'
    }

    # human format
    local humanSize="$( numfmt --to=iec-i --suffix=B --format="$format" $number )" && {
      printf "%s" "$humanSize"
    } || {
      info "Warning: not a number (or missing 'numfmt' in path?)"
      printf "%s" "$number"
    }
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
    local rc
    local readRc
    local line
    local emptyRc=1
    local re='^[0-9]+$'
    [[ ${1-} =~ $re ]] && { emptyRc=$1; shift; }

    IFS='' read -r line

    readRc=$?

    [ -n "${line:+_}" ] || { >&2 echo "Error: stdin is empty. (${0##*/})"; return $emptyRc; }

    { printf '%s\n' "$line"; cat; } | "$@"

    rc=$?

    return $(max2 $rc $readRc)
  }


  # takes 0 or n filenames where the stdin will be copied to (appended)
  logToFile() {
    if [[ $# > 0 ]]
    then
      # assuming all args are names of files we append to
      local file TEE=(tee --output-error=warn)
      for file in "$@"; do TEE+=( -a "$file" ); done

      ## consider `ionice -c3` for disk output niceness
      "${NICE[@]}" "${TEE[@]}"
    else
      # simply pipe stdin to stdout
      cat
    fi
  }


  compress() {
    [[ ${#COMPRESS[@]} == 0 ]] && COMPRESS=(cat);

    "${COMPRESS[@]}"
    
    return $?
  }

  store() {
    local path="$1"
    local name="$2"
    shift 2

    # >&2 echo "COMPRESS:${COMPRESS[@]}"

    cat | "${COMPRESS[@]}" | "${STORE[@]}" "${path}" "${name}${compressExt}"

    return $?
  }

  store-local() {
    local storeDir="$1" # set in $STORE
    local path="$2"
    local filename="$3"
    shift 3

    local rc
    local exitRc=0
    local fileSize

    local dir="$storeDir/$path"
    local file="$dir/$filename"

    # cat > /dev/null; # end of the story
    # echo "> $filename"

    [[ -d "$dir" ]] || {
      info "Missing local dir: $dir"

      exitRc=$(max2 $exitRc 1) # warning

      # lets try create it

      "${DRYRUN[@]}" mkdir -p "$dir" && {
        info "Info: successfully created $dir"
      } || {
        local mkdirRc=$?

        exitRc=$(max2 $exitRc $mkdirRc)

        info "Error: could not create dir $dir"

        exit $exitRc
      }
    }

    # info "Info: storing to local '$file'"

    if [[ "${#DRYRUN[@]}" == 0 ]]; then
      cat > "$file"
    else
      cat > /dev/null
      "${DRYRUN[@]}" "output > '$file'"
    fi

    rc=$?

    [[ $rc == 0 ]] && fileSize=$(fileSize "$file") && {
      # info "gggg ${storeLocalTotal-unset}"



      # storeLocalTotal="$( sum ${storeLocalTotal-0} $fileSize 10000000000 )"

      # printf -v storeLocalTotal
      # printf -v storeLocalTotal '%d' "${storeLocalTotal}"

      info "Success: stored '$file' ($( humanSize ${fileSize} ))"
    } || {
      info "Error: failed to write backup to file. (or to read it's size)"

      # returned rc=1
      # in here rc=1 => warning
      rc=$(max2 $rc 2)
    }

    exitRc=$(max2 $rc $exitRc)
    return $exitRc
  }
}
