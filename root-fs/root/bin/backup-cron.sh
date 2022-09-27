#!/bin/bash

SCRIPT_DIR="${0%/*}"

source "${SCRIPT_DIR}/backup-common.sh";
init && initUtils


"${SCRIPT_DIR}/backup-${hostname}.sh" --cron "$@"
