#!/bin/bash

[[ -v 'INIT' ]] || {
  # Only when called directly

  SCRIPT_DIR="${0%/*}"
  SCRIPT_NAME="${0##*/}"
  SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

  . "${SCRIPT_DIR}/backup-common.sh" && init && initDefaults || {
    >&2 echo "Error: failed to load ${SCRIPT_DIR}/backup-common.sh and init"
    exit 2
  }
}

"${SCRIPT_DIR}/backup-${hostname}.sh" --cron "$@"
