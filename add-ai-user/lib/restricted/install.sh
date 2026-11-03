# shellcheck shell=bash disable=SC1090
# Restricted accounts of add-ai-user: sourced by add-ai-user.sh, which provides say, warn, die,
# as_user and the paths. An agent on such an account reads everything through ai-diag and can
# change nothing outside its home.

RESTRICTED_DIR=$CONF_DIR/restricted
AGENTS_DIR=$CONF_DIR/agents
RESTRICTED_GROUP=add-ai-restricted
DIAG_USER=ai-diag
LOGIN_SHELL=$LIB/restricted/login-shell
SSHD_RESTRICTED=/etc/ssh/sshd_config.d/61-add-ai-restricted.conf
POLKIT_RULE=/etc/polkit-1/rules.d/60-add-ai-user.rules
OUTBOUND_RULES=$RESTRICTED_DIR/outbound.nft
SCANNERS_FILE=$RESTRICTED_DIR/scanners
PRIVILEGED_GROUPS='sudo admin wheel docker lxd incus disk shadow adm systemd-journal kmem kvm libvirt'

catalog() { python3 -I "$SRC/lib/restricted/catalog.py" "$@"; }

# -- questions, asked before anything is changed -------------------------------

choose_account_type() {  # sets RESTRICTED, unless --restricted or --standard did
  local answer
  [ -z "$RESTRICTED" ] || return 0
  if [ -f "$RESTRICTED_DIR/$TARGET.conf" ]; then RESTRICTED=true; return; fi
  if [ -n "$home" ] || [ ! -t 0 ]; then RESTRICTED=false; return; fi
  cat <<'EOF'

Account type:
  standard    the agent can do whatever this user can do; everything is visible in tmux
  restricted  the agent can only read and diagnose: no sudo, nothing outside its home can be
              changed, and you choose what it can read, category by category
EOF
  read -r -p "Account type [s = standard, r = restricted] " answer || die "cancelled"
  case $answer in
    [rR]*) RESTRICTED=true ;;
    *)     RESTRICTED=false ;;
  esac
}

ask_category() {  # the category is added to CATEGORIES if it is chosen
  local category=$1 default answer
  default=$(catalog default "$category")
  case $default in
    always)
      printf '\n\033[1m%s\033[0m (always on)\n' "$category"
      catalog describe "$category" | sed 's/^/  /'
      CATEGORIES+=" $category"
      return ;;
    detected)
      if ! catalog detected "$category"; then
        printf '\n\033[1m%s\033[0m: nothing detected on this machine, skipped\n' "$category"
        return
      fi
      default=yes ;;
  esac
  printf '\n\033[1m%s\033[0m\n' "$category"
  catalog describe "$category" | sed 's/^/  /'
  if [ "$default" = yes ]; then
    read -r -p "  Enable $category? [Y/n] " answer || die "cancelled"
    case $answer in [nN]*) ;; *) CATEGORIES+=" $category" ;; esac
  else
    read -r -p "  Enable $category? [y/N] " answer || die "cancelled"
    case $answer in [yY]*) CATEGORIES+=" $category" ;; esac
  fi
}

ask_scanners() {
  local name answer
  printf '\n  Each scanner runs weekly at low priority, driven by a timer:\n'
  for name in lynis debsums rkhunter chkrootkit debsecan; do
    read -r -p "  Enable $name? [y/N] " answer || die "cancelled"
    case $answer in [yY]*) SCANNERS+=" $name" ;; esac
  done
}

categories_from_allow() {
  local category default
  case $ALLOW in
    all)      CATEGORIES=$(catalog categories | tr '\n' ' ') ;;
    none)     CATEGORIES=base ;;
    defaults)
      CATEGORIES=base
      for category in $(catalog categories); do
        default=$(catalog default "$category")
        if [ "$default" = yes ] || { [ "$default" = detected ] && catalog detected "$category"; }; then
          CATEGORIES+=" $category"
        fi
      done ;;
    *)
      CATEGORIES=base
      for category in ${ALLOW//,/ }; do
        catalog categories | grep -qxF "$category" || die "--allow: no category $category (see: --help)"
        [ "$category" = base ] || CATEGORIES+=" $category"
      done ;;
  esac
  case " $CATEGORIES " in
    *" security_scans "*) SCANNERS='lynis debsums rkhunter chkrootkit debsecan' ;;
  esac
}

ask_location() {
  local answer
  case $LOCATION in
    remote|local) return ;;
    '') ;;
    *) die "--agent-location must be remote or local" ;;
  esac
  [ -t 0 ] || die "no terminal to ask where the agent runs (use --agent-location remote|local)"
  cat <<'EOF'

Where does the AI run?
  remote  it connects from outside over SSH: this account gets no new outbound connection,
          DNS and loopback included (active network tests go through ai-diag)
  local   a Claude or Codex CLI runs on this server: it needs outbound access to its API
EOF
  read -r -p "AI location [r = remote, l = local] " answer || die "cancelled"
  case $answer in
    [lL]*) LOCATION=local ;;
    *)     LOCATION=remote ;;
  esac
}

confirm_switch() {  # an existing account becomes restricted
  local groups='' group answer files
  for group in $PRIVILEGED_GROUPS; do
    id -nG "$TARGET" | tr ' ' '\n' | grep -qxF "$group" && groups+=" $group"
  done
  echo
  say "$TARGET exists and becomes restricted:"
  echo "  - its running sessions and its tmux server will be closed"
  [ -z "$groups" ] || echo "  - it leaves these privileged groups:$groups"
  files=$(grep -lsE "^[[:space:]]*${TARGET}[[:space:]]" /etc/sudoers /etc/sudoers.d/* || true)
  [ -z "$files" ] || echo "  - sudo rules remain in $files, without effect: remove them yourself"
  files=$(timeout 60 find / -xdev -user "$TARGET" -not -path "$home" -not -path "$home/*" -not -path '/proc/*' \
    2>/dev/null | head -20 || true)
  [ -z "$files" ] || printf '  - it still owns these files outside its home, and can still change them:\n%s\n' "$(sed 's/^/      /' <<<"$files")"
  if $ASSUME_YES; then return; fi
  [ -t 0 ] || die "no terminal to confirm this (use --yes)"
  read -r -p "Proceed? [y/N] " answer || die "cancelled"
  case $answer in [yY]*) ;; *) die "cancelled, nothing was changed" ;; esac
}

ask_restricted() {  # sets CATEGORIES, SCANNERS and LOCATION; nothing is changed yet
  local state=$RESTRICTED_DIR/$TARGET.conf category
  $SUDO && die "--sudo makes no sense on a restricted account"
  CATEGORIES='' SCANNERS=''
  if [ -f "$state" ]; then  # an update keeps what isn't asked to change
    if [ -z "$LOCATION" ]; then LOCATION=$(. "$state"; echo "$LOCATION"); fi
    if [ -z "$ALLOW" ] && ! $RESTRICTED_FLAG; then
      CATEGORIES=$(. "$state"; echo "$CATEGORIES")
      SCANNERS=$(. "$state"; echo "$SCANNERS")
      return
    fi
  fi
  if [ -n "$ALLOW" ]; then
    categories_from_allow
  else
    [ -t 0 ] || die "no terminal to ask the categories (use --allow defaults|all|none|<list>)"
    echo
    say "Choose what the agent can read. Nothing here gives write access."
    for category in $(catalog categories); do
      ask_category "$category"
      if [ "$category" = security_scans ]; then
        case " $CATEGORIES " in *" security_scans "*) ask_scanners ;; esac
      fi
    done
    CATEGORIES=${CATEGORIES# }
  fi
  ask_location
  [ -z "$home" ] || [ -f "$state" ] || confirm_switch
}

# -- system part ---------------------------------------------------------------

install_restricted_system() {
  local group sandbox=full unit
  say "Installing the restricted mode"
  install -d -m 755 "$LIB/restricted" "$RESTRICTED_DIR" "$AGENTS_DIR"
  install -m 755 "$SRC"/lib/restricted/{diag-helper,ai-diag,login-shell,run-scans} "$LIB/restricted/"
  install -m 644 "$SRC/lib/restricted/catalog.py" "$LIB/restricted/"
  ln -sfn "$LIB/restricted/ai-diag" /usr/local/bin/ai-diag
  grep -qxF "$LOGIN_SHELL" /etc/shells || printf '%s\n' "$LOGIN_SHELL" >>/etc/shells

  getent group "$RESTRICTED_GROUP" >/dev/null || groupadd --system "$RESTRICTED_GROUP"
  for group in $(catalog groups); do
    getent group "$group" >/dev/null || groupadd --system "$group"
  done
  id "$DIAG_USER" >/dev/null 2>&1 ||
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$DIAG_USER"

  [ -f "$RESTRICTED_DIR/targets" ] || cat >"$RESTRICTED_DIR/targets" <<'EOF'
# Targets an agent may probe, on top of loopback, the gateway and the DNS resolvers.
# One per line: <identifier> <host name or address>, for example:
# www example.com
EOF

  # A container may not allow the mount namespaces of the sandbox; a real host must.
  if ! systemd-run --quiet --wait --pipe -p ProtectSystem=strict -p PrivateTmp=yes -p ProtectHome=read-only \
      /bin/true >/dev/null 2>&1; then
    systemd-detect-virt --container --quiet ||
      die "systemd can't sandbox the collectors on this host: refusing to install them"
    sandbox=degraded
    warn "the container refuses the sandbox: collectors run with their fixed commands and capabilities only"
  fi
  rm -f "$UNITS"/ai-diag-*.socket "$UNITS"/ai-diag-*@.service
  catalog units "$UNITS" "$sandbox"
  install -m 644 "$SRC/systemd/add-ai-user-outbound.service" "$SRC/systemd/add-ai-user-scans.service" \
    "$SRC/systemd/add-ai-user-scans.timer" "$UNITS/"
  systemctl daemon-reload
  for unit in "$UNITS"/ai-diag-*.socket; do
    systemctl enable --quiet "$(basename "$unit")"
    systemctl restart "$(basename "$unit")"
  done

  # logind and friends allow a few things to any user, enable-linger for one
  if [ -d "$(dirname "$POLKIT_RULE")" ]; then
    cat >"$POLKIT_RULE" <<EOF
// add-ai-user: restricted accounts get nothing through polkit
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("$RESTRICTED_GROUP")) { return polkit.Result.NO; }
});
EOF
    chmod 644 "$POLKIT_RULE"
  fi

  install -m 644 "$SRC/sshd/61-add-ai-restricted.conf" "$SSHD_RESTRICTED"
  if ! sshd -t; then
    rm -f "$SSHD_RESTRICTED"
    die "sshd rejected the configuration, $SSHD_RESTRICTED removed"
  fi
  reload_sshd
}

uninstall_restricted_system() {
  local unit group
  for unit in "$UNITS"/ai-diag-*.socket; do
    [ -e "$unit" ] && systemctl disable --now --quiet "$(basename "$unit")"
  done
  systemctl disable --now --quiet add-ai-user-outbound.service add-ai-user-scans.timer 2>/dev/null || true
  nft delete table inet add_ai_user 2>/dev/null || true
  rm -f "$UNITS"/ai-diag-*.socket "$UNITS"/ai-diag-*@.service "$UNITS"/add-ai-user-outbound.service \
    "$UNITS"/add-ai-user-scans.service "$UNITS"/add-ai-user-scans.timer "$POLKIT_RULE" "$SSHD_RESTRICTED" \
    /usr/local/bin/ai-diag
  sed -i "\\|^$LOGIN_SHELL\$|d" /etc/shells
  rm -rf /run/ai-diag /var/lib/ai-diag /var/cache/ai-diag /var/lib/add-ai-user
  id "$DIAG_USER" >/dev/null 2>&1 && userdel "$DIAG_USER"
  for group in $(catalog groups) "$RESTRICTED_GROUP"; do
    groupdel "$group" 2>/dev/null || true
  done
  rm -rf "$OUTBOUND_RULES" "$SCANNERS_FILE"
}

# -- user part -----------------------------------------------------------------

install_category_packages() {
  local category package new=() policy=/usr/sbin/policy-rc.d own_policy=false units
  for category in $CATEGORIES; do
    for package in $(catalog packages "$category" $SCANNERS); do
      dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' || new+=("$package")
    done
  done
  if ((${#new[@]})); then
    say "Installing ${new[*]}"
    apt-get update -q
    # installing a diagnostic tool must not start a service
    if [ ! -e "$policy" ]; then
      printf '#!/bin/sh\nexit 101\n' >"$policy"
      chmod 755 "$policy"
      own_policy=true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${new[@]}" || {
      for package in "${new[@]}"; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$package" ||
          warn "could not install $package: its diagnostics will say unavailable"
      done
    }
    if $own_policy; then rm -f "$policy"; fi
    units=$(catalog units-off "${new[@]}")
    # shellcheck disable=SC2086
    [ -z "$units" ] || systemctl disable --now --quiet $units 2>/dev/null || true
  fi
  case " $CATEGORIES " in
    *" performance "*)
      if [ -f /etc/default/sysstat ]; then
        sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
        systemctl enable --now --quiet sysstat 2>/dev/null || true
      fi ;;
  esac
}

render_scanners() {  # the scanners wanted by any restricted account
  local state wanted='' SCANNERS
  for state in "$RESTRICTED_DIR"/*.conf; do
    [ -e "$state" ] || continue
    SCANNERS=$(. "$state"; echo "${SCANNERS:-}")
    wanted+=" $SCANNERS"
  done
  printf '%s\n' $wanted | sed '/^$/d' | sort -u >"$SCANNERS_FILE"
  if [ -s "$SCANNERS_FILE" ]; then
    systemctl enable --now --quiet add-ai-user-scans.timer
  else
    systemctl disable --now --quiet add-ai-user-scans.timer 2>/dev/null || true
  fi
}

render_outbound() {  # no new outbound connection for the accounts whose agent is remote
  local state uids='' name location
  for state in "$RESTRICTED_DIR"/*.conf; do
    [ -e "$state" ] || continue
    name=$(basename "$state" .conf)
    location=$(. "$state"; echo "${LOCATION:-remote}")
    if [ "$location" = remote ] && id "$name" >/dev/null 2>&1; then
      uids+="${uids:+, }$(id -u "$name")"
    fi
  done
  if [ -z "$uids" ]; then
    systemctl disable --now --quiet add-ai-user-outbound.service 2>/dev/null || true
    nft delete table inet add_ai_user 2>/dev/null || true
    rm -f "$OUTBOUND_RULES"
    return 0
  fi
  if ! command -v nft >/dev/null; then
    say "Installing nftables (it filters the outbound connections of the restricted accounts)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends nftables
  fi
  cat >"$OUTBOUND_RULES" <<EOF
# add-ai-user: restricted accounts whose agent connects from outside open no new connection.
table inet add_ai_user
delete table inet add_ai_user
table inet add_ai_user {
    chain output {
        type filter hook output priority filter; policy accept;
        meta skuid { $uids } ct state established,related accept
        meta skuid { $uids } reject
    }
}
EOF
  systemctl enable --quiet add-ai-user-outbound.service
  systemctl restart add-ai-user-outbound.service
}

restrict_account() {
  local uid group category switching=false memory tasks cpu
  uid=$(id -u "$USER_NAME")
  # A process keeps the groups it started with: a right taken away stays in its running tmux.
  if [ ! -f "$RESTRICTED_DIR/$USER_NAME.conf" ] ||
      [ "$(. "$RESTRICTED_DIR/$USER_NAME.conf"; echo "$CATEGORIES")" != "$CATEGORIES" ]; then
    switching=true
  fi
  for group in $PRIVILEGED_GROUPS; do
    gpasswd -d "$USER_NAME" "$group" >/dev/null 2>&1 || true
  done
  usermod -s "$LOGIN_SHELL" -aG "$RESTRICTED_GROUP" "$USER_NAME"
  for category in $(catalog categories); do
    case " $CATEGORIES " in
      *" $category "*) usermod -aG "$(catalog group "$category")" "$USER_NAME" ;;
      *)               gpasswd -d "$USER_NAME" "$(catalog group "$category")" >/dev/null 2>&1 || true ;;
    esac
  done
  for group in /etc/cron.deny /etc/at.deny; do
    grep -qxF "$USER_NAME" "$group" 2>/dev/null || printf '%s\n' "$USER_NAME" >>"$group"
  done
  loginctl disable-linger "$USER_NAME" 2>/dev/null || true

  memory=$(. "$CONF_DIR/add-ai-user.conf"; echo "${RESTRICTED_MEMORY_MAX:-50%}")
  tasks=$(. "$CONF_DIR/add-ai-user.conf"; echo "${RESTRICTED_TASKS_MAX:-1024}")
  cpu=$(. "$CONF_DIR/add-ai-user.conf"; echo "${RESTRICTED_CPU_QUOTA:-200%}")
  install -d -m 755 "$UNITS/user@$uid.service.d" "$UNITS/user-$uid.slice.d"
  printf '[Service]\nNoNewPrivileges=yes\n' >"$UNITS/user@$uid.service.d/60-add-ai-user.conf"
  printf '[Slice]\nMemoryMax=%s\nTasksMax=%s\nCPUQuota=%s\n' "$memory" "$tasks" "$cpu" \
    >"$UNITS/user-$uid.slice.d/60-add-ai-user.conf"
  systemctl daemon-reload

  cat >"$RESTRICTED_DIR/$USER_NAME.conf" <<EOF
CATEGORIES="$CATEGORIES"
SCANNERS="$SCANNERS"
LOCATION=$LOCATION
EOF
  install_category_packages
  render_scanners
  render_outbound

  if $switching && [ -n "${home:-}" ]; then  # what already runs has no no_new_privs and the old groups
    say "Closing the running sessions of $USER_NAME: its rights have changed"
    as_user tmux kill-server 2>/dev/null || true
    loginctl terminate-user "$USER_NAME" 2>/dev/null || true
  fi
  if [ "$LOCATION" = local ]; then
    warn "the agent runs on this server with outbound access: it can send what it reads anywhere it can reach"
  fi
}

unrestrict_account() {  # back to a standard account; privileged groups are not given back
  local user=$1 uid group home_dir file=$AGENTS_DIR/$1.md
  [ -f "$RESTRICTED_DIR/$user.conf" ] || return 0
  uid=$(id -u "$user")
  home_dir=$(getent passwd "$user" | cut -d: -f6)
  usermod -s /bin/bash "$user"
  gpasswd -d "$user" "$RESTRICTED_GROUP" >/dev/null 2>&1 || true
  for group in $(catalog groups); do
    gpasswd -d "$user" "$group" >/dev/null 2>&1 || true
  done
  for group in /etc/cron.deny /etc/at.deny; do
    [ -f "$group" ] && sed -i "/^$user\$/d" "$group"
  done
  rm -rf "${UNITS:?}/user@$uid.service.d" "${UNITS:?}/user-$uid.slice.d"
  systemctl daemon-reload
  rm -f "$RESTRICTED_DIR/$user.conf"
  if [ -L "$home_dir/AGENTS.md" ] && [ -f "$file" ]; then
    runuser -u "$user" -- rm -f "$home_dir/AGENTS.md"
    runuser -u "$user" -- tee "$home_dir/AGENTS.md" <"$file" >/dev/null
  fi
  rm -f "$file"
  render_scanners
  render_outbound
  say "$user is no longer restricted (privileged groups it had before are not given back)"
}
