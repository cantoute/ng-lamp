#!/bin/bash

# storeLocalTotal=0
# declare -ix storeLocalTotal=0
# storeLocalTotal=0

init() {
  [[ -v 'INIT' ]] && { >&2 echo "Info: init already loaded"; return; }
  INIT=( init )

  set -u
  set -o pipefail
  set -o noclobber  # Ban override of existing files
  set -o noglob     # No magic substitutions *? etc...

  umask 027
  LC_ALL=C
  # LANG="en_US.UTF-8"

  [[ -v 'DRYRUN' ]]               || DRYRUN=
  [[ -v 'hostname' ]]             || hostname=$( hostname -s )
  [[ -v 'backupMysqlLocalDir' ]]  || backupMysqlLocalDir="/home/backups/mysql-${hostname}"

  MYSQLDUMP="$( which mysqldump )"
  FIND="$( which find )"
  TIME="$( which time ) --portability"

  COMPRESS_BZIP=( "$( which bzip2 )" -z )
  COMPRESS_GZIP=( "$( which gzip )" -c )

  [[ -v 'COMPRESS' ]] || { COMPRESS=(); compressExt=; }

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

  borgCreateArgs=()

  backupBorgMysqlArgs=()
  backupBorgMysqlSingleArgs=()

  RCLONE=( "$( which rclone )" )
}

initUtils() {
  INIT+=( initUtils )

  # Test if array contains element.
  # Usage 
  containsElement()   { local s="$1"; shift; printf '%s\0' "$@" | grep -F -x -z -- "$s"; }
  containsStartWith() { local s="$1"; shift; case "$@" in  *"two"*) echo "found" ;; esac;  }
  containsEndsWith()  { case "${myarray[@]}" in  *"two"*) echo "found" ;; esac; }
  
  # WIP: not tested
  # Will wildcard any string '*' and has only 4 modes. Aka startWith endWith StartEndWith & '*' Any (alias $#>0)
  simpleMatch() {
    local m="$1"; shift

    for e in "$@"; do
      case "$m" in
        # '')  return 1 ;; # Not matching an empty string
        '*') return ;; # Any. We got element so ok
        *'*') case "$e" in "${e::-1}"*) return ;; esac ;; # Starts with
        '*'*) case "$e" in   *"${e:1}") return ;; esac ;; # Ends with
        *'*'*'*'*) >&2 echo "Error: Not acceptable pattern: '$m"; return 10 ;;
        *'*'*) # Starts and ends with
          s1="${s%%'*'*}" # get up to first
          # s1="${s%'*'*}" # up to last
          # s2="${s##*'*'}" # gets after last
          s2="${s#*'*'}" # gets after first so $s == "$s1*$s2"
          
          # s1="${s%"*$s2"*}"

          # IFS='*' read -r -a array <<< "$2"; unset IFS # Or was it set just for the call?

          case "$e" in "$s1"*"$s2") return ;; esac
          ;;
      esac
    done

    return 1
  }
  
  info() { >&2 printf "\n%s %s\n\n" "$( LC_ALL=C date )" "$*"; }

  # Ex: DRYRUN=dryRun
  dryRun() { >&2 echo "DRYRUN: $@"; }

  dotenv() {
    local rc=1 file

    # Alternatives
    # eval "$(direnv hook bash)"
    # dotenv ~/.env.backup

    # No arg we set default
    (( $# == 0 )) && set -- .env ~/.env

    while (( $# > 0 )); do
      file="$1"; shift

      if [[ -f "$file" ]]; then
        # Poor mans load .env file and export it's vars
        set -o allexport; source "$file"; set +o allexport;
        
        rc=$?

        (( $rc == 0 )) && { # Enforce env file is not group or others readable
          local fileMode=$( stat -c %A "$file" )
          [[ "$fileMode" == *------ ]] || {
            >&2 echo "Doing: chmod go-rwx on '$file'"; chmod go-rwx "$file";
          }
        } || >&2 echo "Error: dotenv: failed to load '$file'"

        break # Stop on first file found
      fi
    done

    return $rc
  }

  now()    { date +"%Y-%m-%dT%H-%M-%S%z"; } # avoiding ':' for filenames
  nowIso() { date --iso-8601=seconds; }

  # returns max of two numbers
  # max2() { printf '%d' $(( $1 > $2 ? $1 : $2 )); }
  max2() { max "$@"; }

  # max of n numbers
  max() {
    (( $# > 0 )) || { echo "Error: max takes minimum one argument"; return 1; }
    local max=$1; shift

    for n in $@; do max=$(( $n > $max ? $n : $max )); done

    printf '%d' $max
  }

  # sum of integers
  # Ex: sum 1 2 -3 #0
  sum() { printf "%d" "$((${@/%/+}0))"; }

  # Ex: join_by , a b c #a,b,c
  # https://stackoverflow.com/questions/1527049/how-can-i-join-elements-of-an-array-in-bash
  joinBy() { local d="${1-}" f="${2-}"; shift 2 && printf %s "$f" "${@/#/$d}"; }

  # joinSplit() {
  #   local array d="$1"; shift;
  #   IFS="$d"
  #   read -r -a array <<< "$( joinBy "$d" "$@" )";
  #   printf %s "${array[@]}";
  #   unset IFS;
    
  # }

  # a="someletters_12345_moreleters.ext"
  # IFS="_"
  # set $a
  # echo $2
  # # prints 12345

  fileSize() { stat -c%s "$1" ; }

  # arg1: filename (required)
  humanSize() {
    local FRM=( numfmt --to=iec-i --suffix=B )
    local str number=$1
    shift
    
    # No decimals on Bites
    (( $number > 1024 )) && { FRM+=( --format='%.1f' ); } || { FRM+=( --format='%f' ); }

    # Human format
    str="$( "${FRM[@]}" $number )" && { printf "%s" "$str"; } || {
      info "Warning: not a number (or missing 'numfmt' in path?)"; printf "%s" $number;
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
    local readRc line emptyRc=1
    
    # if first arg is a number we consume it
    local re='^[0-9]+$'; [[ ${1-} =~ $re ]] && { emptyRc=$1; shift; }

    IFS='' read -r line
    
    readRc=$?

    [ -n "${line:+_}" ] || { >&2 echo "Error: stdin is empty, not piping. (${0##*/})"; #??
      return $emptyRc;
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
    local rc=0

    [[ -v 'COMPRESS' && -v 'compressExt' ]] || { info "Warning: compress: missing var COMPRESS[] || compressExt"
      COMPRESS=(); compressExt=''; rc=1;
    }

    (( ${#COMPRESS[@]} > 0 )) || COMPRESS=( cat );

    "${COMPRESS[@]}";

    return $( max $? $rc )
  }

  # Set repo as default
  setRepo() {
    local var repo="$1"
    shift

    var="BORG_REPO_${repo}" 
    [[ -v "$var" ]] && {
      export BORG_REPO="${!var}"
      info "Info: setRepo: Loaded $var"
    } || {
      info "Warning: setRepo: not found $var"
      rc=1
    }

    "BORG_PASSPHRASE_${repo}"
    [[ -v "$var" ]] && {
      export BORG_PASSPHRASE="${!var}"
      info "Info: setRepo: Loaded $var"
    } || {
      info "Warning: setRepo: not found $var"
      rc=1
    }
  }

  # Will look for vars BORG_REPO-$1
  # and will restaure default BORG_REPO BORG_PASSPHRASE before terminating
  usingRepo() {
    local repo="$1"
    shift

    local BORG_REPO_ORIG
    local BORG_PASSPHRASE_ORIG
    local rc
    local var

    [[ -v 'BORG_REPO' ]]       && BORG_REPO_ORIG="$BORG_REPO"
    [[ -v 'BORG_PASSPHRASE' ]] && BORG_PASSPHRASE_ORIG="$BORG_PASSPHRASE"

    var="BORG_REPO_${repo}"
    [[ -v "$var" ]] && export BORG_REPO="${!var}"

    var="BORG_PASSPHRASE_${repo}"
    [[ -v "$var" ]] && export BORG_PASSPHRASE="${!var}"

    "$@"

    rc=$?

    # Restore previous values
    [[ -v 'BORG_REPO_ORIG' ]]       && export       BORG_REPO="${BORG_REPO_ORIG}"       || unset BORG_REPO
    [[ -v 'BORG_PASSPHRASE_ORIG' ]] && export BORG_PASSPHRASE="${BORG_PASSPHRASE_ORIG}" || unset BORG_PASSPHRASE

    return $rc
  }

  createLogrotate() {
    local conf="# created by $0 on $( nowIso )"

    conf+="
  ${logFile} {
      daily
      rotate 14
      compress
      delaycompress
      nocreate
      nomissingok     # default

      # generate an error on missing
      # 24h without any logs is not normal
      notifempty
      errors ${alertEmail}
  }
  "

    [[ $DRYRUN == "" ]] || {
      echo "DryRun: not creating file ${logrotateConf}"
      echo "$conf"

      return
    }

    info "Info: missing '${logrotateConf}' use --logrotate-conf"

    >&2 echo "$conf" 

    # printf "%s" "$conf" > "$logrotateConf"
  }
}

initStore() {
  INIT+=( initStore )

  [[ -v 'SCRIPT_DIR' ]] || SCRIPT_DIR="${0%/*}"
  [[ -v 'SCRIPT_DIR' ]] || SCRIPT_NAME="${0##*/}"

  source "$SCRIPT_DIR/backup-store.sh"                \
    && source "$SCRIPT_DIR/backup-store-local.sh"     \
    && source "$SCRIPT_DIR/backup-store-rclone.sh"    \
    && {
      # set default store if required
      [[ -v 'STORE' ]] || STORE=( storeLocal "/home/backup/${hostname}" )
    } || return 1
}

# seems to brake return status 
# silentOnSuccess() {
#   # local rc OUTPUT=`"$@"; return \\$? 2>&1` || { rc=$?; echo "$OUTPUT"; return $rc; }

#   local rc=0 OUTPUT=`$( "$@" ) 2>&1;` || { rc=$?; rc=$( max $rc ${PIPESTATUS[@]} ); echo "$OUTPUT"; }
#   # local rc=0 OUTPUT=`"$@" 2>&1` || { rc=$?; echo "$OUTPUT"; }
#   return $rc
# }
