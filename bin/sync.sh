#!/bin/bash

# stop on error
set -e

usage() {
  echo "Usage: $0 {dir2sync}" >&2;
  exit 1;
}

if [ -z "$1" ]
  then
   usage 
fi

SYNC_PATH=$1

SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

SRC_ROOT=$(realpath $SCRIPT_PATH/../root-fs)
DST_ROOT=/

SRC=$(realpath -L $SRC_ROOT/$SYNC_PATH)
DST=$(realpath -mL $DST_ROOT/$SYNC_PATH)

BACKUP_BASE=/root/_ng-lamp.bak
BACKUP_DIR=$(realpath -mL $BACKUP_BASE/$SYNC_PATH)
BACKUP_SUFFIX=$(date +"_%Y%m%d%H%M")

[[ -e "$SRC" ]] || {
  echo "Error: Source $SRC does not exist!";
  exit 1;
}

if [[ -d "$SRC" ]]; then
  SRC="$SRC/";
  DST="$DST/";
else
  # $SRC is a file then $BACKUP_DIR and $DST should map file's directory
  BACKUP_DIR=$(dirname "$BACKUP_DIR");
  DST=$(dirname "$DST");
fi

RSYNC="rsync -v"
RSYNC_ARGS="-r --checksum -b --suffix=$BACKUP_SUFFIX --backup-dir=$BACKUP_DIR"

echo "About to copy files"
echo "from: $SRC"
echo "  to: $DST"
echo "(a backup will be made here $BACKUP_DIR)"

while true; do
	read -p "Do you wish to proceed? [Y/n] " yn
  case $yn in
    [Yy]* | '' )
      $RSYNC $RSYNC_ARGS $SRC $DST;
      break;;
    [Nn]* ) exit;;
    * ) echo "Please answer Yes or No.";;
  esac
done

