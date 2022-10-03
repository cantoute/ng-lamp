#!/bin/bash

set -u

[[ -v 'INIT' ]] || {
  # Only when called directly

  SCRIPT_DIR="${0%/*}"
  SCRIPT_NAME="${0##*/}"
  SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

  . "${SCRIPT_DIR}/backup-common.sh" && init && initUtils || {
    >&2 echo "Error: failed to load ${SCRIPT_DIR}/backup-common.sh and init"
    exit 2
  }
}


tryDotenv=(
  # .backup.${hostname}.env
  # ~/.backup.${hostname}.env
  /root/.backup.${hostname}.env
  # "${SCRIPT_DIR}/.backup.${hostname}.env"
)

dotenv "${tryDotenv[@]}" || { info "Failed to load env in: ${tryDotenv[@]@Q}"; exit 2; }


# BACKUP_MYSQL_STORE=local:/home/backup/${hostname}-mysql
# BACKUP_MYSQL_STORE_user=rclone:user@localhost:22/home/backup/${hostname}-%user%-mysql
# BACKUP_MYSQL_STORE_some_label=rclone:user@localhost:22/home/backup/${hostname}-mysql

alertEmail=alert


# load common labels
source "${SCRIPT_DIR}/backup-borg-label.sh";


# Create your own
bb_borg_create_wrapper() {
  "$@" --exclude '**/node_modules'
}

bb_label_my-user() {
  local rc=0 myRc borgRc label="$1" bbArg="$2"; shift 2

  # local myDir="${backupMysqlLocalDir}-${label}"

  local myUser="$bbArg"
  local myDir=~/$myUser/backup/mysql

  # Create local backup
  # usingRepo "${myUser}" backupBorgMysql single --label "${myUser}" --dir "${myDir}"  --like "${myUser}_%"
  backupBorgMysql single --dir "${myDir}"  --like "${myUser}_%"

  myRc=$( max $? $rc )

  # Upload the backup to borg repo using BORG_REPO_${label}
  usingRepo "${myUser}" borgCreate "${myUser}" ~/$myUser "$@"

  rc=$( max $? $rc )

  return $rc
}



. "${SCRIPT_DIR}/backup-borg.sh";

