#!/usr/bin/env bash
# setup-ubuntu-rdp.sh: XFCE remote desktop for Ubuntu 24.04+ over RDP (xrdp + xorgxrdp,
# Xorg session, RFX codec) with Google Chrome. RDP is reached through an SSH tunnel, or
# directly from the network when you choose so.
# Version 2.0.0. Run it INSIDE Ubuntu (VM or container), never on a Proxmox host.
# Single file: the small Python configuration helper is embedded below. See --help.
#
# References:
# https://github.com/neutrinolabs/xrdp/releases
# https://github.com/neutrinolabs/xorgxrdp/releases
# https://github.com/neutrinolabs/xrdp/blob/v0.10.6.1/xrdp/gfx.toml
# https://github.com/neutrinolabs/xrdp/blob/v0.10.6.1/sesman/sesman.ini.in
# https://forum.proxmox.com/threads/apparmor-help-needed-for-lxc-container.164523/
# https://www.google.com/linuxrepositories/
#
# IPv6, DNS, routes and Proxmox confinement are left alone. The firewall (ufw) is only
# touched to open the RDP port when you choose public access.
# No --no-sandbox, no "allow all", no graphical root login.
# No automatic downgrade, Snap purge, apt full-upgrade or reboot.

set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MIN_XRDP=0.10.6.1
MIN_XORGXRDP=0.10.5
# Empty settings come from the previous run (SETTINGS), else from their defaults.
RDP_USER=''          # default: desktop
ACCESS=''            # local | public, default: asked
PORT=''              # default: 3389
ALLOW_FROM=''        # "any" on the command line clears a saved restriction
SESSION_LOCALE=''    # default: the system's if UTF-8, else C.UTF-8
FAIL2BAN=''          # default: 1
SETTINGS=/etc/setup-ubuntu-rdp/settings
RDP_GROUP=rdp-users
SOURCE=auto
INSTALL_CHROME=1
APPARMOR_MODE=auto
RESET_PASSWORD=0
KEEP_BUILD_DEPS=0
F2B_JAIL=xrdp-authfail
F2B_MAXRETRY=5
F2B_FINDTIME=10m
F2B_BANTIME=1h
UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu
UBUNTU_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
DEB_CACHE=/var/cache/setup-ubuntu-rdp
UFW_COMMENT=setup-ubuntu-rdp
WORK=''
BACKUP=''
LOG=''
BUILD_LOG=''
MASKED_BY_US=()
WARNINGS=()
SERVICES_TOUCHED=0
READY=0

usage() {
    cat <<'HELP'
Usage: sudo bash setup-ubuntu-rdp.sh [options]

  --user NAME              Linux account of the desktop (default: desktop).
  --reset-password         Also set the password of an existing account again.
  --local                  RDP only listens on 127.0.0.1: reach it through an SSH
                           tunnel (recommended).
  --public                 RDP listens on every interface: reach it directly.
                           Without --local or --public, the script asks (local
                           when there is no terminal to ask).
  --allow-from ADDRESS     With --public: only accept RDP from this IP address or
                           network (e.g. 203.0.113.7 or 203.0.113.0/24). Needs an
                           active ufw firewall. "--allow-from any" lifts it.
  --port N                 RDP port (default: 3389).
  --no-fail2ban            With --public: don't install the fail2ban jail that bans
                           for 1 hour an address with 5 failed RDP logins in 10
                           minutes (installed by default in public mode).
  --fail2ban               Put the fail2ban jail back after --no-fail2ban.
  --locale NAME            UTF-8 locale of the desktop session, e.g. fr_FR.UTF-8
                           (default: the system's when it is UTF-8, else C.UTF-8).
  --source MODE            Where xrdp and xorgxrdp come from:
                             auto     (default) the Ubuntu repositories when they
                                      are recent enough, else a backport
                             repo     the Ubuntu repositories only
                             backport rebuild the source packages of a newer
                                      Ubuntu release on this one
                             ppa      the community PPA ppa:t.o/xrdp
  --keep-build-deps        Keep the packages installed to build the backport.
  --no-chrome              Don't install or update Google Chrome.
  --chrome-apparmor MODE   auto | on | off (default: auto). auto = network fix for
                           Chrome only in an LXC container, if Chrome's AppArmor
                           profile and its local include exist.
  -h, --help               Show this help.

Requirements: Ubuntu 24.04 or later with systemd, IPv4 Internet access, an admin
account and an interactive terminal to set a password. Chrome needs amd64;
--no-chrome lets you try other architectures.

Versions: xrdp >= 0.10.6.1 and xorgxrdp >= 0.10.5 (they fix about twenty CVEs),
0.10.x branch only. A new branch (0.11, 1.x...) needs a review of this script.
When the repositories are too old, the backport downloads the source packages of
the next Ubuntu releases from archive.ubuntu.com (signature checked by APT) and
builds them here, unprivileged; binary packages of another release are never
installed. Run the script again to rebuild when newer sources are published.

What it does: backs up the configuration files, installs or updates the
components, sets up XFCE for the chosen account, RFX codec only, TLS, RDP on
127.0.0.1 (or every interface with --public), and lets the members of the
rdp-users group open a desktop session. The account is NOT a sudoer. Existing
passwords are kept.

Running it again: do it over SSH or a console, after LOGGING OUT of the XFCE
session. The script refuses to run while an xrdp-chansrv process exists. It
restarts the xrdp services but doesn't kill user sessions. It reuses the
choices of the previous run (account, access mode, port, address restriction,
locale, fail2ban: /etc/setup-ubuntu-rdp/settings); options change them, e.g.
--public or --local to switch the access mode.

Modified files are backed up; this is not a package rollback nor a snapshot.
Take a Proxmox snapshot before using it on a machine with important work.

Exit codes: 0 = server checks OK; 2 = done with warnings;
1 (or any other non-zero code) = installation stopped, see the log.
HELP
}

say()  { printf '\n==> %s\n' "$*"; }
warn() { WARNINGS+=("$*"); printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

has_tty() { ( : </dev/tty ) 2>/dev/null; }
valid_address() {  # IPv4 or IPv6 address, optionally a network (/prefix): prints "ok"
    if [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ||
          $1 =~ ^[0-9A-Fa-f]*:[0-9A-Fa-f:.]*(/[0-9]{1,3})?$ ]]; then
        echo ok
    fi
}
ask() {  # ask PROMPT: read an answer on the terminal (not logged)
    local reply=''
    printf '%s' "$1" >/dev/tty
    read -r reply </dev/tty || true
    printf '%s\n' "$reply"
}

installed_version() {
    local result
    result=$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' "$1" 2>/dev/null) || return 0
    [[ $result == 'ii |'* ]] && printf '%s\n' "${result#*|}" || true
}

candidate_version() {
    apt-cache policy "$1" | awk '/Candidate:/ {print $2; exit}'
}

version_ok() {
    local version=${1#*:}
    [[ $version == 0.10.* ]] && dpkg --compare-versions "$version" ge "$2"
}

best_version() {
    local pkg=$1 minimum=$2 installed candidate best=''
    installed=$(installed_version "$pkg")
    candidate=$(candidate_version "$pkg")
    if version_ok "$installed" "$minimum"; then best=$installed; fi
    if version_ok "$candidate" "$minimum"; then
        if [[ -z $best ]] || dpkg --compare-versions "$candidate" gt "$best"; then
            best=$candidate
        fi
    fi
    printf '%s\n' "$best"
}

check_future_branches() {
    local pkg version
    for pkg in xrdp xorgxrdp; do
        for version in "$(installed_version "$pkg")" "$(candidate_version "$pkg")"; do
            [[ -z $version || $version == '(none)' ]] && continue
            if dpkg --compare-versions "${version#*:}" ge 0.11; then
                die "$pkg $version: branch not validated by this script. No downgrade will be attempted."
            fi
        done
    done
}

backup_path() {
    local path=$1
    [[ -e $path || -L $path ]] || return 0
    [[ -e "$BACKUP/files$path" || -L "$BACKUP/files$path" ]] && return 0
    cp -a --parents -- "$path" "$BACKUP/files/"
}

apt_update() { apt-get -o APT::Update::Error-Mode=any update; }
apt_install() {
    apt-get -y -o DPkg::Lock::Timeout=180 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        --no-install-recommends --no-remove install "$@"
}

ufw_enabled() { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; }

cleanup() {
    local rc=$?
    trap - EXIT ERR
    if (( rc != 0 && SERVICES_TOUCHED && ! READY )); then
        # Don't leave xrdp listening on every interface after a partial installation.
        # SSH and the console are independent from it.
        systemctl stop xrdp.service xrdp-sesman.service >/dev/null 2>&1 || true
    fi
    local unit
    for unit in "${MASKED_BY_US[@]}"; do
        systemctl unmask --runtime "$unit" >/dev/null 2>&1 || true
    done
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    if (( rc != 0 && ! READY )); then
        printf '\nInstallation stopped. Packages are not rolled back.\n' >&2
        printf 'Log: %s\nBackups: %s\n' "$LOG" "$BACKUP" >&2
        printf 'Fix the problem, then run the script again over SSH or a console.\n' >&2
    fi
    exit "$rc"
}

write_config_helper() {
    cat > "$WORK/configure.py" <<'PY'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

# Keep comments and repeated keys (sesman.ini has several param=):
# a strict ConfigParser doesn't fit these files.
def edit_section(text, name, values):
    sections = list(re.finditer(r'^[ \t]*\[([^]\r\n]+)\][ \t]*\r?$', text, re.M))
    matches = [(i, m) for i, m in enumerate(sections) if m[1].lower() == name.lower()]
    if len(matches) != 1:
        raise ValueError(f'Section [{name}] missing or duplicated')
    index, match = matches[0]
    begin = match.end()
    end = sections[index + 1].start() if index + 1 < len(sections) else len(text)
    wanted = {key.lower(): (key, value) for key, value in values.items()}
    seen, lines = set(), []
    for line in text[begin:end].splitlines():
        setting = re.match(r'^\s*([A-Za-z][\w.]*)\s*=', line)
        key = setting[1].lower() if setting else None
        if key in wanted:
            canonical, value = wanted[key]
            if key not in seen and value is not None:
                lines.append(f'{canonical}={value}')
            seen.add(key)
        else:
            lines.append(line)
    for key, (canonical, value) in wanted.items():
        if key not in seen and value is not None:
            lines.append(f'{canonical}={value}')
    body = '\n'.join(lines).strip('\n')
    return text[:begin] + '\n' + body + '\n\n' + text[end:]


def atomic_write(path, text, mode=0o644):
    path = Path(path)
    if path.is_symlink():
        raise ValueError(f'Refusing to replace a symlinked configuration file: {path}')
    previous = path.stat() if path.exists() else None
    fd, temporary = tempfile.mkstemp(prefix='.setup-rdp-', dir=path.parent)
    try:
        os.fchmod(fd, stat.S_IMODE(previous.st_mode) if previous else mode)
        if previous:
            os.fchown(fd, previous.st_uid, previous.st_gid)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure_xrdp(directory, group, listen):
    directory = Path(directory)
    path = directory / 'xrdp.ini'
    text = edit_section(path.read_text(), 'Globals', {
        'port': listen,
        'runtime_user': 'xrdp', 'runtime_group': 'xrdp',
        'security_layer': 'tls', 'ssl_protocols': 'TLSv1.2, TLSv1.3',
        'certificate': '/etc/xrdp/cert.pem', 'key_file': '/etc/xrdp/key.pem',
        'allow_channels': 'true', 'max_bpp': '32', 'autorun': 'Xorg',
    })
    text = edit_section(text, 'Channels', {'drdynvc': 'true', 'cliprdr': 'true'})
    text = edit_section(text, 'Xorg', {'ip': None, 'port': '-1', 'code': '20'})
    atomic_write(path, text)

    path = directory / 'sesman.ini'
    text = edit_section(path.read_text(), 'Globals', {
        'ListenPort': 'sesman.socket',
        'EnableUserWindowManager': 'true',
        'DefaultWindowManager': 'startwm.sh',
    })
    text = edit_section(text, 'Security', {
        'AllowRootLogin': 'false', 'SessionSockdirGroup': 'xrdp',
        'TerminalServerUsers': group, 'AlwaysGroupCheck': 'true',
    })
    text = edit_section(text, 'Sessions', {
        'KillDisconnected': 'false', 'DisconnectedTimeLimit': '0',
        'IdleTimeLimit': '0', 'Policy': 'Default',
    })
    # fail2ban reads the AUTHFAIL lines that xrdp-sesman logs at the INFO level
    text = edit_section(text, 'Logging', {'LogLevel': 'INFO'})
    # Replace ONLY the first param= (the Xorg binary).
    match = re.search(r'^\[Xorg\][ \t]*\r?$(.*?)(?=^\[|\Z)', text, re.M | re.S)
    if not match:
        raise ValueError('No Xorg section in sesman.ini')
    body, count = re.subn(r'^[ \t]*param[ \t]*=.*$',
                         'param=/usr/lib/xorg/Xorg', match[1], count=1, flags=re.M)
    if count != 1:
        raise ValueError('No Xorg command in sesman.ini')
    text = text[:match.start(1)] + body + text[match.end(1):]
    atomic_write(path, text)

    path = directory / 'gfx.toml'
    text = edit_section(path.read_text(), 'codec', {'order': '[ "RFX" ]'})
    # Ubuntu 24.04+ ships Python >= 3.12, with tomllib.
    import tomllib
    parsed = tomllib.loads(text)
    if parsed['codec']['order'] != ['RFX']:
        raise ValueError('RFX codec check failed')
    atomic_write(path, text)


def apparmor_override(path):
    path = Path(path)
    text = path.read_text() if path.exists() else ''
    if re.search(r'^\s*(?:allow\s+)?all\s*,', text, re.M):
        print('WARNING: an old "allow all" rule exists; it is kept, this script did not create it.')
    rules = ['network inet stream,', 'network inet dgram,',
             'network inet6 stream,', 'network inet6 dgram,']
    normal = {' '.join(line.split()) for line in text.splitlines()}
    missing = [rule for rule in rules if rule not in normal]
    if missing:
        text = text.rstrip() + '\n\n# setup-ubuntu-rdp: Chrome network in LXC\n'
        text += '\n'.join(missing) + '\n'
        atomic_write(path, text)


if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == 'xrdp' and len(sys.argv) == 5:
        configure_xrdp(sys.argv[2], sys.argv[3], sys.argv[4])
    elif len(sys.argv) == 3 and sys.argv[1] == 'apparmor':
        apparmor_override(sys.argv[2])
    else:
        raise SystemExit('Usage: configure.py xrdp DIRECTORY GROUP LISTEN | apparmor FILE')
PY
}

# -- backport: rebuild the xrdp / xorgxrdp sources of a newer Ubuntu release ---------

apt_tmp() {  # apt-get on a temporary deb-src list, without touching the system's
    apt-get -q -o Dir::Etc::SourceList="$WORK/apt/sources.list" \
        -o Dir::Etc::SourceParts="$WORK/apt/parts" -o Dir::State::Lists="$WORK/apt/lists" \
        -o Dir::Cache="$WORK/apt/cache" "$@"
}

newest_source() {  # newest 0.10.x version >= minimum of a source package in the temporary list
    local pkg=$1 minimum=$2 version best=''
    while read -r version; do
        version_ok "$version" "$minimum" || continue
        if [[ -z $best ]] || dpkg --compare-versions "$version" gt "$best"; then best=$version; fi
    done < <(apt-cache -o Dir::Etc::SourceList="$WORK/apt/sources.list" \
        -o Dir::Etc::SourceParts="$WORK/apt/parts" -o Dir::State::Lists="$WORK/apt/lists" \
        -o Dir::Cache="$WORK/apt/cache" showsrc "$pkg" 2>/dev/null | awk '/^Version:/ {print $2}' || true)
    printf '%s\n' "$best"
}

installed_packages() { dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" {print $2}' | sort; }

build_one() {  # build_one PACKAGE VERSION: build the backport as nobody, set BUILT_DEB
    local pkg=$1 version=$2 dsc dir backport
    dsc=$WORK/build/${pkg}_${version#*:}.dsc
    [[ -f $dsc ]] || die "$dsc was not downloaded."
    say "Installing the build dependencies of $pkg"
    apt-get -y -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold --no-install-recommends build-dep "$dsc"
    dir=$WORK/build/$pkg-src
    runuser -u nobody -- dpkg-source -x "$dsc" "$dir" >> "$BUILD_LOG" 2>&1 || die "Cannot unpack $dsc (see $BUILD_LOG)."
    backport="$version~$VERSION_ID.1"
    {
        printf '%s (%s) %s; urgency=medium\n\n' "$pkg" "$backport" "$CODENAME"
        printf '  * No-change backport to Ubuntu %s, built by setup-ubuntu-rdp.sh.\n\n' "$VERSION_ID"
        printf ' -- setup-ubuntu-rdp <root@localhost>  %s\n\n' "$(date -R)"
        cat "$dir/debian/changelog"
    } > "$WORK/changelog"
    install -o nobody -g nogroup -m 0644 "$WORK/changelog" "$dir/debian/changelog"
    say "Building $pkg $backport (a few minutes; log: $BUILD_LOG)"
    if ! (cd "$dir" && runuser -u nobody -- env HOME="$WORK/build/home" \
            DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" \
            dpkg-buildpackage -b -uc -us -rfakeroot) >> "$BUILD_LOG" 2>&1; then
        tail -n 30 "$BUILD_LOG" >&2
        die "The build of $pkg failed, see $BUILD_LOG."
    fi
    BUILT_DEB=$WORK/build/${pkg}_${backport#*:}_$(dpkg --print-architecture).deb
    [[ -f $BUILT_DEB ]] || die "$BUILT_DEB was not produced."
    install -d -m 0755 "$DEB_CACHE"
    install -m 0644 "$BUILT_DEB" "$DEB_CACHE/"
}

remove_build_deps() {
    if (( KEEP_BUILD_DEPS )); then
        say 'Build dependencies kept (--keep-build-deps)'
        return 0
    fi
    say 'Removing the packages installed only to build the backport'
    installed_packages > "$WORK/packages-after-build"
    comm -13 "$WORK/packages-before-build" "$WORK/packages-after-build" |
        grep -vxE 'xrdp|xorgxrdp' > "$WORK/packages-new" || true
    [[ -s $WORK/packages-new ]] || return 0
    xargs -a "$WORK/packages-new" apt-mark auto >/dev/null
    # only what we installed, never what was already removable before
    apt-get -s autoremove | awk '/^Remv/ {print $2}' | grep -Fxf "$WORK/packages-new" \
        > "$WORK/packages-remove" || true
    [[ -s $WORK/packages-remove ]] || return 0
    xargs -a "$WORK/packages-remove" apt-get -y -o DPkg::Lock::Timeout=180 purge
}

build_backport() {
    local series='' found='' src_xrdp='' src_xorg=''
    [[ -r $UBUNTU_KEYRING ]] || die "$UBUNTU_KEYRING is missing (package ubuntu-keyring)."
    [[ -r /usr/share/distro-info/ubuntu.csv ]] || apt_install distro-info-data
    install -d "$WORK/apt/lists/partial" "$WORK/apt/cache/archives/partial" "$WORK/apt/parts"
    for series in $(awk -F, -v current="$VERSION_ID" 'NR > 1 && $1 + 0 > current + 0 {print $3}' \
            /usr/share/distro-info/ubuntu.csv); do
        say "Looking for xrdp >= $MIN_XRDP and xorgxrdp >= $MIN_XORGXRDP sources in Ubuntu $series"
        printf 'deb-src [signed-by=%s] %s %s main universe\n' "$UBUNTU_KEYRING" "$UBUNTU_MIRROR" "$series" \
            > "$WORK/apt/sources.list"
        apt_tmp update >/dev/null 2>&1 || { echo "  (no sources for $series)"; continue; }
        src_xrdp=$(newest_source xrdp "$MIN_XRDP")
        src_xorg=$(newest_source xorgxrdp "$MIN_XORGXRDP")
        if [[ -n $src_xrdp && -n $src_xorg ]]; then found=$series; break; fi
    done
    [[ -n $found ]] || die "No newer Ubuntu release has the sources of xrdp >= $MIN_XRDP and xorgxrdp >= $MIN_XORGXRDP."
    say "Backport: building xrdp $src_xrdp and xorgxrdp $src_xorg from the Ubuntu $found sources"
    installed_packages > "$WORK/packages-before-build"
    apt_install dpkg-dev fakeroot build-essential
    install -d -o nobody -g nogroup -m 0755 "$WORK/build" "$WORK/build/home"
    (cd "$WORK/build" && apt_tmp source --download-only "xrdp=$src_xrdp" "xorgxrdp=$src_xorg")
    chown -R nobody:nogroup "$WORK/build"
    build_one xrdp "$src_xrdp"
    apt_install "$BUILT_DEB"   # xorgxrdp's build needs xrdp >= 0.10.5
    build_one xorgxrdp "$src_xorg"
    apt_install "$BUILT_DEB"
    remove_build_deps
}

restore_package_defaults_if_needed() {
    local old=$1 current=$2 need=0 file source deb
    [[ -n $old && ${old#*:} == 0.9.* ]] && need=1
    for file in xrdp.ini sesman.ini startwm.sh gfx.toml; do
        [[ -f /etc/xrdp/$file ]] || need=1
    done
    (( need )) || return 0
    say 'Migration/repair: getting the configuration files of the installed xrdp package'
    mkdir -p "$WORK/package" "$WORK/extracted"
    deb=$(compgen -G "$DEB_CACHE/xrdp_${current#*:}_*.deb" | head -n 1 || true)
    if [[ -z $deb ]]; then
        (cd "$WORK/package" && apt-get download "xrdp=$current")
        deb=$(compgen -G "$WORK/package/*.deb" | head -n 1 || true)
    fi
    [[ -n $deb && -f $deb ]] || die 'xrdp package not found.'
    dpkg-deb -x "$deb" "$WORK/extracted"
    for file in xrdp.ini sesman.ini startwm.sh gfx.toml; do
        source=''
        local candidate
        for candidate in \
            "$WORK/extracted/etc/xrdp/$file" \
            "$WORK/extracted/etc/xrdp/$file.original" \
            "$WORK/extracted/usr/share/xrdp/$file"; do
            if [[ -f $candidate ]]; then source=$candidate; break; fi
        done
        [[ -n $source ]] || die "$file not found in the package: stopping rather than guessing."
        if grep -Eq '@[A-Za-z_][A-Za-z_0-9]*@' "$source"; then
            die "$file still contains build-time variables; configuration not replaced."
        fi
        local mode=0644
        [[ $file == *.sh ]] && mode=0755
        install -m "$mode" -o root -g root "$source" "/etc/xrdp/$file"
    done
}

# -- access, firewall, locale --------------------------------------------------

choose_access() {
    [[ -z $ACCESS ]] || return 0
    if ! has_tty; then
        ACCESS=local
        say 'No terminal to ask: RDP stays local (SSH tunnel). Use --public to expose it.'
        return 0
    fi
    cat >/dev/tty <<EOF

How will you reach the desktop?
  1) through an SSH tunnel: RDP only listens on 127.0.0.1 (recommended)
  2) directly from the network: RDP listens on port $PORT of every interface.
     Anyone who can reach this port can try passwords; fail2ban bans for
     $F2B_BANTIME an address with $F2B_MAXRETRY failures in $F2B_FINDTIME. Restricting
     the port to your IP address is still advised.
EOF
    local reply
    while :; do
        reply=$(ask 'Choice [1]: ')
        case ${reply:-1} in
            1) ACCESS=local; break ;;
            2) ACCESS=public; break ;;
        esac
    done
    if [[ $ACCESS == public && -z $ALLOW_FROM ]] && ufw_enabled; then
        while :; do
            ALLOW_FROM=$(ask 'Only accept RDP from this IP address or network (empty = from anywhere): ')
            [[ -z $ALLOW_FROM || $(valid_address "$ALLOW_FROM") == ok ]] && break
            printf 'Not an address: use something like 203.0.113.7 or 203.0.113.0/24.\n' >/dev/tty
        done
    fi
}

configure_firewall() {
    if ! ufw_enabled; then
        if [[ $ACCESS == public ]]; then
            warn "No active ufw firewall here: port $PORT is open to whoever can reach this machine. Check your provider's firewall."
        fi
        return 0
    fi
    local number
    # remove the rules of a previous run (numbers shift: delete from the last one)
    for number in $(ufw status numbered | grep -F "# $UFW_COMMENT" | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn || true); do
        ufw --force delete "$number" >/dev/null
    done
    [[ $ACCESS == public ]] || return 0
    if [[ -n $ALLOW_FROM ]]; then
        say "Firewall: allowing RDP (port $PORT) from $ALLOW_FROM only"
        ufw allow proto tcp from "$ALLOW_FROM" to any port "$PORT" comment "$UFW_COMMENT"
    else
        say "Firewall: allowing RDP (port $PORT) from anywhere"
        ufw allow "$PORT/tcp" comment "$UFW_COMMENT"
    fi
}

configure_fail2ban() {  # public RDP: ban addresses that keep failing to log in
    local jail=/etc/fail2ban/jail.d/setup-ubuntu-rdp.conf
    local filter=/etc/fail2ban/filter.d/xrdp-authfail.conf
    local test_ip=203.0.113.250 line found i  # 203.0.113.0/24: documentation addresses
    if [[ $ACCESS != public ]] || (( ! FAIL2BAN )); then
        if [[ -f $jail ]]; then
            say "fail2ban: removing the $F2B_JAIL jail"
            rm -f -- "$jail"
            if systemctl is-active --quiet fail2ban; then fail2ban-client reload >/dev/null; fi
        fi
        return 0
    fi
    say "fail2ban: ban for $F2B_BANTIME an address with $F2B_MAXRETRY failed RDP logins in $F2B_FINDTIME"
    apt_install fail2ban nftables
    install -d -m 0755 /etc/fail2ban/filter.d /etc/fail2ban/jail.d
    cat > "$filter" <<'FILTER'
# setup-ubuntu-rdp: failed xrdp logins, as logged by xrdp-sesman >= 0.10 for fail2ban:
#   [20261020-15:40:01] [INFO ] AUTHFAIL: user=bob ip=203.0.113.7 time=1760967601
# Anchored at the end of the line, so that a user name can't smuggle another address.
[Definition]
failregex = ^\s*\[INFO\s*\]\s+AUTHFAIL: user=.* ip=(?:::ffff:)?<ADDR> time=\d+\s*$
datepattern = ^\[%%Y%%m%%d-%%H:%%M:%%S\]
FILTER
    cat > "$jail" <<JAIL
# setup-ubuntu-rdp: public RDP, ban for $F2B_BANTIME an address with $F2B_MAXRETRY failed
# logins in $F2B_FINDTIME. Unban: fail2ban-client set $F2B_JAIL unbanip <address>
[$F2B_JAIL]
enabled  = true
filter   = xrdp-authfail
logpath  = /var/log/xrdp-sesman.log
backend  = auto
port     = $PORT
protocol = tcp
maxretry = $F2B_MAXRETRY
findtime = $F2B_FINDTIME
bantime  = $F2B_BANTIME
JAIL
    chmod 0644 "$filter" "$jail"
    # the filter must catch the address in what xrdp-sesman writes (IPv4 or IPv4-mapped)
    for line in "[20261020-15:40:01] [INFO ] AUTHFAIL: user=test ip=$test_ip time=1760967601" \
                "[20261020-15:40:01] [INFO ] AUTHFAIL: user=a ip=1.2.3.4 time=1 ip=::ffff:$test_ip time=1760967601"; do
        found=$(fail2ban-regex -o ip "$line" "$filter" 2>/dev/null | tail -n 1 || true)
        [[ $found == "$test_ip" ]] || die "The fail2ban filter doesn't read xrdp's AUTHFAIL lines (got: ${found:-nothing})."
    done
    touch /var/log/xrdp-sesman.log
    systemctl enable --quiet fail2ban
    systemctl restart fail2ban
    for i in $(seq 1 15); do
        fail2ban-client status "$F2B_JAIL" >/dev/null 2>&1 && break
        sleep 1
    done
    (( i < 15 )) || fail2ban-client status "$F2B_JAIL" >/dev/null 2>&1 ||
        die "The $F2B_JAIL fail2ban jail doesn't start (journalctl -u fail2ban)."
    # check that a ban really reaches the firewall here (containers may refuse it)
    fail2ban-client set "$F2B_JAIL" banip "$test_ip" >/dev/null
    for i in $(seq 1 10); do
        { nft list ruleset 2>/dev/null; iptables -S 2>/dev/null; } | grep -qF "$test_ip" && break
        sleep 1
    done
    if ! { nft list ruleset 2>/dev/null; iptables -S 2>/dev/null; } | grep -qF "$test_ip"; then
        fail2ban-client set "$F2B_JAIL" unbanip "$test_ip" >/dev/null || true
        die "fail2ban bans don't reach the firewall on this machine. Fix it, or run again with --no-fail2ban."
    fi
    fail2ban-client set "$F2B_JAIL" unbanip "$test_ip" >/dev/null
}

configure_locale() {  # configure_locale HOME: UTF-8 locale for the desktop session
    local home=$1 system_lang wanted
    system_lang=$([ -r /etc/default/locale ] && . /etc/default/locale; printf '%s' "${LANG:-}")
    if [[ -z $SESSION_LOCALE ]]; then
        [[ $system_lang =~ [Uu][Tt][Ff]-?8$ ]] && return 0  # the session gets the system's
        SESSION_LOCALE=C.UTF-8
    fi
    wanted=${SESSION_LOCALE,,}
    wanted=${wanted/utf-8/utf8}
    if ! locale -a | tr '[:upper:]' '[:lower:]' | grep -qxF "$wanted"; then
        say "Generating the $SESSION_LOCALE locale"
        apt_install locales
        locale-gen "$SESSION_LOCALE"
    fi
    say "Desktop session locale: $SESSION_LOCALE (~/.xsessionrc)"
    [[ ! -L "$home/.xsessionrc" ]] || die "$home/.xsessionrc is a symlink; handle it by hand."
    backup_path "$home/.xsessionrc"
    runuser -u "$RDP_USER" -- sh -c 'umask 022; cat > "$1"' sh "$home/.xsessionrc" <<EOF
# setup-ubuntu-rdp: locale of the desktop session
export LANG=$SESSION_LOCALE
EOF
}

wait_for_listener() {
    local listeners=''
    for _ in $(seq 1 15); do
        listeners=$(ss -H -ltn "sport = :$PORT" | awk '{print $4}' | sort -u | tr '\n' ' ')
        [[ -n $listeners ]] && break
        sleep 1
    done
    if [[ $ACCESS == local ]]; then
        [[ $listeners == "127.0.0.1:$PORT " ]] || die "Unexpected xrdp listener(s): ${listeners:-none}"
    else
        [[ " $listeners" =~ \ (0\.0\.0\.0|\*|\[::\]):$PORT\  ]] || die "Unexpected xrdp listener(s): ${listeners:-none}"
    fi
}

configure_chrome_apparmor() {
    (( INSTALL_CHROME )) || return 0
    [[ $APPARMOR_MODE != off ]] || return 0
    if [[ $APPARMOR_MODE == auto && $VIRT != lxc ]]; then
        say 'Chrome AppArmor fix skipped: not an LXC container'
        return 0
    fi
    local profile=/etc/apparmor.d/chrome override=/etc/apparmor.d/local/chrome
    if [[ ! -f $profile ]]; then
        warn 'No AppArmor profile for Chrome: none is made up. Check Chrome from the desktop.'
        return 0
    fi
    if ! grep -Eq '^[[:space:]]*#?include([[:space:]]+if[[:space:]]+exists)?[[:space:]]+[<"]local/chrome[>"]' "$profile"; then
        warn "Chrome's profile doesn't include its local override; fix not applied."
        return 0
    fi
    if [[ -L $override ]]; then
        warn 'Chrome AppArmor override is a symlink: left alone, check it by hand.'
        return 0
    fi
    say 'Targeted AppArmor fix: IPv4 and IPv6 TCP/UDP sockets for Chrome'
    backup_path "$override"
    local existed=0
    [[ -f $override ]] && existed=1
    install -d -m 0755 /etc/apparmor.d/local
    python3 "$WORK/configure.py" apparmor "$override"
    if ! apparmor_parser -Q -T "$profile" || ! apparmor_parser -r -T "$profile"; then
        if (( existed )); then
            cp -a -- "$BACKUP/files$override" "$override"
        else
            rm -f -- "$override"
        fi
        warn 'AppArmor refused or failed to reload the profile. Previous override restored; do not disable AppArmor on Proxmox.'
    fi
}

# -- settings of the previous run ----------------------------------------------

load_settings() {  # fill what the command line left empty with the previous run's choices
    [[ -r $SETTINGS ]] || return 0
    local key value
    while IFS='=' read -r key value; do
        case $key in
            RDP_USER)       RDP_USER=${RDP_USER:-$value} ;;
            ACCESS)         ACCESS=${ACCESS:-$value} ;;
            PORT)           PORT=${PORT:-$value} ;;
            ALLOW_FROM)     ALLOW_FROM=${ALLOW_FROM:-$value} ;;
            SESSION_LOCALE) SESSION_LOCALE=${SESSION_LOCALE:-$value} ;;
            FAIL2BAN)       FAIL2BAN=${FAIL2BAN:-$value} ;;
        esac
    done < "$SETTINGS"
}

save_settings() {
    install -d -m 0755 "${SETTINGS%/*}"
    cat > "$SETTINGS" <<EOF
# setup-ubuntu-rdp: choices of the last run, reused by the next one.
# Command line options win: --local / --public switch the access mode.
RDP_USER=$RDP_USER
ACCESS=$ACCESS
PORT=$PORT
ALLOW_FROM=$ALLOW_FROM
SESSION_LOCALE=$SESSION_LOCALE
FAIL2BAN=$FAIL2BAN
EOF
    chmod 0644 "$SETTINGS"
}

# -- main ----------------------------------------------------------------------

main() {
    while (( $# )); do
        case $1 in
            --allow-ppa) SOURCE=ppa; shift ;;  # former option
            --no-chrome) INSTALL_CHROME=0; shift ;;
            --reset-password) RESET_PASSWORD=1; shift ;;
            --keep-build-deps) KEEP_BUILD_DEPS=1; shift ;;
            --no-fail2ban) FAIL2BAN=0; shift ;;
            --fail2ban) FAIL2BAN=1; shift ;;
            --local) ACCESS=local; shift ;;
            --public) ACCESS=public; shift ;;
            --user|--chrome-apparmor|--source|--port|--allow-from|--locale)
                (( $# >= 2 )) || die "$1 needs a value."
                case $1 in
                    --user) RDP_USER=$2 ;;
                    --chrome-apparmor) APPARMOR_MODE=$2 ;;
                    --source) SOURCE=$2 ;;
                    --port) PORT=$2 ;;
                    --allow-from) ALLOW_FROM=$2 ;;
                    --locale) SESSION_LOCALE=$2 ;;
                esac
                shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
    done
    if [[ -n $ALLOW_FROM && -z $ACCESS ]]; then ACCESS=public; fi
    load_settings
    [[ $ALLOW_FROM != any ]] || ALLOW_FROM=''  # kept in local mode, for a later --public
    RDP_USER=${RDP_USER:-desktop}
    PORT=${PORT:-3389}
    FAIL2BAN=${FAIL2BAN:-1}
    [[ $RDP_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $RDP_USER != root ]] || die 'Invalid user name.'
    [[ $APPARMOR_MODE =~ ^(auto|on|off)$ ]] || die 'Invalid --chrome-apparmor mode.'
    [[ $SOURCE =~ ^(auto|repo|backport|ppa)$ ]] || die 'Invalid --source mode.'
    [[ $PORT =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die 'Invalid port.'
    [[ -z $ALLOW_FROM || $ALLOW_FROM == any || $(valid_address "$ALLOW_FROM") == ok ]] || die 'Invalid --allow-from address.'
    [[ -z $SESSION_LOCALE || $SESSION_LOCALE =~ ^[A-Za-z_@]+\.[Uu][Tt][Ff]-?8$ ]] || die 'Invalid --locale (expected a UTF-8 locale such as fr_FR.UTF-8).'
    (( EUID == 0 )) || die "Run it as root: sudo bash $0"
    [[ -r /etc/os-release ]] || die 'Cannot detect the distribution.'
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ ${ID:-} == ubuntu ]] || die "This script targets Ubuntu, not ${ID:-unknown}. Never run it on Proxmox."
    dpkg --compare-versions "${VERSION_ID:-0}" ge 24.04 || die 'Ubuntu >= 24.04 required.'
    CODENAME=${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}
    [[ $CODENAME =~ ^[a-z]+$ ]] || die 'Ubuntu release name not found.'
    [[ -d /run/systemd/system ]] || die 'systemd must be the service manager.'
    local arch
    arch=$(dpkg --print-architecture)
    if (( INSTALL_CHROME )) && [[ $arch != amd64 ]]; then
        die "The Chrome .deb used here needs amd64 (this is $arch). Use --no-chrome."
    fi
    if pgrep -x xrdp-chansrv >/dev/null; then
        die 'An xrdp session exists. Save your work, log out OF XFCE, then run again over SSH or a console.'
    fi
    local unit state
    for unit in xrdp.service xrdp-sesman.service; do
        state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        [[ $state != masked* ]] || die "$unit is masked by an administrator: leaving that policy alone."
    done
    local audit
    audit=$(dpkg --audit 2>&1 || true)
    [[ -z $audit ]] || die "dpkg is in an incomplete state, fix it first: $audit"
    if getent passwd "$RDP_USER" >/dev/null; then
        grep -q "^${RDP_USER}:" /etc/passwd || die 'Use a LOCAL Linux account.'
        (( $(id -u "$RDP_USER") >= 1000 )) || die 'The chosen account is a system account.'
    fi
    choose_access
    if [[ $ACCESS == public && -n $ALLOW_FROM ]] && ! ufw_enabled; then
        die "--allow-from needs an active ufw firewall (allow SSH, then: ufw enable), or drop it."
    fi

    umask 077
    mkdir -p /run/lock
    exec 9>/run/lock/setup-ubuntu-rdp.lock
    flock -n 9 || die 'Another run is in progress.'
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)-$$
    BACKUP=/var/backups/setup-ubuntu-rdp/$stamp
    install -d -m 0700 "$BACKUP/files" /var/log/setup-ubuntu-rdp
    LOG=/var/log/setup-ubuntu-rdp/$stamp.log
    BUILD_LOG=/var/log/setup-ubuntu-rdp/$stamp-build.log
    touch "$LOG"; chmod 0600 "$LOG"
    exec > >(tee -a "$LOG") 2>&1
    WORK=$(mktemp -d /tmp/setup-ubuntu-rdp.XXXXXXXX)
    chmod 0755 "$WORK" # public packages and tools only, no password
    trap cleanup EXIT
    trap 'rc=$?; if (( ! READY || rc != 2 )); then printf "\nFailed at line %s (code %s).\n" "$LINENO" "$rc" >&2; fi' ERR
    # Packages and APT sources must keep their normal permissions.
    # Backups and logs are already protected (0700/0600).
    umask 022
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l UCF_FORCE_CONFFOLD=1
    VIRT=$(systemd-detect-virt --container 2>/dev/null || true)
    local old_xrdp
    old_xrdp=$(installed_version xrdp)
    say "Ubuntu $VERSION_ID ($CODENAME), $arch, container=${VIRT:-none}, user=$RDP_USER, access=$ACCESS"
    printf 'Backups: %s\nLog: %s\n' "$BACKUP" "$LOG"
    backup_path /etc/xrdp
    backup_path /etc/X11/xrdp
    backup_path /etc/apt
    dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$BACKUP/packages-before.tsv"
    apt-cache policy xrdp xorgxrdp > "$BACKUP/apt-policy-before.txt"

    # Keep xrdp from starting (on every interface) while APT installs it.
    SERVICES_TOUCHED=1
    for unit in xrdp.service xrdp-sesman.service; do
        if systemctl is-active --quiet "$unit"; then systemctl stop "$unit"; fi
        systemctl mask --runtime "$unit"
        MASKED_BY_US+=("$unit")
        state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        [[ $state == masked* ]] || die "Cannot mask $unit: check the local systemd units."
    done
    apt_update
    apt-get check
    say 'Installing tools and enabling the Ubuntu universe component'
    apt_install ca-certificates curl python3 software-properties-common \
        ssl-cert openssl sudo procps iproute2
    add-apt-repository -y -n universe
    apt_update

    check_future_branches
    local target_xrdp target_xorg backport=0
    target_xrdp=$(best_version xrdp "$MIN_XRDP")
    target_xorg=$(best_version xorgxrdp "$MIN_XORGXRDP")
    if [[ -z $target_xrdp || -z $target_xorg ]]; then
        case $SOURCE in
            repo) die "The Ubuntu repositories only have xrdp $(candidate_version xrdp) / xorgxrdp $(candidate_version xorgxrdp). Use --source backport." ;;
            auto|backport) backport=1 ;;
            ppa)
                say "Checking that the PPA publishes for $CODENAME (never another Ubuntu release)"
                if ! curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 15 --max-time 60 \
                    "https://ppa.launchpadcontent.net/t.o/xrdp/ubuntu/dists/$CODENAME/Release" \
                    -o "$WORK/ppa-release"; then
                    die "The PPA doesn't publish for $CODENAME. Use --source backport."
                fi
                say 'Adding the community PPA t.o/xrdp (--source ppa)'
                add-apt-repository -y -n ppa:t.o/xrdp
                # Only xrdp and xorgxrdp from THIS PPA; everything else stays Ubuntu's.
                install -d -m 0755 /etc/apt/preferences.d
                cat > /etc/apt/preferences.d/90-setup-ubuntu-rdp-ppa <<'PIN'
Package: xrdp xorgxrdp
Pin: release o=LP-PPA-t.o-xrdp
Pin-Priority: 500

Package: *
Pin: release o=LP-PPA-t.o-xrdp
Pin-Priority: -1
PIN
                chmod 0644 /etc/apt/preferences.d/90-setup-ubuntu-rdp-ppa
                apt_update
                check_future_branches
                target_xrdp=$(best_version xrdp "$MIN_XRDP")
                target_xorg=$(best_version xorgxrdp "$MIN_XORGXRDP")
                [[ -n $target_xrdp && -n $target_xorg ]] || die 'No compatible xrdp/xorgxrdp pair in the PPA.'
                ;;
        esac
    fi
    apt-cache policy xrdp xorgxrdp
    if (( backport )); then
        build_backport
        target_xrdp=$(installed_version xrdp)
        target_xorg=$(installed_version xorgxrdp)
    fi
    say "Installing XFCE, xrdp $target_xrdp and xorgxrdp $target_xorg"
    local xrdp_packages=()
    (( backport )) || xrdp_packages=("xrdp=$target_xrdp" "xorgxrdp=$target_xorg")
    apt_install xfce4 xfce4-terminal mousepad dbus-x11 dbus-user-session \
        libpam-systemd x11-xserver-utils libgl1-mesa-dri \
        fonts-dejavu-core fonts-liberation openssh-server \
        "${xrdp_packages[@]}"
    version_ok "$(installed_version xrdp)" "$MIN_XRDP" || die 'Wrong xrdp version installed.'
    version_ok "$(installed_version xorgxrdp)" "$MIN_XORGXRDP" || die 'Wrong xorgxrdp version installed.'
    [[ $(command -v xrdp) == /usr/sbin/xrdp ]] || die 'Another xrdp binary hides the packaged one (manual installation?).'
    [[ -x /usr/lib/xorg/Xorg && -x /usr/bin/startxfce4 ]] || die 'Xorg or XFCE is missing.'

    write_config_helper
    restore_package_defaults_if_needed "$old_xrdp" "$(installed_version xrdp)"
    say 'Setting up the desktop account, without sudo rights'
    if ! id "$RDP_USER" >/dev/null 2>&1; then
        adduser --disabled-password --comment '' "$RDP_USER"
    fi
    local passwd_entry home shell password_state
    passwd_entry=$(getent passwd "$RDP_USER")
    IFS=: read -r _ _ _ _ _ home shell <<< "$passwd_entry"
    [[ $home == /* && $home != / && $home != /root && -d $home ]] || die 'Invalid home directory.'
    [[ $shell != */nologin && $shell != */false ]] || die 'The account has a login shell that forbids logins.'
    getent group "$RDP_GROUP" >/dev/null || groupadd "$RDP_GROUP"
    usermod -aG "$RDP_GROUP" "$RDP_USER"
    [[ ! -L "$home/.xsession" ]] || die "$home/.xsession is a symlink; handle it by hand."
    backup_path "$home/.xsession"
    # Written as the user: root never follows a link planted by the user.
    runuser -u "$RDP_USER" -- sh -c 'umask 077; cat > "$1"; chmod 700 "$1"' sh "$home/.xsession" <<'SESSION'
#!/bin/sh
exec startxfce4
SESSION
    configure_locale "$home"
    password_state=$(passwd -S "$RDP_USER" | awk '{print $2}')
    if [[ $password_state != P ]] || (( RESET_PASSWORD )); then
        has_tty || die "An interactive terminal is needed: run passwd $RDP_USER, then this script again."
        say "Set the Linux/RDP password of $RDP_USER (not logged)"
        [[ $ACCESS == local ]] || printf 'RDP is public: use a long, unique password.\n' >/dev/tty
        passwd "$RDP_USER" </dev/tty >/dev/tty 2>&1
        [[ $(passwd -S "$RDP_USER" | awk '{print $2}') == P ]] || die 'The account must have an active password.'
    fi

    say 'Configuring TLS, listening address, Xorg session, channels and RFX codec'
    usermod -aG ssl-cert xrdp
    if [[ ! -s /etc/ssl/certs/ssl-cert-snakeoil.pem || ! -s /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
        make-ssl-cert generate-default-snakeoil
    fi
    [[ -e /etc/xrdp/cert.pem ]] || ln -sfn /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/xrdp/cert.pem
    [[ -e /etc/xrdp/key.pem ]] || ln -sfn /etc/ssl/private/ssl-cert-snakeoil.key /etc/xrdp/key.pem
    runuser -u xrdp -- test -r /etc/xrdp/cert.pem || die 'xrdp cannot read its certificate.'
    runuser -u xrdp -- test -r /etc/xrdp/key.pem || die 'xrdp cannot read its TLS key; check permissions.'
    local listen
    if [[ $ACCESS == local ]]; then listen="tcp://127.0.0.1:$PORT"; else listen=$PORT; fi
    python3 "$WORK/configure.py" xrdp /etc/xrdp "$RDP_GROUP" "$listen"

    if (( INSTALL_CHROME )); then
        say 'Installing Google Chrome stable from the official .deb, without Snap'
        apt_install apparmor
        if [[ -z $(installed_version google-chrome-stable) ]]; then
            curl --proto '=https' --tlsv1.2 -fSL --retry 2 --connect-timeout 20 --max-time 600 \
                https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
                -o "$WORK/google-chrome.deb"
            chmod 0644 "$WORK/google-chrome.deb"
            [[ $(dpkg-deb -f "$WORK/google-chrome.deb" Package) == google-chrome-stable ]] || die 'Unexpected Chrome package.'
            [[ $(dpkg-deb -f "$WORK/google-chrome.deb" Architecture) == amd64 ]] || die 'Unexpected Chrome architecture.'
            apt_install "$WORK/google-chrome.deb"
        else
            # The official .deb normally adds Google's update repository.
            apt_install google-chrome-stable
        fi
        configure_chrome_apparmor
    fi

    configure_firewall

    say 'Starting the services, without rebooting Ubuntu'
    systemctl daemon-reload
    for unit in "${MASKED_BY_US[@]}"; do systemctl unmask --runtime "$unit"; done
    MASKED_BY_US=()
    systemctl enable xrdp.service
    systemctl restart xrdp-sesman.service
    systemctl restart xrdp.service
    # Don't change an existing SSH setup, nor force a standalone sshd when Ubuntu
    # uses ssh.socket activation.
    if ! systemctl is-active --quiet ssh.service && ! systemctl is-active --quiet ssh.socket; then
        systemctl enable --now ssh.service
    fi
    for unit in xrdp.service xrdp-sesman.service; do
        systemctl is-active --quiet "$unit" || die "$unit is not running."
    done
    wait_for_listener
    configure_fail2ban  # on failure, cleanup stops xrdp: no unprotected public RDP
    READY=1
    save_settings
    say 'Final checks'
    /usr/sbin/xrdp --version
    dpkg-query -W xrdp xorgxrdp
    ss -ltnp "sport = :$PORT"
    if ! runuser -u "$RDP_USER" -- curl -4 -fsSI --connect-timeout 10 --max-time 20 https://www.google.com/; then
        warn "HTTPS/IPv4 test as $RDP_USER failed. The script doesn't change DNS or IPv6 to hide it."
    fi
    dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$BACKUP/packages-after.tsv"

    local address
    address=$(ip -4 -o addr show scope global | awk '{print $4; exit}' | cut -d/ -f1)
    cat <<END

=======================================================================
Server setup done
  RDP user        : $RDP_USER (member of $RDP_GROUP)
  Session         : Xorg / XFCE${SESSION_LOCALE:+, $SESSION_LOCALE}
  GFX codec       : RFX only
  xrdp            : $(installed_version xrdp)
  IPv6/DNS/routes : unchanged
  Backups         : $BACKUP
  Log             : $LOG
END
    if [[ $ACCESS == local ]]; then
        cat <<END
  RDP             : 127.0.0.1:$PORT, through an SSH tunnel

In a Windows PowerShell, open this tunnel and keep it open (adapt the account,
the -i key and -p port to your usual SSH connection):

  ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L 127.0.0.1:13389:127.0.0.1:$PORT SSH_USER@${address:-UBUNTU_IP}

Then, in ANOTHER Windows terminal:

  mstsc /v:127.0.0.1:13389 /w:1920 /h:1080

Or, with the SDL FreeRDP client:

  .\sdl-freerdp.exe /v:127.0.0.1:13389 /u:$RDP_USER /size:1920x1080 /dynamic-resolution +clipboard
END
    else
        cat <<END
  RDP             : port $PORT on every interface (public)${ALLOW_FROM:+, only from $ALLOW_FROM}
  fail2ban        : $( (( FAIL2BAN )) && echo "$F2B_MAXRETRY failed logins in $F2B_FINDTIME = banned for $F2B_BANTIME (jail $F2B_JAIL)" || echo "disabled (--no-fail2ban)")

From Windows:

  mstsc /v:${address:-UBUNTU_IP}:$PORT /w:1920 /h:1080

Or, with the SDL FreeRDP client:

  .\sdl-freerdp.exe /v:${address:-UBUNTU_IP}:$PORT /u:$RDP_USER /size:1920x1080 /dynamic-resolution +clipboard

Public RDP: anyone who can reach port $PORT can try passwords. Keep a long,
unique password, restrict the port to your address (--allow-from, or your
provider's firewall), and run the script with --local to close it again.
If this machine is a container behind NAT, the host must forward port $PORT.
Banned yourself? fail2ban-client status $F2B_JAIL, then
fail2ban-client set $F2B_JAIL unbanip YOUR_IP (Ubuntu's fail2ban also guards SSH).
END
    fi
    cat <<END

Log in as $RDP_USER, NOT as root. No password is stored here.
The local TLS certificate (snakeoil) makes clients show a warning.
Check the desktop, Chrome and resizing from the client: server checks are
not an end-to-end graphical test.

Troubleshooting:
  journalctl -u xrdp -u xrdp-sesman -n 100 --no-pager
  tail -n 100 /var/log/xrdp.log /var/log/xrdp-sesman.log
  tail -n 100 $home/.xsession-errors
=======================================================================
END
    if (( ${#WARNINGS[@]} )); then
        printf '\nDone with %s warning(s):\n' "${#WARNINGS[@]}"
        printf ' - %s\n' "${WARNINGS[@]}"
        return 2
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
