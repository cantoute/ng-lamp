#!/bin/bash

set -eu

# https://downloads.rclone.org/v1.59.2/rclone-v1.59.2-linux-amd64.deb

cd /tmp

wget https://downloads.rclone.org/rclone-current-linux-amd64.deb

dpkg -i rclone-current-linux-amd64.deb

rclone genautocomplete bash

cd -
