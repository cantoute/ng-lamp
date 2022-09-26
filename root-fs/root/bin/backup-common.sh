#!/bin/bash

# set -u
# set -o pipefail

# storeLocalTotal=0
# declare -ix storeLocalTotal=0
# storeLocalTotal=0

init() {
  [[ -v 'INIT' ]] && { >&2 echo "Info: init already loaded"; return; }
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

  borgCreateArgs=()

  backupMysqlArgs=()
  backupMysqlSingleArgs=()
}

initUtils() {
  info() { >&2 printf "\n%s %s\n\n" "$( LC_ALL=C date )" "$*"; }

  # Ex: DRYRUN=dryRun
  dryRun() { >&2 echo "DRYRUN: $@"; }

  dotenv() {
    local rc file="${1-~/.env}"

    # Alternatives
    # eval "$(direnv hook bash)"
    # dotenv ~/.env.backup

    [[ -f "$file" ]] && {
      set -o allexport; source "$file"; set +o allexport;
      rc=$?

      local fileMode=$( stat -c %A "$file" )
      [[ "$fileMode" == *------ ]] || { >&2 echo "Doing: chmod go-rwx on '$file'"; chmod go-rwx "$file"; }
    } || { >&2 echo "Error: no such file '$file'"; rc=1; }

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

      # is in charge of compressing and adding $compressExt to filename
      create)
        (( $# > 0 )) || { info "Error: create requires at least one arg, the filename"; return $( max 2 $rd ); }

        # get last arg
        local filename="${@:$#}"
        set -- "${@:1:$#-1}" # right shift

        # unset 'args@[$#args - 1]'
        
        # $@ are dirs that will be joinBy '/' to create path
        cat | "${COMPRESS[@]}" | "${STORE[@]}" 'create' "$@" "${filename}${compressExt}"

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

    local rc mkdirRc fileSize exitRc=0

    local path="$( joinBy '/' "$@" )"
    local dir="${path%/*}"
    local filename="${path##*/}"
    local name="${filename%.*}" # removes after last dot
    # local fileExt=

    # abs path to final store file
    local localPath="$( joinBy '/' "$storeDir" "$path" )"
    local localDir="${localPath%/*}"

    # local debug=( path "$path" dir "$dir" filename "$filename" name "$name" localPath "$localPath" localDir "$localDir" )
    # info "Debug: ${debug[@]@Q}"

    [[ -d "$storeDir" ]] || { info "Missing repo base dir: '$storeDir' we will try init the store."

      storeLocal "$storeDir" init
      
      local storeLocalInitRc=$?  
      (( $storeLocalInitRc == 0 )) || info "Error: failed to init local store '$storeDir' rc = $?"
    }

    # storeLocal requires directory to exist
    [[ -d "$localDir" ]] || {
      info "Missing local dir: $localDir"

      exitRc=$( max 1 $exitRc ) # warning

      $DRYRUN mkdir -p "$localDir" && { $DRYRUN info "Info: created dir '$localDir'"; } || {
        info "Error: failed to create dir '$localDir'"

        exitRc=$( max 2 $exitRc ) # error
      }
    }

    # On dry run we stop here
    [[ $DRYRUN == "" ]] || { $DRYRUN output '>' "$localPath"; cat > /dev/null; return $exitRc; }

    cat > "$localPath";
    
    rc=$?

    (( $rc == 0 )) && fileSize=$( fileSize "$localPath" ) && { info "Success: storeLocalCreate: Stored '$localPath' ($( humanSize $fileSize ))"; } || {
      info "Error: storeLocalCreate: could note size backup to file."

      # Error returning rc=1
      # We escalade to 2, not able to size on local drive is a backup error.
      rc=$( max 2 $rc )
    }

    return $( max $rc $exitRc )
  }

  storeLocalPrune() {
    local storeDir="$1"
    shift

    local rc=0
    # defaults
    local keepDays=10
    local finds=()

    local findRc rmRc FOUND found localFind localFindDir findName

    while (( $# > 0 )); do
      case "$1" in
        --keep-days)
          keepDays="$2"
          shift 2
          ;;

        --find)
          finds+=("$2")
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
        rc=$( max $? $rc )

        (( $rmRc == 0 )) && {
          info "Info: storeLocalPrune: Files deleted"
        } || {
          info "Warning: storeLocalPrune: Failed to delete files."
        }
      fi
    done

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
    [[ -v "$var" ]] && export BORG_REPO="${!var}"

    var="BORG_PASSPHRASE_${repo}"
    [[ -v "$var" ]] && export BORG_PASSPHRASE="${!var}"

    "$@"

    rc=$?

    # Restore previous values
    [[ -v 'BORG_REPO_ORIG' ]]       && export BORG_REPO="${BORG_REPO_ORIG}"             || unset BORG_REPO
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

  # seems to brake return status 
  # silentOnSuccess() {
  #   # local rc OUTPUT=`"$@"; return \\$? 2>&1` || { rc=$?; echo "$OUTPUT"; return $rc; }

  #   local rc=0 OUTPUT=`$( "$@" ) 2>&1;` || { rc=$?; rc=$( max $rc ${PIPESTATUS[@]} ); echo "$OUTPUT"; }
  #   # local rc=0 OUTPUT=`"$@" 2>&1` || { rc=$?; echo "$OUTPUT"; }
  #   return $rc
  # }

  # subRepo() {
  #   local repoSuffix="$1"
  #   shift

  #   local exitRc=

  #   [[ -v 'BORG_REPO' ]] || {
  #     info "Error: subRepo requires BORG_REPO"
  #     return 2
  #   }

  #   local BORG_REPO_ORIG
  #   local BORG_PASSPHRASE_ORIG

  #   BORG_REPO_ORIG="${BORG_REPO}"

  #   # append repoSuffix to default repo
  #   export BORG_REPO="${BORG_REPO}-${repoSuffix}"

  #   local subRepoPassVar="BORG_PASSPHRASE_${repoSuffix}"
    
  #   [[ -v "${subRepoPassVar}" ]] && {

  #     [[ -v 'BORG_PASSPHRASE' ]] && {
  #       BORG_PASSPHRASE_ORIG="${BORG_PASSPHRASE}"
  #     }

  #     export BORG_PASSPHRASE="${!subRepoPassVar}"
  #   }

  #   "$@"

  #   exitRc=$?

  #   export BORG_REPO="${BORG_REPO_ORIG}"

  #   [[ -v 'BORG_PASSPHRASE_ORIG' ]] && {
  #     export BORG_PASSPHRASE="${BORG_PASSPHRASE_ORIG}"
  #   }

  #   return $exitRc
  # }
}
