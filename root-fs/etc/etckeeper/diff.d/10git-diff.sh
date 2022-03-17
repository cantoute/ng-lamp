#!/bin/sh
set -e

gitDiffAll() {
  # credits https://stackoverflow.com/questions/855767/can-i-use-git-diff-on-untracked-files
  # this simulates a `git add .` without taking the risk of braking with stashes
  # and will show all new failes too in the diff

  git ls-files --others --exclude-standard                    \
    | xargs -n 1 git --no-pager diff --color=always /dev/null \
    | less -R;
}

if [ "$VCS" = git ] && [ -d .git ]; then
  if ! gitDiffAll; then
    echo "etckeeper warning: git diff failed" >&2
  fi
fi
