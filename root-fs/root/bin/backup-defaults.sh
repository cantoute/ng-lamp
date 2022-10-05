#!/usr/bin/env bash

# Set in backup-common.sh
# [[ -v 'hostname' ]]             || hostname=$( hostname -s )
# [[ -v 'backupMysqlLocalDir' ]]  || backupMysqlLocalDir="/home/backups/${hostname}-mysql"

# Include mysql labels ( mysql mysql-skip-lock my-user my-user-skip-lock )
# . "${SCRIPT_DIR}/backup-borg-label-mysql.sh"


createArgs=(
  --verbose
  --list
  --stats
  --show-rc
  --filter AME

  --compression auto,zstd,11
  --upload-ratelimit 30000

  --files-cache=mtime,size
)

excludeArgs=(
  --one-file-system                     # Don't backup mounted fs
  --exclude-caches                      # See https://bford.info/cachedir/
  --exclude '**/.config/borg/security'  # creates annoying warnings
  --exclude '**/lost+found'
  --exclude '**/*nobackup*'

  # some commons
  --exclude '**/.*cache*'
  --exclude '**/.*Cache*'
  --exclude '**/*.tmp'
  --exclude '**/*.log'
  --exclude '**/*.LOG'
  --exclude '**/.npm/_*'
  --exclude '**/tmp'
  --exclude 'var/log'
  --exclude 'var/run'
  --exclude 'var/cache'
  --exclude 'var/lib/ntp'
  --exclude 'var/lib/mysql'
  --exclude 'var/lib/postgresql'
  --exclude 'var/lib/postfix/*cache*'
  --exclude 'var/lib/varnish'
  --exclude 'var/spool/squid'
  --exclude '**/site/cache'

  # fail2ban
  --exclude 'var/lib/fail2ban/fail2ban.sqlite3'
  
  # php
  --exclude 'var/lib/**/sessions/*'
  --exclude '**/sessions/sess_*'
  --exclude '**/smarty/compile'

  # Drupal
  --exclude '**/.drush'
  --exclude '**/drush-backups'

  # WordPress
  --exclude '**/.wp-cli'
  --exclude '**/wp-content/*cache*'
  --exclude '**/wp-content/*log*'
  --exclude '**/wp-content/*webp*'
  --exclude '**/wp-content/*backup*'

  # Misc
  --exclude '**/.ipfs'
  --exclude '**/.bitcoin'
  --exclude '**/downloads'
  --exclude '**/Downloads'

  # Node
  --exclude '**/node_modules'
)

pruneArgs=(
  --list
  --show-rc
)

pruneKeepArgs=(
  --keep-within   2w
  --keep-last     24
  --keep-hourly   96
  --keep-daily    48
  --keep-weekly   24
  --keep-monthly  12
  --keep-yearly   2
)


##################################
# Default labels

bb_label_home() {
  local self="$1" bbArg="$2"; shift 2

  set -- backupCreate "$self" /home "$@"
  
  tryingRepo "$self" "home" -- "$@"
}

bb_label_home-users() {
  local self="$1" bbArg="$2"; shift 2

  # backupCreate "home" /home --exclude "home/vmail" --exclude "$backupMysqlLocalDir" "$@"
  set -- bb_label_home "$self" "$bbArg" --exclude "home/vmail" --exclude "$backupMysqlLocalDir" "$@"
  
  tryingRepo "$self" "home-users" "users" "home" -- "$@"
}

bb_label_vmail() {
  local self="$1" bbArg="$2"; shift 2

  set -- backupCreate "$self" /home/vmail "$@"

  tryingRepo "$self" "vmail" "home" -- "$@"
}

bb_label_sys() {
  local self="$1" bbArg="$2"; shift 2

  set -- backupCreate "$self" /etc /usr/local /root "$@"

  tryingRepo "$self" "sys" -- "$@"
}

bb_label_var() {
  local self="$1" bbArg="$2"; shift 2

  set -- backupCreate "$self" /var "$@"

  tryingRepo "$self" "var" -- "$@"
}

bb_label_etc() {
  local self="$1" bbArg="$2"; shift 2

  set -- backupCreate "$self" /etc "$@"

  tryingRepo "$self" "etc" "sys" -- "$@"
}

bb_label_usr-local() {
  local self="$1" bbArg="$2"; shift 2

  set -- backupCreate "$self" /usr/local "$@"

  tryingRepo "$self" "sys" -- "$@"
}

# user:$user:$repo
bb_label_user() {
  local self="$1" bbArg="$2"; shift 2
  local ISF user users repo s="$bbArg" rc=() args=( "$@" )

  user="${s%%:*}"; s=${s#"$user"}; s=${s#:};
  [[ "$user" == "" ]] && { info "Error: $self:$bbArg param1(user) is required"; return 2; }

  repo="${s%%:*}"; s=${s#"$repo"}; s=${s#:};

  # Split on comma
  IFS=,; users=( $user ); unset IFS

  for user in "${users[@]}"; do
    userHome="$( getUserHome "$user" )" && [[ "$userHome" != '' ]] && {
      set -- 'backupCreate' "${self}-${user}" "$( getUserHome "$user" )" "${args[@]}"

      # >&2 echo "$@"
      info "Info: ${FUNCNAME[0]}: executing user:$user $@"

      tryingRepo "${repo}_${user}" "$user" "$repo" "$self" "user" -- "$@"
      # "$@"

      rc+=( $? )
    } || {
      info "Error: ${FUNCNAME[0]}: Could not get user '$user' home dir."
      rc+=( 2 )
    }
  done

  [[ -v 'rc' ]] && (( ${#rc} > 0 )) || {
    info "Error: No user was backed up. Call: ${FUNCNAME[0]} $@"
    rc=(2)
  }

  return $( max "${rc[@]}" )
}

#########
# Misc
###

bb_label_sleep() {
  local self="$1" sleep="$2"; shift 2

  [[ "$sleep" == '' ]] && sleep=60

  info "Sleeping ${sleep}s..."

  sleep $sleep
}

bb_label_test() {
  local self="$1" bbArg="$2"; shift 2

  case "$bbArg" in
                 [0-9]*) return $bbArg ;;
         ok|success|s|t) return 0      ;;
         warning|warn|w) return 1      ;;
       ko|error|err|e|f) return 2      ;;
                      *) return 2      ;;
  esac
}
