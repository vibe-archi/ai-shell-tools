#!/bin/bash
# add-ai-user.sh: create a user whose SSH sessions have to go through tmux, so that whatever
# an AI does on that account can be watched live and read back later. The account gets
# Oh my tmux! with byobu-style keys, and every tmux pane is recorded in ~/tmux-logs.
# Debian / Ubuntu. Run as root from the directory that holds this script.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./add-ai-user.sh [options] <user>
       sudo ./add-ai-user.sh --update [options] <user>
       sudo ./add-ai-user.sh --system-only [--host <name>]
       sudo ./add-ai-user.sh --remove <user>
       sudo ./add-ai-user.sh --uninstall

Creates <user> so that every SSH session of this account goes through tmux and every
tmux pane is recorded in ~<user>/tmux-logs. The system part (dependencies, Oh my tmux!,
SSH gate, log janitor) is installed or updated on the way.

With a terminal, the script asks what it needs: the account type, a password, an SSH key
and whether SSH password login is turned off. The options below answer in advance.

Login:
  -k, --key <file|key>  authorize SSH public key(s): a file such as id_ed25519.pub, or
                        the key itself ("ssh-ed25519 AAAA... comment"); repeatable.
                        Without --key, if the user has no key yet, it is asked for:
                        paste it and confirm it, or leave it empty to log in with the password
      --no-key          don't ask for a key (password login, or keys added later)
  -p, --password        set a new password on an existing account (asked)
      --password-file <file>
                        read the password from the first line of <file> ("-": standard input),
                        at least 8 characters
      --no-password-login
                        SSH login with a key only (the password still unlocks sudo)
      --password-login  SSH login with the password too (always the case without a key)
      --no-sudo         a standard account without sudo (a new standard account is a sudoer,
                        sudo asks for its password)
  -s, --sudo            add an existing standard account to the sudo group

Other options:
  -m, --message <file>  your own instructions for agents, placed in ~<user>/AGENTS.md below
                        the managed block ({user} and {host} are replaced); they replace
                        the previous ones, "--message default" removes them
  -u, --update          <user> already exists: (re)apply the add-ai-user setup to it
      --host <name>     host name shown to agents
      --system-only     install or update the system part only
      --remove <user>   take <user> out of add-ai-user (the account and its files are kept)
      --uninstall       remove add-ai-user from the system (users and their files are kept)
  -h, --help            show this help

Account type: a new account is asked for, when there is a terminal.
      --standard        the agent can do what this user can do (default without a terminal);
                        on a restricted account, turns it back into a standard one
      --restricted      the agent can only read and diagnose, category by category
      --allow <list>    categories, without asking: defaults, all, none, or a comma-separated
                        list among base logs performance network storage kernel hardware
                        accounts persistence security containers services security_scans
                        profiling packet_capture
      --agent-location  remote (connects over SSH: no new outbound connection for the account)
          <where>       or local (a Claude or Codex CLI on this server: outbound stays open)
  -y, --yes             confirm making an existing account restricted
EOF
}

SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
LIB=/usr/local/lib/add-ai-user
CONF_DIR=/etc/add-ai-user
GROUP=add-ai-user
KEY_ONLY_GROUP=add-ai-key-only            # sshd: no password login
PASSWORD_LOGIN_GROUP=add-ai-password-login  # sshd: password login, whatever sshd_config says
SSHD_CONF=/etc/ssh/sshd_config.d/60-add-ai-user.conf
UNITS=/etc/systemd/system
OMT_REPO=https://github.com/gpakosz/.tmux.git
UTF8_MARK='#tmux-utf8#'
AGENTS_MARK='#add-ai-user-agents#'
AGENTS_BEGIN='<!-- add-ai-user:begin: add-ai-user.sh --update rewrites this block; add your own instructions below it -->'
AGENTS_END='<!-- add-ai-user:end -->'
STAMP=$(date +%Y%m%d-%H%M%S)

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/restricted/install.sh
. "$SRC/lib/restricted/install.sh"

# -- system part ---------------------------------------------------------------

install_deps() {
  local missing=() cmd
  for cmd in tmux git python3 gzip less nano; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  [ -x /usr/sbin/sshd ] || missing+=(openssh-server)
  if ((${#missing[@]})); then
    command -v apt-get >/dev/null || die "missing: ${missing[*]} (and no apt-get to install them)"
    say "Installing ${missing[*]}"
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
  fi
  local version
  version=$(tmux -V | grep -oE '[0-9]+\.[0-9]+' | head -1)
  if [ "$(printf '%s\n' 3.4 "$version" | sort -V | head -1)" != 3.4 ]; then
    warn "tmux $version: 3.4 or newer is recommended (F9 menu, popups)"
  fi
}

reload_sshd() { systemctl reload ssh 2>/dev/null || systemctl reload sshd; }

install_system() {
  local group
  install_deps
  grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config ||
    die "/etc/ssh/sshd_config doesn't include /etc/ssh/sshd_config.d/*.conf"

  say "Installing add-ai-user in $LIB"
  for group in "$GROUP" "$KEY_ONLY_GROUP" "$PASSWORD_LOGIN_GROUP"; do
    getent group "$group" >/dev/null || groupadd --system "$group"
  done
  install -d -m 755 "$LIB" "$LIB/tmux" "$CONF_DIR"
  install -m 755 "$SRC/lib/ssh-gate" "$SRC/lib/tmux-logs-janitor" "$SRC/lib/tmux-logs" "$LIB/"
  install -m 755 "$SRC"/lib/tmux/{help,broadcast,printscreen,log-panes,pane-logger} "$LIB/tmux/"
  install -m 644 "$SRC/lib/tmux/tmux.conf.local" "$LIB/tmux/"
  ln -sfn "$LIB/tmux-logs" /usr/local/bin/tmux-logs

  if [ -d "$LIB/oh-my-tmux/.git" ]; then
    git -C "$LIB/oh-my-tmux" pull -q --ff-only || warn "could not update Oh my tmux!"
  else
    say "Cloning Oh my tmux!"
    git clone -q --single-branch "$OMT_REPO" "$LIB/oh-my-tmux"
  fi

  # settings and default rules: installed once, then they are the admin's to edit
  [ -f "$CONF_DIR/add-ai-user.conf" ] || install -m 644 "$SRC/etc/add-ai-user.conf" "$CONF_DIR/add-ai-user.conf"
  [ -f "$CONF_DIR/AGENTS.md" ] || install -m 644 "$SRC/etc/AGENTS.md" "$CONF_DIR/AGENTS.md"
  [ -f "$CONF_DIR/AGENTS-restricted.md" ] || install -m 644 "$SRC/etc/AGENTS-restricted.md" "$CONF_DIR/AGENTS-restricted.md"
  [ -z "$HOST_NAME" ] || sed -i "s|^SSH_HOST=.*|SSH_HOST=$HOST_NAME|" "$CONF_DIR/add-ai-user.conf"

  install -m 644 "$SRC/systemd/add-ai-user-janitor@.service" "$SRC/systemd/add-ai-user-janitor@.timer" "$UNITS/"
  systemctl daemon-reload

  install -m 644 "$SRC/sshd/60-add-ai-user.conf" "$SSHD_CONF"
  if ! sshd -t; then
    rm -f "$SSHD_CONF"
    die "sshd rejected the configuration, $SSHD_CONF removed"
  fi
  reload_sshd
}

# -- user part -----------------------------------------------------------------

# run a command as the user, with its own HOME and outside any tmux of the caller
as_user() { runuser -u "$USER_NAME" -- env -u TMUX -u TMUX_PANE HOME="$HOME_DIR" "$@"; }

is_public_key() {
  command -v ssh-keygen >/dev/null || die "ssh-keygen not found (apt install openssh-client)"
  printf '%s\n' "$1" | ssh-keygen -l -f - >/dev/null 2>&1
}

key_lines() {  # the SSH public keys given with --key (files or keys), one per line
  local key
  for key in "${KEYS[@]}"; do
    if [ -f "$key" ]; then grep -vE '^[[:space:]]*(#|$)' "$key" || true
    else printf '%s\n' "$key"
    fi
  done
}

check_keys() {  # dies on a bad --key, before anything is changed
  local line n=0
  while IFS= read -r line; do
    is_public_key "$line" || die "--key: not an SSH public key (a .pub file or \"ssh-ed25519 AAAA...\"): ${line:0:40}"
    n=$((n + 1))
  done < <(key_lines)
  ((n > 0)) || die "--key: no SSH public key found"
}

has_password() { [ "$(passwd -S "$1" 2>/dev/null | cut -d' ' -f2)" = P ]; }
in_group() { [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]; }

ask_password() {  # sets NEW_PASSWORD, typed twice without echo
  local again
  say "Password of $TARGET: $1"
  while :; do
    read -r -s -p "Password: " NEW_PASSWORD || die "cancelled"
    echo >&2
    if ((${#NEW_PASSWORD} < 8)); then
      warn "at least 8 characters, try again"
      continue
    fi
    read -r -s -p "Password again: " again || die "cancelled"
    echo >&2
    [ "$NEW_PASSWORD" != "$again" ] || return 0
    warn "the two passwords differ, try again"
  done
}

read_password_file() {
  if [ "$PASSWORD_FILE" = - ]; then IFS= read -r NEW_PASSWORD || true
  else IFS= read -r NEW_PASSWORD <"$PASSWORD_FILE" || true
  fi
  NEW_PASSWORD=${NEW_PASSWORD%$'\r'}
  ((${#NEW_PASSWORD} >= 8)) || die "--password-file: the password needs at least 8 characters"
}

ask_key() {  # no --key: ask for one, then confirm it or enter it again; $1=true: may stay empty
  local key fingerprint answer
  if $1; then
    say "SSH public key of $TARGET: paste it, or leave it empty to log in with the password"
  else
    say "SSH public key of $TARGET: paste it"
  fi
  while :; do
    read -r -p "SSH public key: " key || die "cancelled"
    key=$(printf '%s' "$key" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ -z "$key" ] && $1; then return 0; fi
    if ! fingerprint=$(printf '%s\n' "$key" | ssh-keygen -l -f - 2>/dev/null); then
      warn "not an SSH public key (it looks like: ssh-ed25519 AAAA... comment), try again"
      continue
    fi
    if ((${#key} > 72)); then
      printf '  key:         %s...%s\n' "${key:0:40}" "${key: -28}"
    else
      printf '  key:         %s\n' "$key"
    fi
    printf '  fingerprint: %s\n' "$fingerprint"
    read -r -p "Is this the right key? [y = yes, n = enter it again] " answer || die "cancelled"
    case $answer in
      [yY]*) KEYS+=("$key"); return ;;
    esac
  done
}

ask_login() {  # sets NEW_PASSWORD, KEYS and PASSWORD_LOGIN; nothing is changed yet
  local had_password=false had_key=false has_key ask=false sudoer=false answer purpose
  if [ -n "$home" ]; then
    if has_password "$TARGET"; then had_password=true; fi
    if [ -s "$home/.ssh/authorized_keys" ]; then had_key=true; fi
  fi
  has_key=$had_key
  ((${#KEYS[@]} == 0)) || has_key=true
  if $RESTRICTED; then
    purpose='it logs in over SSH without a key (a restricted account has no sudo)'
  elif [ "$SUDO" = true ] || { [ -z "$SUDO" ] && in_group "$TARGET" sudo; }; then
    purpose='it unlocks sudo, and logs in over SSH without a key'
    sudoer=true
  else
    purpose='it logs in over SSH without a key'
  fi

  # A new account always gets a password; an existing one when asked, or when it lacks one
  # it needs: for sudo, or to log in without a key.
  if [ -z "$home" ] || $PASSWORD; then
    ask=true
  elif ! $had_password && { ! $has_key || $sudoer; }; then
    ask=true
  fi
  if [ -n "$PASSWORD_FILE" ]; then
    read_password_file
  elif $ask; then
    if [ -t 0 ]; then
      ask_password "$purpose"
    elif $PASSWORD; then
      die "no terminal to ask the password (use --password-file)"
    fi
  fi

  if ! $has_key && ! $NO_KEY && [ -t 0 ]; then
    if [ -n "$NEW_PASSWORD" ] || $had_password; then ask_key true; else ask_key false; fi
    ((${#KEYS[@]} == 0)) || has_key=true
  fi
  if ! $has_key && ! $NO_KEY && [ -z "$NEW_PASSWORD" ] && ! $had_password; then
    die "no SSH key and no password: nobody could log in (use --key, --password-file or --no-key)"
  fi

  case $PASSWORD_LOGIN in
    no)  $has_key || die "--no-password-login needs an SSH key (--key)" ;;
    yes) ;;
    *)
      if ! $has_key; then
        PASSWORD_LOGIN=yes  # the only way in
      elif [ -t 0 ] && { [ -z "$home" ] || ((${#KEYS[@]})); }; then
        read -r -p "Disable SSH password login for $TARGET (SSH key only)? [Y/n] " answer || die "cancelled"
        case $answer in [nN]*) PASSWORD_LOGIN=yes ;; *) PASSWORD_LOGIN=no ;; esac
      elif [ -z "$home" ]; then
        PASSWORD_LOGIN=no
      fi ;;  # otherwise, an existing account keeps what it has
  esac
}

agents_custom_text() {  # stdin: an AGENTS.md; stdout: what is outside the managed block
  awk -v begin='<!-- add-ai-user:begin' -v end='<!-- add-ai-user:end' '
    index($0, begin) == 1 { inside = 1; next }
    index($0, end) == 1   { inside = 0; next }
    !inside' | sed '/./,$!d'
}

setup_agents() {  # ~/AGENTS.md: the managed block, then the instructions added by the admin
  local host=$1 home_file=$HOME_DIR/AGENTS.md file custom block old=$HOME_DIR/.ai/con-refused.txt
  custom=$(mktemp) block=$(mktemp)
  file=$home_file
  if $RESTRICTED; then file=$AGENTS_DIR/$USER_NAME.md; fi
  fill() { sed "s/{user}/$USER_NAME/g; s/{host}/$host/g" "$1"; }

  # The home belongs to the account: what is there is read as the account, never as root.
  if [ -n "$MESSAGE" ]; then
    [ "$MESSAGE" = default ] || fill "$MESSAGE" >"$custom"
  elif [ -f "$file" ] && [ "$file" != "$home_file" ]; then
    agents_custom_text <"$file" >"$custom"
  elif [ -e "$home_file" ]; then
    as_user cat "$home_file" | agents_custom_text >"$custom"
  fi
  if [ -f "$old" ]; then  # the rules of an older version become the admin's instructions, once
    if [ -z "$MESSAGE" ] && ! { [ -f "$CONF_DIR/con-refused.txt" ] &&
        as_user cat "$old" | cmp -s - <(fill "$CONF_DIR/con-refused.txt"); }; then
      as_user cat "$old" >>"$custom"
      say "Your rules of ~/.ai/con-refused.txt are now in AGENTS.md"
    fi
    as_user mv "$old" "$old.migrated"
  fi

  {
    printf '%s\n' "$AGENTS_BEGIN"
    fill "$CONF_DIR/AGENTS.md"
    if $RESTRICTED; then
      fill "$CONF_DIR/AGENTS-restricted.md"
      echo
      # shellcheck disable=SC2086
      catalog agents-block $CATEGORIES
    fi
    printf '%s\n' "$AGENTS_END"
    if [ -s "$custom" ]; then
      echo
      cat "$custom"
    fi
  } >"$block"

  if $RESTRICTED; then
    install -m 644 "$block" "$file"
    if [ -e "$home_file" ] && [ ! -L "$home_file" ]; then
      as_user mv "$home_file" "$home_file.bak-$STAMP"
    fi
    as_user ln -sfn "$file" "$home_file"
    say "Instructions for agents: $file (~/AGENTS.md links to it, the account can't change it)"
  else
    as_user rm -f "$home_file"
    as_user tee "$home_file" <"$block" >/dev/null
    say "Instructions for agents: $home_file"
  fi
  rm -f "$custom" "$block"

  # the CLIs read it by themselves, and a new tmux shell says where it is
  as_user mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.codex"
  as_user grep -qxF '@~/AGENTS.md' "$HOME_DIR/.claude/CLAUDE.md" 2>/dev/null ||
    printf '@~/AGENTS.md\n' | as_user tee -a "$HOME_DIR/.claude/CLAUDE.md" >/dev/null
  if [ ! -e "$HOME_DIR/.codex/AGENTS.md" ] && [ ! -L "$HOME_DIR/.codex/AGENTS.md" ]; then
    as_user ln -s ../AGENTS.md "$HOME_DIR/.codex/AGENTS.md"
  elif [ "$(readlink "$HOME_DIR/.codex/AGENTS.md")" != ../AGENTS.md ]; then
    warn "~/.codex/AGENTS.md exists and is kept: Codex won't read ~/AGENTS.md by itself"
  fi
  if ! grep -qF "$AGENTS_MARK" "$HOME_DIR/.bashrc" 2>/dev/null; then
    as_user tee -a "$HOME_DIR/.bashrc" >/dev/null <<EOF

# where the instructions for agents are, in each new tmux shell  $AGENTS_MARK
if [ -n "\${TMUX:-}" ] && [ -r ~/AGENTS.md ]; then echo "Instructions of this account: ~/AGENTS.md"; fi  $AGENTS_MARK
EOF
  fi
}

setup_user() {
  USER_NAME=$1
  if id "$USER_NAME" >/dev/null 2>&1; then
    say "Updating $USER_NAME"
  else
    say "Creating $USER_NAME"
    useradd --create-home --shell /bin/bash "$USER_NAME"
  fi
  HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
  [ -d "$HOME_DIR" ] || die "$USER_NAME has no home directory ($HOME_DIR)"

  usermod -aG "$GROUP" "$USER_NAME"
  if $RESTRICTED; then
    restrict_account
  else
    unrestrict_account "$USER_NAME"
  fi
  if [ "$SUDO" = true ]; then
    usermod -aG sudo "$USER_NAME"
  elif [ "$SUDO" = false ]; then
    gpasswd -d "$USER_NAME" sudo >/dev/null 2>&1 || true
  fi
  if [ -n "$NEW_PASSWORD" ]; then
    printf '%s:%s\n' "$USER_NAME" "$NEW_PASSWORD" | chpasswd
    NEW_PASSWORD=''
    say "Password of $USER_NAME set"
  fi
  case $PASSWORD_LOGIN in
    yes)
      gpasswd -d "$USER_NAME" "$KEY_ONLY_GROUP" >/dev/null 2>&1 || true
      usermod -aG "$PASSWORD_LOGIN_GROUP" "$USER_NAME" ;;
    no)
      gpasswd -d "$USER_NAME" "$PASSWORD_LOGIN_GROUP" >/dev/null 2>&1 || true
      usermod -aG "$KEY_ONLY_GROUP" "$USER_NAME" ;;
  esac

  if ((${#KEYS[@]})); then
    say "Authorizing SSH key(s)"
    as_user install -d -m 700 "$HOME_DIR/.ssh"
    as_user touch "$HOME_DIR/.ssh/authorized_keys"
    as_user chmod 600 "$HOME_DIR/.ssh/authorized_keys"
    while IFS= read -r key; do
      grep -qxF "$key" "$HOME_DIR/.ssh/authorized_keys" ||
        printf '%s\n' "$key" | as_user tee -a "$HOME_DIR/.ssh/authorized_keys" >/dev/null
    done < <(key_lines)
  fi

  say "Setting up tmux for $USER_NAME"
  as_user mkdir -p "$HOME_DIR/.config/tmux" "$HOME_DIR/tmux-logs"
  if [ -e "$HOME_DIR/.tmux.conf" ] || [ -L "$HOME_DIR/.tmux.conf" ]; then  # would win over ours
    as_user mv "$HOME_DIR/.tmux.conf" "$HOME_DIR/.tmux.conf.bak-$STAMP"
    warn "~/.tmux.conf moved to ~/.tmux.conf.bak-$STAMP"
  fi
  as_user ln -sfn "$LIB/oh-my-tmux/.tmux.conf" "$HOME_DIR/.config/tmux/tmux.conf"
  local conf_local=$HOME_DIR/.config/tmux/tmux.conf.local
  if [ -f "$conf_local" ] && ! cmp -s "$LIB/tmux/tmux.conf.local" "$conf_local"; then
    as_user cp "$conf_local" "$conf_local.bak-$STAMP"
    warn "previous ~/.config/tmux/tmux.conf.local kept as tmux.conf.local.bak-$STAMP"
  fi
  as_user cp "$LIB/tmux/tmux.conf.local" "$conf_local"

  # ssh from Windows sends no locale, tmux needs UTF-8 for its symbols
  if ! grep -qF "$UTF8_MARK" "$HOME_DIR/.bashrc" 2>/dev/null; then
    as_user tee -a "$HOME_DIR/.bashrc" >/dev/null <<EOF

# UTF-8 locale when the ssh client doesn't send one (tmux needs it for its symbols)  $UTF8_MARK
case "\${LC_ALL:-\${LC_CTYPE:-\$LANG}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;; *) export LANG=C.UTF-8 ;; esac  $UTF8_MARK
EOF
  fi

  local host
  host=$(. "$CONF_DIR/add-ai-user.conf"; echo "${SSH_HOST:-$(hostname -f)}")
  setup_agents "$host"

  systemctl enable --now --quiet "add-ai-user-janitor@$USER_NAME.timer"
  if as_user tmux has-session 2>/dev/null; then
    as_user tmux source-file "$HOME_DIR/.config/tmux/tmux.conf" && say "Reloaded the running tmux of $USER_NAME"
  fi

  local login
  if [ -s "$HOME_DIR/.ssh/authorized_keys" ]; then
    if in_group "$USER_NAME" "$KEY_ONLY_GROUP"; then login='SSH key only'
    elif in_group "$USER_NAME" "$PASSWORD_LOGIN_GROUP"; then login='SSH key or password'
    else login='SSH key (password login as set in sshd_config)'
    fi
  else
    login='password'
    has_password "$USER_NAME" ||
      warn "$USER_NAME has neither an SSH key nor a password: nobody can log in yet (see --key)"
  fi
  if in_group "$USER_NAME" sudo; then
    login+="; sudo asks for the password of $USER_NAME"
    has_password "$USER_NAME" || warn "$USER_NAME has no password: sudo can't work (see --password)"
  fi
  say "Done. $USER_NAME works through tmux:"
  cat <<EOF
    human: ssh -t $USER_NAME@$host tmux new -A -s main
    AI:    ssh $USER_NAME@$host tmux new -d -s <session>      (e.g. fix-login-bug)
           ssh $USER_NAME@$host "tmux send-keys -t <session> '<command>' Enter"
           ssh $USER_NAME@$host tmux capture-pane -p -t <session>
    watch: ssh -t $USER_NAME@$host tmux attach -r -t <session>
    rules: ssh $USER_NAME@$host cat AGENTS.md
    login: $login
    logs:  $HOME_DIR/tmux-logs (read them with tmux-logs)
EOF
  if $RESTRICTED; then
    cat <<EOF
    type:  restricted, agent $LOCATION; categories: $CATEGORIES
           on this account, ai-diag list shows what it can read
EOF
  fi
}

remove_user() {
  local user=$1 group
  id "$user" >/dev/null 2>&1 || die "no user $user"
  unrestrict_account "$user"
  systemctl disable --now "add-ai-user-janitor@$user.timer" >/dev/null 2>&1 || true
  for group in "$GROUP" "$KEY_ONLY_GROUP" "$PASSWORD_LOGIN_GROUP"; do
    gpasswd -d "$user" "$group" >/dev/null 2>&1 || true
  done
  say "$user is no longer an add-ai-user account (the account, its tmux setup and its logs are kept)"
  say "SSH password login of $user follows sshd_config again"
}

uninstall() {
  local timer
  for timer in "$UNITS"/timers.target.wants/add-ai-user-janitor@*.timer; do
    [ -e "$timer" ] && remove_user "$(basename "$timer" .timer | cut -d@ -f2)"
  done
  uninstall_restricted_system
  rm -f "$SSHD_CONF"
  sshd -t && reload_sshd
  rm -f "$UNITS/add-ai-user-janitor@.service" "$UNITS/add-ai-user-janitor@.timer" /usr/local/bin/tmux-logs
  systemctl daemon-reload
  rm -rf "$LIB"
  groupdel "$GROUP" 2>/dev/null || true
  groupdel "$KEY_ONLY_GROUP" 2>/dev/null || true
  groupdel "$PASSWORD_LOGIN_GROUP" 2>/dev/null || true
  say "add-ai-user removed. Kept: $CONF_DIR, the users, their ~/tmux-logs and ~/.config/tmux"
  say "(their ~/.config/tmux/tmux.conf now points to a removed Oh my tmux!)"
}

# -- main ----------------------------------------------------------------------

KEYS=() NO_KEY=false MESSAGE='' PASSWORD=false PASSWORD_FILE='' NEW_PASSWORD='' PASSWORD_LOGIN=''
SUDO='' UPDATE=false HOST_NAME=''
RESTRICTED='' RESTRICTED_FLAG=false ALLOW='' LOCATION='' ASSUME_YES=false
ACTION=user TARGET=''
while (($#)); do
  case $1 in
    -k|--key)      KEYS+=("${2:?$1 needs a value}"); shift 2 ;;
    --no-key)      NO_KEY=true; shift ;;
    -m|--message)  MESSAGE=${2:?$1 needs a file}; shift 2 ;;
    -p|--password) PASSWORD=true; shift ;;
    --password-file) PASSWORD_FILE=${2:?$1 needs a file}; shift 2 ;;
    --password-login)    PASSWORD_LOGIN=yes; shift ;;
    --no-password-login) PASSWORD_LOGIN=no; shift ;;
    -s|--sudo)     SUDO=true; shift ;;
    --no-sudo)     SUDO=false; shift ;;
    -u|--update)   UPDATE=true; shift ;;
    --host)        HOST_NAME=${2:?$1 needs a name}; shift 2 ;;
    --system-only) ACTION=system; shift ;;
    --remove)      ACTION=remove TARGET=${2:?$1 needs a user}; shift 2 ;;
    --uninstall)   ACTION=uninstall; shift ;;
    --restricted)  RESTRICTED=true RESTRICTED_FLAG=true; shift ;;
    --standard)    RESTRICTED=false; shift ;;
    --allow)       ALLOW=${2:?$1 needs a list}; RESTRICTED=${RESTRICTED:-true}; shift 2 ;;
    --agent-location) LOCATION=${2:?$1 needs remote or local}; shift 2 ;;
    -y|--yes)      ASSUME_YES=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option $1 (see --help)" ;;
    *)             [ -z "$TARGET" ] || die "one user at a time"; TARGET=$1; shift ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run me as root (sudo $0 ...)"
[ -z "$HOST_NAME" ] || [[ $HOST_NAME =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid host name: $HOST_NAME"
[ -z "$MESSAGE" ] || [ "$MESSAGE" = default ] || [ -r "$MESSAGE" ] || die "cannot read $MESSAGE"
[ -z "$PASSWORD_FILE" ] || [ "$PASSWORD_FILE" = - ] || [ -r "$PASSWORD_FILE" ] || die "cannot read $PASSWORD_FILE"
((${#KEYS[@]} == 0)) || check_keys

case $ACTION in
  system)    install_system ;;
  remove)    remove_user "$TARGET" ;;
  uninstall) uninstall ;;
  user)
    [ -n "$TARGET" ] || { usage; exit 1; }
    [[ $TARGET =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: $TARGET"
    if home=$(getent passwd "$TARGET" | cut -d: -f6) && [ -n "$home" ]; then
      $UPDATE || die "user $TARGET already exists (add --update to apply the add-ai-user setup to it)"
    else
      $UPDATE && die "user $TARGET doesn't exist"
      home=''
    fi
    # every question comes before anything is changed
    choose_account_type
    if $RESTRICTED; then
      [ "$SUDO" != true ] || die "--sudo makes no sense on a restricted account"
    elif [ -z "$SUDO" ] && [ -z "$home" ]; then
      SUDO=true  # a new standard account; an existing one keeps what it has
    fi
    ask_login
    if $RESTRICTED; then
      install_deps  # the questions come from a Python catalog
      ask_restricted
    fi
    install_system
    if $RESTRICTED; then install_restricted_system; fi
    setup_user "$TARGET"
    ;;
esac
