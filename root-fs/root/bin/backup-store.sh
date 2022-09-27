#!/url/bin/env bash

[[ -v 'INIT' ]] || {
  SCRIPT_DIR="${0%/*}"
  SCRIPT_NAME="${0##*/}"
  SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

  source "${SCRIPT_DIR}/backup-common.sh";
  init && initUtils && {
    [[ -v 'STORE' ]] || {
      # source "${SCRIPT_DIR}/backup-store-local.sh";
      STORE=( storeLocal "/home/backup/${hostname}" );
      initStore
    }
  }
}

# source "${SCRIPT_DIR}/backup-store-local.sh";
# source "${SCRIPT_DIR}/backup-store-borg.sh";

# [[ -v 'COMPRESS' ]] || {
#   COMPRESS_BZIP=( "$( which bzip2 )" -z )
#   COMPRESS_GZIP=( "$( which gzip )" -c )

#   COMPRESS=()
#   compressExt=

#   # auto compress default bzip2 gzip none
#   if (command -v bzip2 >/dev/null 2>&1); then
#     COMPRESS=( "${COMPRESS_BZIP[@]}" )
#     compressExt='.bz2'
#   elif( command -v gzip >/dev/null 2>&1); then
#     COMPRESS=( "${COMPRESS_GZIP[@]}" )
#     compressExt='.gz'
#   else
#     COMPRESS=()
#     compressExt=
#   fi
# }

# [[ -v 'NICE' ]] || {
#   # auto nice and ionice if they can be found in path
#   NICE=()
#   command -v nice >/dev/null 2>&1   && NICE+=( nice )
#   command -v ionice >/dev/null 2>&1 && NICE+=( ionice -c3 )
# }

# STORE=( store-local /path/to/store )

store() {
  local ZIP zipExt rc=0 cmd="$1"; shift

  [[ -v 'STORE' ]] || { info "Error: store requires var STORE. Ex: STORE=( storeLocal /path/to/store )";
    return 2
  }
  
  [[ -v 'COMPRESS' && -v 'compressExt' ]] && { ZIP=( "${COMPRESS[@]}" ); zipExt="$compressExt"; } || {
    info "Warning: store requires var COMPRESS[] and compressExt to use compression"
    rc=1; ZIP=(); zipExt=''
  }

  (( ${#ZIP[@]} == 0 )) || { ZIP=( cat ); zipExt=''; }

  case "$cmd" in
    init|prune)
      "${STORE[@]}" "$cmd" "$@" 
      rc=$( max $? $rc )
      ;;

    # is in charge of compressing and adding $compressExt to filename
    create)
      (( $# > 0 )) || { info "Error: create requires at least one arg, the filename"; return $( max 2 $rd ); }

      # get last arg
      local filename="${@:$#}"
      set -- "${@:1:$#-1}" # right shift

      # unset 'args@[$#args - 1]'
      
      # $@ are dirs that will be joinBy '/' to create path
      cat | "${ZIP[@]}" | "${STORE[@]}" 'create' "$@" "${filename}${zipExt}"

      rc=$( max ${PIPESTATUS[@]} $rc )
      ;;

    *)
      info "Error: storeLocal: unknown command '$cmd' - accepts init|create|prune"
      rc=2 ;;
  esac
}
