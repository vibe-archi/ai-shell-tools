#!/bin/bash
# probe-restricted.sh [test-user]: what the restricted mode can rely on, on this machine.
# Run as root. test-user is an existing unprivileged account (default: aitest).
# Temporary changes, all undone on exit: transient units and sockets in /run, one nft table,
# and a linger attempt by the test user. Nothing is installed.
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
TEST_USER=${1:-aitest}
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
id "$TEST_USER" >/dev/null 2>&1 || { echo "no user $TEST_USER"; exit 1; }
UID_T=$(id -u "$TEST_USER")
SOCK_DIR=/run/ai-diag-probe
UNIT_DIR=/run/systemd/system

cleanup() {
    systemctl stop ai-diag-probe.socket >/dev/null 2>&1
    rm -f "$UNIT_DIR/ai-diag-probe.socket" "$UNIT_DIR/ai-diag-probe@.service"
    systemctl daemon-reload
    rm -rf "$SOCK_DIR"
    nft delete table inet ai_diag_probe >/dev/null 2>&1
    loginctl disable-linger "$TEST_USER" >/dev/null 2>&1
}
trap cleanup EXIT

section() { printf '\n== %s\n' "$*"; }
one_line() { head -c 400 | tr '\n' ' '; }
as_user() { timeout 20 runuser -u "$TEST_USER" -- env -u TMUX HOME="$(getent passwd "$TEST_USER" | cut -d: -f6)" "$@"; }

# unit NAME [-p PROP]... -- CMD...: run CMD in a transient unit, show exit code and output
unit() {
    local name=$1 out rc
    shift
    out=$(timeout 40 systemd-run --quiet --wait --pipe --collect "$@" </dev/null 2>&1)
    rc=$?
    printf '%-30s rc=%-3s %s\n' "$name" "$rc" "$(printf '%s' "$out" | one_line)"
}

section 'Machine'
echo "virt=$(systemd-detect-virt 2>&1) container=$(systemd-detect-virt --container 2>&1)"
echo "systemd=$(systemctl --version | head -1)"
echo "kernel=$(uname -r)"
. /etc/os-release; echo "os=$PRETTY_NAME"
echo "cgroup_controllers=$(cat /sys/fs/cgroup/cgroup.controllers 2>&1)"
echo "user_slice_controllers=$(cat /sys/fs/cgroup/user.slice/cgroup.controllers 2>&1)"
for key in net.ipv4.ping_group_range kernel.dmesg_restrict kernel.perf_event_paranoid \
           kernel.kptr_restrict kernel.yama.ptrace_scope kernel.apparmor_restrict_unprivileged_userns \
           kernel.unprivileged_userns_clone user.max_user_namespaces; do
    printf '%s=%s\n' "$key" "$(sysctl -n "$key" 2>&1 | one_line)"
done
echo "ping_caps=$(getcap "$(command -v ping)" 2>&1) ping_mode=$(stat -c %A "$(command -v ping)" 2>&1)"
echo "mtr_packet=$(getcap /usr/bin/mtr-packet 2>&1) $(stat -c %A /usr/bin/mtr-packet 2>&1)"
echo "bwrap=$(command -v bwrap || echo absent) claude=$(as_user sh -c 'command -v claude' || echo absent) codex=$(as_user sh -c 'command -v codex' || echo absent)"
echo "polkit=$(pkaction --version 2>&1 | head -1) rules_dir=$(ls -d /etc/polkit-1/rules.d 2>&1)"
echo "lxcfs=$(grep -c lxcfs /proc/mounts) pam_namespace=$(ls /usr/lib/*/security/pam_namespace.so /lib/*/security/pam_namespace.so 2>/dev/null | head -1)"
echo "last=$(command -v last || echo absent) lastb=$(command -v lastb || echo absent) lslogins=$(command -v lslogins || echo absent)"

section 'systemd sandbox directives (rc=0 means the unit ran)'
unit baseline                  -- /bin/true
for prop in ProtectSystem=strict ProtectHome=read-only PrivateTmp=yes PrivateDevices=yes \
            ProtectKernelTunables=yes ProtectKernelModules=yes ProtectKernelLogs=yes \
            ProtectControlGroups=yes ProtectClock=yes ProtectHostname=yes \
            RestrictNamespaces=yes LockPersonality=yes RestrictRealtime=yes \
            RestrictSUIDSGID=yes MemoryDenyWriteExecute=yes SystemCallArchitectures=native \
            NoNewPrivileges=yes CapabilityBoundingSet=CAP_NET_RAW \
            MemoryMax=128M CPUQuota=25% TasksMax=16 Nice=15 IOSchedulingClass=idle \
            RuntimeMaxSec=30 'SystemCallFilter=@system-service' \
            'RestrictAddressFamilies=AF_UNIX AF_NETLINK'; do
    unit "$prop" -p "$prop" -- /bin/true
done

section 'Sandbox effects'
write_test='touch /etc/.ai-diag-probe 2>/dev/null && { rm -f /etc/.ai-diag-probe; echo WROTE; } || echo denied'
unit 'write /etc, no sandbox'      -- /bin/sh -c "$write_test"
unit 'write /etc, ProtectSystem'   -p ProtectSystem=strict -- /bin/sh -c "$write_test"
unit 'write /etc, nobody'          -p User=nobody -- /bin/sh -c "$write_test"
unit 'tmp is private'              -p PrivateTmp=yes -- /bin/sh -c 'ls -A /tmp | wc -l'
unit 'home read-only'              -p ProtectSystem=strict -p ProtectHome=read-only -- /bin/sh -c 'touch /root/.ai-diag-probe 2>&1 | head -1; echo done'

section 'Tools in a non-root unit with ambient capabilities'
nb() { # nb NAME CAPS CMD...
    local name=$1 caps=$2
    shift 2
    unit "$name" -p User=nobody -p NoNewPrivileges=yes -p "AmbientCapabilities=$caps" -p "CapabilityBoundingSet=$caps" -- "$@"
}
nb 'nft list, NET_ADMIN'        CAP_NET_ADMIN /usr/sbin/nft list ruleset
nb 'nft list, no cap'           ''            /usr/sbin/nft list ruleset
nb 'iptables-save, NET_ADMIN'   CAP_NET_ADMIN /usr/sbin/iptables-save
nb 'ss -p, PTRACE+DAC'          'CAP_SYS_PTRACE CAP_DAC_READ_SEARCH' /usr/bin/ss -H -tulnp
nb 'ss -p, no cap'              ''            /usr/bin/ss -H -tulnp
nb 'lsof, PTRACE+DAC'           'CAP_SYS_PTRACE CAP_DAC_READ_SEARCH' /usr/bin/lsof -n -P -w -b -S 5 -i -sTCP:LISTEN
nb 'dmesg, SYSLOG'              CAP_SYSLOG    /usr/bin/dmesg --nopager --level=err
nb 'dmidecode, DAC'             CAP_DAC_READ_SEARCH /usr/sbin/dmidecode -q -t system
nb 'tcpdump, NET_RAW'           CAP_NET_RAW   /usr/bin/timeout 5 /usr/bin/tcpdump -i any -p -n -q -l -s 128 -c 3
nb 'perf stat, PERFMON'         CAP_PERFMON   /bin/true
nb 'ufw status, NET_ADMIN'      CAP_NET_ADMIN /usr/sbin/ufw status
unit 'journalctl, group'  -p User=nobody -p NoNewPrivileges=yes -p SupplementaryGroups=systemd-journal -- /usr/bin/journalctl --no-pager -q -n 1 -o short-iso
unit 'journalctl, no group' -p User=nobody -p NoNewPrivileges=yes -- /usr/bin/journalctl --no-pager -q -n 1 -o short-iso
unit 'journalctl -k, group' -p User=nobody -p NoNewPrivileges=yes -p SupplementaryGroups=systemd-journal -- /usr/bin/journalctl --no-pager -q -k -n 1 -o short-iso
unit 'fail2ban-client, root' -p NoNewPrivileges=yes -- /bin/sh -c 'command -v fail2ban-client >/dev/null && fail2ban-client ping || echo absent'
unit 'smartctl, root'  -p NoNewPrivileges=yes -- /bin/sh -c 'command -v smartctl >/dev/null && smartctl --scan || echo absent'

section 'Socket activation with a group-protected socket'
GROUP_T=$(id -gn "$TEST_USER")
cat > "$UNIT_DIR/ai-diag-probe.socket" <<EOF
[Socket]
ListenStream=$SOCK_DIR/probe.sock
SocketUser=root
SocketGroup=$GROUP_T
SocketMode=0660
DirectoryMode=0755
Accept=yes
MaxConnections=4
TriggerLimitIntervalSec=2s
TriggerLimitBurst=1000
EOF
cat > "$UNIT_DIR/ai-diag-probe@.service" <<'EOF'
[Unit]
CollectMode=inactive-or-failed
[Service]
Type=exec
ExecStart=/bin/sh -c 'read line; echo "got:$line uid=$(id -u) nnp=$(grep NoNewPrivs /proc/self/status | cut -f2)"'
StandardInput=socket
StandardOutput=socket
StandardError=journal
User=nobody
NoNewPrivileges=yes
RuntimeMaxSec=10
EOF
systemctl daemon-reload
systemctl start ai-diag-probe.socket; echo "socket start rc=$? state=$(systemctl is-active ai-diag-probe.socket)"
ls -l "$SOCK_DIR/probe.sock" 2>&1
client='import socket,sys
s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1]); s.sendall(b"hello\n")
print(s.recv(200).decode().strip())'
echo "member ($TEST_USER): $(as_user python3 -c "$client" "$SOCK_DIR/probe.sock" 2>&1 | tail -1)"
echo "member under no_new_privs: $(as_user setpriv --no-new-privs python3 -c "$client" "$SOCK_DIR/probe.sock" 2>&1 | tail -1)"
echo "non-member (nobody): $(timeout 20 runuser -u nobody -- python3 -c "$client" "$SOCK_DIR/probe.sock" 2>&1 | tail -1)"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    as_user python3 -c "$client" "$SOCK_DIR/probe.sock" >/dev/null 2>&1 &
done
wait
echo "after a burst of 20: socket=$(systemctl is-active ai-diag-probe.socket)"

section "no_new_privs as $TEST_USER (expected: 1, sudo/su refused)"
nnp() { as_user setpriv --no-new-privs "$@" 2>&1 | one_line; }
echo "flag:        $(nnp grep NoNewPrivs /proc/self/status)"
echo "sudo:        $(nnp sudo -n true)"
echo "su:          $(nnp su -c true root </dev/null)"
echo "pkexec:      $(nnp pkexec --disable-internal-agent /bin/true </dev/null)"
echo "crontab -l:  $(nnp crontab -l)"
echo "ping:        $(nnp ping -n -c 1 -W 2 127.0.0.1 | tail -c 120)"
echo "tracepath:   $(nnp tracepath -n -m 2 127.0.0.1 | tail -c 80)"
echo "mtr:         $(nnp mtr -n -r -c 1 127.0.0.1 | tail -c 120)"
echo "tcpdump:     $(nnp timeout 3 tcpdump -i any -c 1 | tail -c 120)"
echo "tmux:        $(nnp tmux -L ai-diag-probe new-session -d -s probe 'sleep 1' ; nnp tmux -L ai-diag-probe kill-server; echo ok)"
if command -v bwrap >/dev/null; then
    echo "bwrap:       $(nnp bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all /bin/echo bwrap-ok)"
fi
echo "unshare -U:  $(nnp unshare -U /bin/echo userns-ok)"
for cli in claude codex; do
    path=$(as_user sh -c "command -v $cli" 2>/dev/null)
    [ -n "$path" ] && echo "$cli:      $(nnp "$path" --version)"
done

section "IPC from $TEST_USER under no_new_privs (polkit decides)"
echo "restart ssh:  $(nnp systemctl --no-ask-password restart ssh)"
echo "reboot:       $(nnp systemctl --no-ask-password --dry-run reboot)"
echo "set timezone: $(nnp timedatectl --no-ask-password set-timezone UTC)"
echo "enable-linger self: $(nnp loginctl --no-ask-password enable-linger "$TEST_USER"; echo rc=$?) now=$(loginctl show-user "$TEST_USER" -p Linger 2>&1)"
loginctl disable-linger "$TEST_USER" >/dev/null 2>&1
echo "write /etc:   $(nnp touch /etc/.ai-diag-probe)"; rm -f /etc/.ai-diag-probe

section 'Limits on the user slice'
slice="user-$UID_T.slice"
systemctl set-property --runtime "$slice" MemoryMax=2G TasksMax=512 CPUQuota=200% 2>&1 | one_line; echo "set-property rc=${PIPESTATUS[0]}"
systemctl show "$slice" -p MemoryMax -p TasksMax -p CPUQuotaPerSecUSec -p ActiveState 2>&1 | one_line; echo
systemctl revert "$slice" >/dev/null 2>&1

section 'Mount namespaces and tmpfs (pam_namespace needs this)'
echo "unshare+tmpfs: $(timeout 10 unshare -m sh -c 'mount -t tmpfs -o size=1m tmpfs /mnt && echo mounted' 2>&1 | one_line)"

section "nft filtering by owner (blocks new TCP connections of $TEST_USER to 1.1.1.1:443)"
reach='import socket,sys
s=socket.create_connection(("1.1.1.1",443),timeout=5); print("connected")'
echo "before: $(as_user python3 -c "$reach" 2>&1 | tail -1)"
nft add table inet ai_diag_probe 2>&1 | one_line
nft 'add chain inet ai_diag_probe out { type filter hook output priority 0; policy accept; }' 2>&1 | one_line
nft add rule inet ai_diag_probe out meta skuid "$UID_T" ct state new ip daddr 1.1.1.1 tcp dport 443 reject 2>&1 | one_line
echo "nft rule rc=$? rules=$(nft list table inet ai_diag_probe 2>&1 | grep -c skuid)"
echo "blocked user: $(as_user python3 -c "$reach" 2>&1 | tail -1)"
echo "other user (nobody): $(timeout 20 runuser -u nobody -- python3 -c "$reach" 2>&1 | tail -1)"
nft delete table inet ai_diag_probe

section 'Done'
