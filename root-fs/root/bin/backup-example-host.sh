#!/bin/bash

# Borg environment
tryDotenv=(
  # .backup.${hostname}.env
  # ~/.backup.${hostname}.env
  /root/.backup.${hostname}.env
  # "${SCRIPT_DIR}/.backup.${hostname}.env"
)
dotenv "${tryDotenv[@]}" || { info "Failed to load env in: ${tryDotenv[@]@Q}"; exit 2; }

alertEmail=alert

# BACKUP_MYSQL_STORE=local:/home/backups/${hostname}-mysql
# BACKUP_MYSQL_STORE_user=rclone:user@localhost:22/home/backups/${hostname}-%user%-mysql
# BACKUP_MYSQL_STORE_some_label=rclone:user@localhost:22/home/backups/${hostname}-mysql


# Global to borg create
bb_borg_create_wrapper() {
  "$@" --exclude '**/node_modules'
}

# Wrapper for label named home
bb_borg_create_wrapper_home() {
  local args=(
    --exclude 'home/postgresql/data'
    --exclude "home/backups/${hostname}-mysql"
  )

  "$@" "${args[@]}"
}

# Custom label 'custom-home'
bb_label_custom-home() {
  local self="$1" bbArg="$2"; shift 2

  local args=(
    --exclude 'home/postgresql/data'
    --exclude "home/backups/${hostname}-mysql"
  )

  backupCreate "$self" /home "${args[@]}" "$@"
}


# Examples: see backup-defaults.sh and backup-borg-label-mysql.sh