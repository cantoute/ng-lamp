#!/bin/bash

set -eu

>&2 echo "Downloading and installing borg + bash autocompletion"

urlBorgBin='https://github.com/borgbackup/borg/releases/download/1.2.2/borg-linux64'
urlBashCompletion='https://github.com/SanskritFritz/borg/raw/master/scripts/shell_completions/bash/borg'

cd /usr/local/bin         \
  && wget "$urlBorgBin"   \
  && mv borg-linux64 borg \
  && chmod +x borg

cd /etc/bash_completion.d       \
  && wget "$urlBashCompletion"  \
  && chmod +x borg
