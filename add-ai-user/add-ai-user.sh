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

Options:
  -k, --key <file|key>  authorize SSH public key(s): a file such as id_ed25519.pub, or
                        the key itself ("ssh-ed25519 AAAA... comment"); repeatable.
                        Without --key, if the user has no key yet, it is asked for:
                        paste it, then confirm it or enter it again
      --no-key          don't ask for a key (password login, or keys added later)
  -m, --message <file>  rules shown below the "connection refused" message, copied to
                        ~<user>/.ai/con-refused.txt ({user} and {host} are replaced).
                        Without it, an account that has no rules yet gets the default
                        ones (/etc/add-ai-user/con-refused.txt); "--message default"
                        applies them again
  -p, --password        set the user's password (asked interactively)
  -s, --sudo            add the user to the sudo group (asks for a password if it has none)
  -u, --update          <user> already exists: (re)apply the add-ai-user setup to it
      --host <name>     host name shown in the refusal message
      --system-only     install or update the system part only
      --remove <user>   take <user> out of add-ai-user (the account and its files are kept)
      --uninstall       remove add-ai-user from the system (users and their files are kept)
  -h, --help            show this help
EOF
}

SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
LIB=/usr/local/lib/add-ai-user
CONF_DIR=/etc/add-ai-user
GROUP=add-ai-user
SSHD_CONF=/etc/ssh/sshd_config.d/60-add-ai-user.conf
UNITS=/etc/systemd/system
OMT_REPO=https://github.com/gpakosz/.tmux.git
UTF8_MARK='#tmux-utf8#'
STAMP=$(date +%Y%m%d-%H%M%S)

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

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
  install_deps
  grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config ||
    die "/etc/ssh/sshd_config doesn't include /etc/ssh/sshd_config.d/*.conf"

  say "Installing add-ai-user in $LIB"
  getent group "$GROUP" >/dev/null || groupadd --system "$GROUP"
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
  [ -f "$CONF_DIR/con-refused.txt" ] || install -m 644 "$SRC/etc/con-refused.txt" "$CONF_DIR/con-refused.txt"
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

ask_key() {  # no --key: ask for one, then confirm it or enter it again
  local key fingerprint answer
  [ -t 0 ] || die "no --key given and no terminal to ask for one (or use --no-key)"
  say "No --key given: paste the SSH public key $TARGET will log in with"
  while :; do
    read -r -p "SSH public key: " key || die "cancelled"
    key=$(printf '%s' "$key" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
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
  if $SUDO; then
    usermod -aG sudo "$USER_NAME"
    [ "$(passwd -S "$USER_NAME" | cut -d' ' -f2)" = P ] || PASSWORD=true
  fi
  if $PASSWORD; then passwd "$USER_NAME"; fi

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

  local host rules=$HOME_DIR/.ai/con-refused.txt source=''
  host=$(. "$CONF_DIR/add-ai-user.conf"; echo "${SSH_HOST:-$(hostname -f)}")
  if [ "$MESSAGE" = default ] || { [ -z "$MESSAGE" ] && [ ! -e "$rules" ]; }; then
    source=$CONF_DIR/con-refused.txt
  elif [ -n "$MESSAGE" ]; then
    source=$MESSAGE
  fi
  if [ -n "$source" ]; then
    say "Rules shown to refused connections: ~/.ai/con-refused.txt (from $source)"
    as_user mkdir -p "$HOME_DIR/.ai"
    sed "s/{user}/$USER_NAME/g; s/{host}/$host/g" "$source" | as_user tee "$rules" >/dev/null
  fi

  systemctl enable --now --quiet "add-ai-user-janitor@$USER_NAME.timer"
  if as_user tmux has-session 2>/dev/null; then
    as_user tmux source-file "$HOME_DIR/.config/tmux/tmux.conf" && say "Reloaded the running tmux of $USER_NAME"
  fi

  if ! [ -s "$HOME_DIR/.ssh/authorized_keys" ] && [ "$(passwd -S "$USER_NAME" | cut -d' ' -f2)" != P ]; then
    warn "$USER_NAME has neither an SSH key nor a password: nobody can log in yet (see --key)"
  fi
  say "Done. $USER_NAME works through tmux:"
  cat <<EOF
    human: ssh -t $USER_NAME@$host tmux new -A -s main
    AI:    ssh $USER_NAME@$host tmux new -d -s <session>      (e.g. fix-login-bug)
           ssh $USER_NAME@$host "tmux send-keys -t <session> '<command>' Enter"
           ssh $USER_NAME@$host tmux capture-pane -p -t <session>
    watch: ssh -t $USER_NAME@$host tmux attach -r -t <session>
    rules: $rules
    logs:  $HOME_DIR/tmux-logs (read them with tmux-logs)
EOF
}

remove_user() {
  local user=$1
  id "$user" >/dev/null 2>&1 || die "no user $user"
  systemctl disable --now "add-ai-user-janitor@$user.timer" >/dev/null 2>&1 || true
  gpasswd -d "$user" "$GROUP" >/dev/null 2>&1 || true
  say "$user is no longer an add-ai-user account (the account, its tmux setup and its logs are kept)"
}

uninstall() {
  local timer
  for timer in "$UNITS"/timers.target.wants/add-ai-user-janitor@*.timer; do
    [ -e "$timer" ] && remove_user "$(basename "$timer" .timer | cut -d@ -f2)"
  done
  rm -f "$SSHD_CONF"
  sshd -t && reload_sshd
  rm -f "$UNITS/add-ai-user-janitor@.service" "$UNITS/add-ai-user-janitor@.timer" /usr/local/bin/tmux-logs
  systemctl daemon-reload
  rm -rf "$LIB"
  groupdel "$GROUP" 2>/dev/null || true
  say "add-ai-user removed. Kept: $CONF_DIR, the users, their ~/tmux-logs and ~/.config/tmux"
  say "(their ~/.config/tmux/tmux.conf now points to a removed Oh my tmux!)"
}

# -- main ----------------------------------------------------------------------

KEYS=() NO_KEY=false MESSAGE='' PASSWORD=false SUDO=false UPDATE=false HOST_NAME=''
ACTION=user TARGET=''
while (($#)); do
  case $1 in
    -k|--key)      KEYS+=("${2:?$1 needs a value}"); shift 2 ;;
    --no-key)      NO_KEY=true; shift ;;
    -m|--message)  MESSAGE=${2:?$1 needs a file}; shift 2 ;;
    -p|--password) PASSWORD=true; shift ;;
    -s|--sudo)     SUDO=true; shift ;;
    -u|--update)   UPDATE=true; shift ;;
    --host)        HOST_NAME=${2:?$1 needs a name}; shift 2 ;;
    --system-only) ACTION=system; shift ;;
    --remove)      ACTION=remove TARGET=${2:?$1 needs a user}; shift 2 ;;
    --uninstall)   ACTION=uninstall; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option $1 (see --help)" ;;
    *)             [ -z "$TARGET" ] || die "one user at a time"; TARGET=$1; shift ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run me as root (sudo $0 ...)"
[ -z "$HOST_NAME" ] || [[ $HOST_NAME =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid host name: $HOST_NAME"
[ -z "$MESSAGE" ] || [ "$MESSAGE" = default ] || [ -r "$MESSAGE" ] || die "cannot read $MESSAGE"
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
    # ask for a key before changing anything, unless the user already has one
    if ((${#KEYS[@]} == 0)) && ! $NO_KEY && { [ -z "$home" ] || [ ! -s "$home/.ssh/authorized_keys" ]; }; then
      ask_key
    fi
    install_system
    setup_user "$TARGET"
    ;;
esac
