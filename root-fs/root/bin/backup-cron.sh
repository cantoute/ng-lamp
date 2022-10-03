#!/bin/bash

SCRIPT_DIR="${0%/*}"
SCRIPT_NAME="${0##*/}"
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

hostname="$( hostname -s )"

set -- --conf "${SCRIPT_DIR}/backup-${hostname}.sh" --cron "$@"

. "${SCRIPT_DIR}/backup-borg.sh"
