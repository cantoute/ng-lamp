#!/url/bin/env bash

[[ -v 'INIT' ]] || {
  SCRIPT_DIR="${0%/*}"
  SCRIPT_NAME="${0##*/}"
  SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

  source "${SCRIPT_DIR}/backup-common.sh";
  init && initUtils && {
    [[ -v 'STORE' ]] || {
      # source "${SCRIPT_DIR}/backup-store-local.sh";
      STORE=( 'local' "/home/backup/${hostname}" );
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

# STORE=( ''local' /path/to/store )

store() {
  local rc=0 _STORE cmd

  while (( $# > 0 )); do
    case "$1" in
      --store)
        _STORE=( "$2" "$3" )
        shift 3 ;;

      *)
        cmd="$1"; shift
        break ;;
    esac
  done  

  [[ -v '_STORE' ]] || {
    [[ -v 'STORE' ]] || { info "Error: store requires var STORE or arg --store local /path/to/store";
      return 2
    }

    _STORE=( "${STORE[@]}" )
  }

  # >&2 echo "jjjjjj ${_STORE[@]}"
  _STORE[0]="store-${_STORE[0]}"

  case "$cmd" in
    init|prune)
      "${_STORE[@]}" "$cmd" "$@" 
      rc=$( max $? $rc )
      ;;

    # is in charge of compressing and adding $compressExt to filename
    create)
      (( $# > 0 )) || { info "Error: create requires at least one arg, the filename"; return $( max 2 $rc ); }
      local filename="${@:$#}" # get last arg

      # right shift: "${@:1:$#-1}"
      set -- "${_STORE[@]}" 'create' "${@:1:$#-1}" "${filename}${compressExt}"
      



      # $@ are dirs that store-local will joinBy '/' to create path
      compress | "$@"

      rc=$( max ${PIPESTATUS[@]} $rc )
      ;;

    *)
      info "Error: store: unknown command '$cmd' - accepts init|create|prune"
      rc=2 ;;
  esac

  return $rc
}
