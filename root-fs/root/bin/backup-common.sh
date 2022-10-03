#!/bin/bash

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
  [[ -v 'backupMysqlLocalDir' ]]  || backupMysqlLocalDir="/home/backups/${hostname}-mysql"

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

  # self nice and ionice if they can be found in path
  command -v renice >/dev/null 2>&1 && renice -n 10 -p $$ > /dev/null
  command -v ionice >/dev/null 2>&1 && ionice -c3   -p $$ > /dev/null

  BORG=( borg )

  RCLONE=( "$( which rclone )" )
}

initDefaults() {
  INIT+=( initUtils )

  # Usage: isArray BASH_VERSINFO && echo BASH_VERSINFO is an array
  # https://stackoverflow.com/questions/14525296/how-do-i-check-if-variable-is-an-array
  isArray() {
    local variable_name=$1
    [[ "$(declare -p $variable_name 2>/dev/null)" =~ "declare -a" ]]
  }

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

  now()    { date +"%Y-%m-%dT%H-%M-%S%z"; } # avoiding ':' for filenames
  nowIso() { date --iso-8601=seconds; }

  # sum of integers
  # Ex: sum 1 2 -3 #0
  sum() { printf "%d" "$((${@/%/+}0))"; }

  # Ex: join_by , a b c #a,b,c
  # https://stackoverflow.com/questions/1527049/how-can-i-join-elements-of-an-array-in-bash
  joinBy() { local d="${1-}" f="${2-}"; shift 2 && printf %s "$f" "${@/#/$d}"; }

  # arg1: filename (required)
  fileSize() { stat -c%s "$1" ; }

  # arg1: number (required)
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

      "${TEE[@]}"
    }
  }

  compress() {
    local rc=0

    [[ -v 'COMPRESS' && -v 'compressExt' ]] || { info "Warning: compress: requires vars COMPRESS[] and compressExt"
      local COMPRESS=() compressExt=''
      rc=1  # Warning
    }

    (( ${#COMPRESS[@]} > 0 )) && {
      "${COMPRESS[@]}";
      rc=$( max $? $rc )
    } || cat;

    return $rc
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
    [[ -v "$var" ]] && {
      export BORG_REPO="${!var}";
      tryingRepoSkip="true";
    }

    var="BORG_PASSPHRASE_${repo}"
    [[ -v "$var" ]] && {
      export BORG_PASSPHRASE="${!var}";
      tryingRepoSkip="true";
    }

    "$@"

    rc=$?

    # Restore previous values
    [[ -v 'BORG_REPO_ORIG' ]]       && export       BORG_REPO="${BORG_REPO_ORIG}"       || unset BORG_REPO
    [[ -v 'BORG_PASSPHRASE_ORIG' ]] && export BORG_PASSPHRASE="${BORG_PASSPHRASE_ORIG}" || unset BORG_PASSPHRASE

    return $rc
  }

  tryingRepo() {
    local repo s

    while (( $# > 0 )); do
      case "$1" in
        --) shift; break ;;
         *) # We keep first one found and shift out the others
          [[ -v 'repo' ]] || {
            s="${1//-/_}";
            [[ -v "BORG_REPO_$s" ]] && repo="$s"
          }
          shift; ;;
      esac
    done

    [[ -v 'repo' && ! -v 'tryingRepoSkip' ]] && {
      info "Info: ${FUNCNAME[0]}: using repo: $repo"
      usingRepo "$repo" "$@";
    } || { "$@"; }
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

  getUserHome() { bash -c "cd ~$(printf %q "$1") && pwd"; }

  # Ex: DRYRUN=dryRun
  dryRun() { >&2 echo "DRYRUN: $@"; }

  infoTmp="$( mktemp /tmp/backup-${0##*/}-info-XXXXXXX )"
  trap "rm -f $infoTmp" EXIT
  info() { echo "$( LC_ALL=C date ) $*" >> "$infoTmp"; >&2 printf "\n%s %s\n\n" "$( LC_ALL=C date )" "$*"; }
  infoRecap() { >&2 cat "$infoTmp"; }


  # initStore requires initUtils
  initStore() {
    INIT+=( initStore )

    [[ -v 'SCRIPT_DIR' ]] || {
      SCRIPT_DIR="${0%/*}"; SCRIPT_NAME="${0##*/}";
    }

    source "$SCRIPT_DIR/backup-store.sh"                \
      && source "$SCRIPT_DIR/backup-store-local.sh"     \
      && source "$SCRIPT_DIR/backup-store-rclone.sh"    \
      && {
        # set default store if required
        [[ -v 'STORE' ]] || STORE="local:/home/backups/${hostname}"
      } || return $?
  }


  ###########################
  # Load defaults
  ##########

  . "$SCRIPT_DIR/backup-defaults.sh"
}

# For backward compatibility
initUtils() {
  initDefaults "$@"
}
