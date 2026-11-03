#!/usr/bin/python3
"""Catalog of the restricted accounts of add-ai-user: categories (what the install asks),
collector profiles (one socket and one sandboxed service each) and diagnostics (presets).

Imported by diag-helper and ai-diag; add-ai-user.sh uses its command line:
  catalog.py categories | describe CAT | default CAT | detected CAT | packages CAT [SCANNER...] |
             units-off PACKAGE... | group CAT | groups | agents-block CAT... | units DIR full|degraded
"""
import os
import shutil
import sys

LIB = "/usr/local/lib/add-ai-user/restricted"
SOCK_DIR = "/run/ai-diag"
SERVICE_USER = "ai-diag"
SCANNERS = ("lynis", "debsums", "rkhunter", "chkrootkit", "debsecan")

# id: (default, one-sentence description shown at install, tools shown at install)
# default: "always" (no question), "yes", "detected" (asked only if detected), "no"
CATEGORIES = {
    "base": ("always",
             "Unprivileged read access to processes, services, packages, addresses, disk usage and time.",
             "uptime, free, ps, systemctl, systemd-analyze, timedatectl, chronyc, apt-get -s, pro, df, lsblk, findmnt, ip, ss"),
    "logs": ("yes",
             "Recent system and service log entries, filtered by severity and unit, with risky fields removed; "
             "this text is attacker-influenced and is sent to the model provider in a hosted CLI session.",
             "journalctl, coredumpctl list"),
    "performance": ("yes",
                    "CPU, memory, I/O and network saturation over time, with sysstat installed and its history enabled.",
                    "vmstat, mpstat, iostat, pidstat, sar, top -b, PSI, systemd-cgtop, numastat, slabtop"),
    "network": ("yes",
                "Sockets and owning processes, firewall rules, interface and TCP counters, DNS state, "
                "TLS certificate expiry, and bounded probes to approved targets.",
                "ip, ss, nstat, ethtool, nft, iptables-save, ufw, conntrack, ipset, wg, resolvectl, dig, ping, "
                "tracepath, traceroute, mtr, openssl, curl, lldpcli"),
    "storage": ("yes",
                "Disk health and layout: SMART and NVMe health, RAID, LVM, ZFS, btrfs, and bounded directory sizes.",
                "smartctl, nvme, mdadm, pvs, vgs, lvs, zpool, btrfs, xfs_info, du"),
    "kernel": ("yes",
               "Kernel messages, loaded modules, kernel parameters, taint state, and files held open including deleted ones.",
               "journalctl -k, dmesg, lsmod, sysctl -a, uname, lsof, bpftool"),
    "hardware": ("detected",
                 "Hardware inventory and sensors: CPU, PCI, USB, temperatures, memory errors and BMC sensors, serial numbers removed.",
                 "lscpu, lspci, lsusb, sensors, edac-util, dmidecode, ipmitool, ras-mc-ctl"),
    "accounts": ("yes",
                 "Users, groups, login history and SSH or sudo policy as derived facts; never password hashes, "
                 "private keys, shell history, or names typed by failed logins.",
                 "getent, loginctl, /var/log/wtmp, /var/log/btmp, ssh journal, faillock, sudoers and authorized_keys summaries, sshd -T"),
    "persistence": ("yes",
                    "Cron, at, systemd timers and unit overrides, startup scripts and preload files, "
                    "reported as metadata and hashes with inline values masked.",
                    "systemctl list-timers, systemd-delta, atq, stat, sha256, cron spool reader"),
    "security": ("yes",
                 "Passive security state: AppArmor, audit rules and summaries, fail2ban and CrowdSec status, "
                 "process hardening, and daily setuid, capability and world-writable lists.",
                 "aa-status, auditctl -l/-s, aureport, fail2ban-client status, cscli, /proc/*/status, find, getcap, Suricata alerts"),
    "containers": ("detected",
                   "List containers and VMs with state and resource use; no environment, no exec, no raw inspect.",
                   "docker ps/stats/images/system df, podman ps, lxc list, virsh -r, crictl, pct list, qm list"),
    "services": ("detected",
                 "Status of detected applications: nginx and Apache counters, PostgreSQL readiness, mail queue counts.",
                 "curl (status pages), pg_isready, postqueue -j"),
    "security_scans": ("no",
                       "Scheduled audits and scanners run by the system, never by the agent; the agent reads the "
                       "latest cached summary with its timestamp. Heavy on disk and memory.",
                       "lynis, debsums, rkhunter, chkrootkit, debsecan"),
    "profiling": ("no",
                  "On-demand aggregate CPU counters and latency histograms from fixed presets; no syscall arguments, "
                  "memory, stacks or per-event data. Unavailable in containers.",
                  "perf stat, biolatency-bpfcc, runqlat-bpfcc"),
    "packet_capture": ("no",
                       "Short on-demand capture printing addresses, ports and lengths only, never payloads; "
                       "it still reveals who talks to whom on this host.",
                       "tcpdump"),
}

# category: [(package, condition, units to keep disabled)]
# Read-only tools only: nothing that starts a service for its own sake or belongs to a
# technology (a firewall, RAID, a database...) is installed; those are used if present.
PACKAGES = {
    "performance": [("sysstat", "always", ()), ("numactl", "always", ())],
    "network": [("ethtool", "always", ()), ("bind9-dnsutils", "always", ()), ("iputils-ping", "always", ()),
                ("iputils-tracepath", "always", ()), ("traceroute", "always", ()), ("mtr-tiny", "always", ()),
                ("conntrack", "always", ()), ("openssl", "always", ()), ("curl", "always", ())],
    "storage": [("smartmontools", "physical", ("smartmontools.service",)),
                ("nvme-cli", "nvme", ("nvmf-autoconnect.service", "nvmefc-boot-connections.service"))],
    "kernel": [("lsof", "always", ()), ("bpftool", "physical", ())],
    "hardware": [("pciutils", "physical", ()), ("usbutils", "physical", ()),
                 ("lm-sensors", "physical", ("lm-sensors.service",)), ("dmidecode", "physical", ()),
                 ("edac-utils", "physical", ("edac.service",)), ("ipmitool", "bmc", ("ipmievd.service",))],
    "security_scans": [("lynis", "scanner", ("lynis.timer", "lynis.service")), ("debsums", "scanner", ()),
                       ("rkhunter", "scanner", ()), ("chkrootkit", "scanner", ("chkrootkit.timer",)),
                       ("debsecan", "scanner", ())],
    "profiling": [("linux-tools-generic", "physical", ()), ("bpfcc-tools", "physical", ())],
    "packet_capture": [("tcpdump", "always", ())],
}

DETECT = {
    "containers": ("docker", "podman", "lxc", "virsh", "crictl", "pct", "qm"),
    "services": ("nginx", "apache2", "pg_isready", "postqueue"),
}


def _profile(category, user=SERVICE_USER, caps="", groups="", families="AF_UNIX AF_NETLINK",
             devices=False, kernel_logs=False, runtime=120, filter_debug=True, connections=8, private_tmp=True):
    return dict(category=category, user=user, caps=caps, groups=groups, families=families,
                devices=devices, kernel_logs=kernel_logs, runtime=runtime,
                filter_debug=filter_debug, connections=connections, private_tmp=private_tmp)


INET = "AF_UNIX AF_NETLINK AF_INET AF_INET6"
READ = "CAP_DAC_READ_SEARCH"
PROC = "CAP_SYS_PTRACE CAP_DAC_READ_SEARCH"

# One socket and one service per privilege level: a single helper would hold the union.
PROFILES = {
    "base": _profile("base", families=INET),
    "logs": _profile("logs", groups="systemd-journal"),
    "performance": _profile("performance"),
    "performance-proc": _profile("performance", caps=PROC),
    "network": _profile("network", families=INET),
    "network-proc": _profile("network", caps=PROC, families=INET),
    "network-admin": _profile("network", caps="CAP_NET_ADMIN"),
    "network-raw": _profile("network", caps="CAP_NET_RAW", families=INET + " AF_PACKET"),
    "network-root": _profile("network", user="root"),
    "storage": _profile("storage", caps=READ, runtime=300),
    "storage-root": _profile("storage", user="root", devices=True),
    "kernel": _profile("kernel", groups="systemd-journal"),
    "kernel-syslog": _profile("kernel", caps="CAP_SYSLOG", kernel_logs=True),
    "kernel-proc": _profile("kernel", caps=PROC, families=INET),
    "kernel-root": _profile("kernel", user="root", filter_debug=False),
    "hardware": _profile("hardware"),
    "hardware-root": _profile("hardware", user="root", devices=True),
    "accounts": _profile("accounts"),
    "accounts-root": _profile("accounts", user="root"),
    "persistence": _profile("persistence"),
    "persistence-read": _profile("persistence", caps=READ),
    "persistence-root": _profile("persistence", user="root"),
    "security": _profile("security"),
    "security-read": _profile("security", caps=READ, runtime=900, private_tmp=False),  # /tmp is part of the scan
    "security-root": _profile("security", user="root"),
    "containers": _profile("containers", user="root", families=INET),
    "services": _profile("services", families=INET),
    "services-root": _profile("services", user="root"),
    "security-scans": _profile("security_scans", user="root"),
    "profiling": _profile("profiling", caps="CAP_PERFMON CAP_BPF", filter_debug=False, connections=1),
    "packet-capture": _profile("packet_capture", caps="CAP_NET_RAW", connections=1,
                               families="AF_UNIX AF_NETLINK AF_INET AF_PACKET"),
}

PRESETS = {}


def preset(category, name, profile, help, argv=None, fn=None, post=None, timeout=15, ttl=0,
           params=None, untrusted=False, physical=False, ok_codes=(0,)):
    """argv: a fixed argument list, or a list of them; {field} is a validated parameter."""
    PRESETS[f"{category}/{name}"] = dict(category=category, name=name, profile=profile, help=help, argv=argv,
                                         fn=fn, post=post, timeout=timeout, ttl=ttl, params=params or {},
                                         untrusted=untrusted, physical=physical, ok_codes=ok_codes)


SYSTEMCTL = ["systemctl", "--no-pager", "--no-ask-password", "--plain", "--no-legend"]
JOURNAL = ["journalctl", "--no-pager", "-q", "-o", "json"]

# -- base ------------------------------------------------------------------------------
preset("base", "uptime", "base", "Uptime and load", ["uptime"])
preset("base", "memory", "base", "Memory usage", ["free", "-w", "-m"])
preset("base", "processes", "base", "Processes, without command-line arguments",
       ["ps", "-eo", "pid,ppid,user,stat,pcpu,pmem,etimes,comm", "--no-headers"], untrusted=True)
preset("base", "failed-units", "base", "Failed systemd units", SYSTEMCTL + ["--failed"])
preset("base", "services", "base", "All service units and their state", SYSTEMCTL + ["list-units", "--type=service", "--all"])
preset("base", "unit-state", "base", "State of one unit (unit=NAME)",
       ["systemctl", "--no-pager", "show", "{unit}", "-p", "ActiveState,SubState,Result,NRestarts,ExecMainStatus,StateChangeTimestamp"],
       params={"unit": "unit"})
preset("base", "boot-time", "base", "Boot duration", ["systemd-analyze", "--no-pager", "time"])
preset("base", "boot-blame", "base", "Slowest units at boot", ["systemd-analyze", "--no-pager", "blame"])
preset("base", "unit-security", "base", "Exposure score of one unit (unit=NAME)",
       ["systemd-analyze", "--no-pager", "security", "{unit}"], params={"unit": "unit"}, ok_codes=(0, 1))
preset("base", "time", "base", "Clock and synchronization state", ["timedatectl", "--no-pager", "--no-ask-password", "show"])
preset("base", "chrony", "base", "chrony tracking", [["chronyc", "-n", "tracking"], ["chronyc", "-n", "sources"]])
preset("base", "packages", "base", "Installed packages",
       ["dpkg-query", "--no-pager", "-W", "-f=${binary:Package}\t${Version}\t${db:Status-Abbrev}\n"])
preset("base", "pending-updates", "base", "Upgrades apt would install (simulation, from the last apt update)",
       ["apt-get", "-s", "-q", "upgrade"], post="apt_upgrades", timeout=60, ttl=3600)
preset("base", "reboot-required", "base", "Whether a reboot is pending", fn="reboot_required")
preset("base", "pro-status", "base", "Ubuntu Pro security status", ["pro", "security-status", "--format", "json"], timeout=60, ttl=3600)
preset("base", "disk-usage", "base", "Disk usage per filesystem", ["df", "-h", "--local", "-x", "tmpfs", "-x", "devtmpfs"], timeout=10)
preset("base", "inodes", "base", "Inode usage per filesystem", ["df", "-i", "--local"], timeout=10)
preset("base", "block-devices", "base", "Block devices", ["lsblk", "-J", "-b", "-o", "NAME,TYPE,SIZE,ROTA,MOUNTPOINTS,FSTYPE,MODEL"])
preset("base", "mounts", "base", "Mount points", ["findmnt", "-J", "-o", "TARGET,SOURCE,FSTYPE,OPTIONS"])
preset("base", "addresses", "base", "IP addresses", ["ip", "-j", "addr", "show"])
preset("base", "routes", "base", "Routes", ["ip", "-j", "route", "show"])
preset("base", "listening", "base", "Listening ports, without process names", ["ss", "-H", "-tuln"])

# -- logs ------------------------------------------------------------------------------
preset("logs", "errors", "logs", "Warnings and errors of the last hour, all units",
       JOURNAL + ["-b", "0", "-p", "warning", "-n", "200", "--since=-1h"], post="journal", untrusted=True)
preset("logs", "recent-errors", "logs", "Warnings and errors over a period (since=15m|1h|24h)",
       JOURNAL + ["-b", "0", "-p", "warning", "-n", "500", "--since={since}"], post="journal",
       params={"since": "since"}, untrusted=True)
preset("logs", "unit", "logs", "Recent entries of one unit (unit=NAME since=15m|1h|24h)",
       JOURNAL + ["-n", "200", "--since={since}", "--unit={unit}"], post="journal",
       params={"unit": "unit", "since": "since"}, untrusted=True)
preset("logs", "journal-size", "logs", "Disk space used by the journal", ["journalctl", "--no-pager", "-q", "--disk-usage"])
preset("logs", "coredumps", "logs", "Crashes of the last 7 days, without their contents",
       ["coredumpctl", "--no-pager", "--no-legend", "list", "--since=-7d", "-n", "20"], ok_codes=(0, 1), untrusted=True)

# -- performance -----------------------------------------------------------------------
preset("performance", "vmstat", "performance", "Run queue, memory, swap, I/O, CPU", ["vmstat", "-w", "1", "5"])
preset("performance", "mpstat", "performance", "CPU per core", ["mpstat", "-P", "ALL", "1", "5"])
preset("performance", "iostat", "performance", "Disk latency and saturation", ["iostat", "-xz", "1", "5"])
preset("performance", "pidstat", "performance", "CPU per process", ["pidstat", "-h", "1", "5"], untrusted=True)
preset("performance", "pidstat-io", "performance-proc", "Disk I/O per process", ["pidstat", "-d", "-h", "1", "5"], untrusted=True)
preset("performance", "sar-cpu", "performance", "CPU now (sar)", ["sar", "-u", "1", "5"])
preset("performance", "sar-memory", "performance", "Memory now (sar)", ["sar", "-r", "1", "5"])
preset("performance", "sar-disk", "performance", "I/O now (sar)", ["sar", "-b", "1", "5"])
preset("performance", "sar-network", "performance", "Network now (sar)", ["sar", "-n", "DEV", "1", "5"])
preset("performance", "sar-tcp", "performance", "TCP now (sar)", ["sar", "-n", "TCP,ETCP", "1", "5"])
preset("performance", "history", "performance", "Today's CPU history (sar)", ["sar", "-u"], ok_codes=(0, 1))
preset("performance", "top", "performance", "Top processes", ["top", "-b", "-n", "2", "-d", "1", "-w", "512"], untrusted=True)
preset("performance", "pressure", "performance", "Pressure stall information", fn="pressure")
preset("performance", "cgroups", "performance", "Resource use per cgroup", ["systemd-cgtop", "-b", "-n", "1", "--depth=2"])
preset("performance", "numa", "performance", "NUMA statistics", ["numastat", "-c"])
preset("performance", "slabs", "performance-proc", "Kernel slab caches", ["slabtop", "-o", "-s", "c"])

# -- network ---------------------------------------------------------------------------
preset("network", "interfaces", "network", "Interfaces and counters", ["ip", "-j", "-s", "link", "show"])
preset("network", "neighbours", "network", "ARP and neighbour table", ["ip", "-j", "neigh", "show"])
preset("network", "counters", "network", "Protocol counters", ["nstat", "-a", "-s", "-z", "-j"])
preset("network", "socket-summary", "network", "Socket counts", ["ss", "-s"])
preset("network", "interface-info", "network", "Driver and features (interface=NAME)",
       [["ethtool", "-i", "{interface}"], ["ethtool", "-k", "{interface}"], ["ethtool", "-S", "{interface}"]],
       params={"interface": "interface"}, ok_codes=(0, 1, 71, 94))
preset("network", "dns-status", "network", "Resolver configuration", ["resolvectl", "--no-pager", "status"])
preset("network", "dns-stats", "network-root", "Resolver statistics", ["resolvectl", "--no-pager", "statistics"])
preset("network", "dns-lookup", "network", "Resolve an approved target (target=ID type=A|AAAA|MX|TXT|NS|PTR|SOA)",
       ["dig", "-r", "+short", "+timeout=2", "+tries=1", "{target}", "{type}"], params={"target": "target", "type": "dns_type"})
preset("network", "ping", "network-raw", "Ping an approved target (target=ID)",
       ["ping", "-n", "-c", "3", "-W", "2", "-w", "5", "{target}"], params={"target": "target"}, ok_codes=(0, 1))
preset("network", "tracepath", "network", "Path to an approved target (target=ID)",
       ["tracepath", "-n", "-m", "15", "{target}"], params={"target": "target"}, timeout=30, ok_codes=(0, 1))
preset("network", "traceroute", "network-raw", "Route to an approved target (target=ID)",
       ["traceroute", "-n", "-q", "1", "-N", "1", "-m", "15", "-w", "2", "{target}"], params={"target": "target"}, timeout=45)
preset("network", "mtr", "network-raw", "Loss and latency to an approved target (target=ID)",
       ["mtr", "-n", "-r", "-c", "5", "-m", "20", "--json", "{target}"], params={"target": "target"}, timeout=45)
preset("network", "tls-probe", "network", "Certificate of an approved target on port 443 (target=ID)", fn="tls_probe",
       params={"target": "target"}, timeout=20, untrusted=True)
preset("network", "tls-expiry", "network-proc", "Expiry of the local certificates", fn="tls_expiry", timeout=30)
preset("network", "sockets", "network-proc", "Listening ports with process names", ["ss", "-H", "-tulnp"], untrusted=True)
preset("network", "firewall", "network-admin", "nftables ruleset", ["nft", "-n", "-t", "-j", "list", "ruleset"])
preset("network", "iptables", "network-admin", "iptables rules", ["iptables-save"])
preset("network", "conntrack-stats", "network-admin", "Connection tracking counters", [["conntrack", "-S"], ["conntrack", "-C"]])
preset("network", "conntrack", "network-admin", "Tracked connections", ["conntrack", "-L", "-o", "extended"])
preset("network", "ipset", "network-admin", "IP sets", ["ipset", "list", "-terse"])
preset("network", "wireguard", "network-admin", "WireGuard peers, without keys",
       [["wg", "show", "all", "latest-handshakes"], ["wg", "show", "all", "transfer"],
        ["wg", "show", "all", "endpoints"], ["wg", "show", "all", "allowed-ips"]], post="wg_redact")
preset("network", "ufw", "network-root", "ufw status", ["ufw", "status", "verbose"])
preset("network", "lldp", "network", "LLDP neighbours", ["lldpcli", "-f", "json", "show", "neighbors", "summary"], untrusted=True)

# -- storage ---------------------------------------------------------------------------
preset("storage", "smart-scan", "storage-root", "Disks SMART can see", ["smartctl", "--scan", "-j"], physical=True, ttl=3600, ok_codes=(0, 1, 2))
preset("storage", "smart", "storage-root", "SMART data of one disk (device=NAME), never waking it up",
       ["smartctl", "-a", "-n", "standby", "-j", "{device}"], params={"device": "disk"}, physical=True, ttl=900,
       ok_codes=tuple(range(256)), post="smart_redact")
preset("storage", "nvme-list", "storage-root", "NVMe devices", ["nvme", "list", "-o", "json"], physical=True, ttl=3600, post="smart_redact")
preset("storage", "nvme-health", "storage-root", "NVMe health log (controller=NAME)",
       [["nvme", "smart-log", "{controller}", "-o", "json"], ["nvme", "error-log", "{controller}", "-o", "json"]],
       params={"controller": "nvme"}, physical=True, ttl=900)
preset("storage", "raid-state", "storage", "Software RAID state", fn="mdstat")
preset("storage", "raid", "storage-root", "Details of one array (array=NAME)", ["mdadm", "--detail", "--test", "{array}"],
       params={"array": "md"}, ok_codes=(0, 1, 2, 4))
preset("storage", "lvm", "storage-root", "LVM physical and logical volumes",
       [["pvs", "--readonly", "--reportformat", "json"], ["vgs", "--readonly", "--reportformat", "json"],
        ["lvs", "--readonly", "--reportformat", "json"]])
preset("storage", "zfs", "storage-root", "ZFS pool health", [["zpool", "status", "-x"], ["zpool", "status", "-p"]])
preset("storage", "btrfs", "storage-root", "btrfs error counters (mount=PATH)", ["btrfs", "device", "stats", "--check", "{mount}"],
       params={"mount": "btrfs_mount"}, ok_codes=(0, 64))
preset("storage", "xfs", "storage", "XFS geometry (mount=PATH)", ["xfs_info", "{mount}"], params={"mount": "xfs_mount"})
preset("storage", "directory-sizes", "storage", "Size of the main directories, cached one hour", fn="directory_sizes", timeout=120, ttl=3600)

# -- kernel ----------------------------------------------------------------------------
preset("kernel", "messages", "kernel", "Kernel warnings and errors of this boot",
       JOURNAL + ["-k", "-b", "0", "-p", "warning", "-n", "500"], post="journal", physical=True, untrusted=True)
preset("kernel", "dmesg", "kernel-syslog", "Kernel ring buffer, errors and warnings",
       ["dmesg", "--nopager", "--kernel", "--ctime", "--level=err,warn", "--since", "1 hour ago"], physical=True, untrusted=True)
preset("kernel", "modules", "kernel", "Loaded modules", ["lsmod"])
preset("kernel", "parameters", "kernel", "Kernel parameters", ["sysctl", "-a"], ok_codes=(0, 1, 255))
preset("kernel", "version", "kernel", "Kernel version", ["uname", "-a"])
preset("kernel", "tainted", "kernel", "Taint state", fn="tainted")
preset("kernel", "deleted-open", "kernel-proc", "Deleted files still held open", ["lsof", "-n", "-P", "-w", "-b", "-S", "5", "+L1"],
       ok_codes=(0, 1), timeout=30, untrusted=True)
preset("kernel", "listeners", "kernel-proc", "Listening sockets with their process",
       ["lsof", "-n", "-P", "-w", "-b", "-S", "5", "-i", "-sTCP:LISTEN"], ok_codes=(0, 1), timeout=30, untrusted=True)
preset("kernel", "bpf-programs", "kernel-root", "Loaded eBPF programs", ["bpftool", "prog", "list", "-j"], physical=True)

# -- hardware --------------------------------------------------------------------------
preset("hardware", "cpu", "hardware", "CPU", ["lscpu", "-J"])
preset("hardware", "pci", "hardware", "PCI devices", ["lspci", "-nnk"], physical=True)
preset("hardware", "usb", "hardware", "USB devices", ["lsusb"], physical=True)
preset("hardware", "sensors", "hardware", "Temperatures, fans, voltages", ["sensors", "-j"], physical=True)
preset("hardware", "memory-errors", "hardware", "ECC memory errors", ["edac-util", "-s"], physical=True, ok_codes=(0, 1))
preset("hardware", "dmi", "hardware-root", "BIOS, system and memory, serial numbers removed",
       ["dmidecode", "-q", "-t", "bios", "-t", "system", "-t", "memory"], physical=True, post="dmi_redact", ttl=86400)
preset("hardware", "bmc", "hardware-root", "BMC sensors and event log",
       [["ipmitool", "-I", "open", "sdr", "elist"], ["ipmitool", "-I", "open", "sel", "list"], ["ipmitool", "-I", "open", "chassis", "status"]],
       physical=True, ttl=300, timeout=60)
preset("hardware", "ras", "hardware-root", "RAS error summary (rasdaemon)", [["ras-mc-ctl", "--status"], ["ras-mc-ctl", "--summary"], ["ras-mc-ctl", "--error-count"]],
       physical=True, ok_codes=(0, 1))

# -- accounts --------------------------------------------------------------------------
preset("accounts", "users", "accounts", "Local users", ["getent", "passwd"], post="passwd_fields")
preset("accounts", "groups", "accounts", "Local groups", ["getent", "group"])
preset("accounts", "sessions", "accounts", "Login sessions", ["loginctl", "--no-pager", "--no-legend", "list-sessions"])
preset("accounts", "logins", "accounts-root", "Last 200 logins (/var/log/wtmp)", fn="wtmp_logins", untrusted=True)
preset("accounts", "failed-logins", "accounts-root", "Failed logins per source address, no user names", fn="failed_logins", timeout=30, ttl=60)
preset("accounts", "locked", "accounts-root", "Failed attempts recorded for one user (account=NAME)", ["faillock", "--user", "{account}"],
       params={"account": "local_user"})
preset("accounts", "sudo-policy", "accounts-root", "Who has sudo rights: summary, hashes and modes of the sudoers files", fn="sudo_policy")
preset("accounts", "ssh-config", "accounts-root", "Main settings of sshd", ["sshd", "-T"], post="sshd_allowlist")
preset("accounts", "ssh-keys", "accounts-root", "Authorized SSH keys per user: type and fingerprint only", fn="authorized_keys")

# -- persistence -----------------------------------------------------------------------
preset("persistence", "timers", "persistence", "systemd timers", ["systemctl", "list-timers", "--all", "--no-pager", "--output=json"])
preset("persistence", "unit-files", "persistence", "Unit files and their state", SYSTEMCTL + ["list-unit-files"])
preset("persistence", "unit-overrides", "persistence", "Overridden and extended units", ["systemd-delta", "--no-pager", "--type=overridden,extended"], ok_codes=(0, 1))
preset("persistence", "startup-files", "persistence-read", "cron directories, rc.local, ld.so.preload, udev rules: metadata and hashes", fn="startup_files", timeout=60)
preset("persistence", "crontabs", "persistence-read", "Users' crontabs: schedule and command path, values masked", fn="crontabs", untrusted=True)
preset("persistence", "at-queue", "persistence-root", "Queued at jobs", ["atq"], ok_codes=(0, 1))

# -- security --------------------------------------------------------------------------
preset("security", "apparmor", "security-root", "AppArmor status", ["aa-status", "--json"], ok_codes=(0, 1, 2, 3, 4))
preset("security", "audit-rules", "security-root", "Audit rules and state", [["auditctl", "-l"], ["auditctl", "-s"]], physical=True, ok_codes=(0, 1))
preset("security", "audit-summary", "security-root", "Audit summaries", [["aureport", "--input-logs", "--summary"], ["aureport", "--input-logs", "--auth", "--failed", "--start", "today"]],
       physical=True, ok_codes=(0, 1), timeout=60, ttl=300)
preset("security", "fail2ban", "security-root", "fail2ban jails", ["fail2ban-client", "status"], timeout=10)
preset("security", "fail2ban-jail", "security-root", "One fail2ban jail (jail=NAME)", ["fail2ban-client", "status", "{jail}"], params={"jail": "jail"}, timeout=10)
preset("security", "crowdsec", "security-root", "CrowdSec decisions and metrics",
       [["cscli", "decisions", "list", "-o", "json", "--limit", "100"], ["cscli", "metrics", "show", "-o", "json"]], timeout=20)
preset("security", "process-hardening", "security", "Per process: seccomp, no_new_privs, capabilities", fn="process_hardening", untrusted=True)
preset("security", "setuid-files", "security-read", "Setuid and setgid files, cached one day",
       ["find", "/", "-xdev", "-type", "f", "(", "-perm", "-4000", "-o", "-perm", "-2000", ")", "-printf", "%m %u %g %s %TF %p\n"],
       timeout=600, ttl=86400, ok_codes=(0, 1), untrusted=True)
preset("security", "world-writable", "security-read", "World-writable files, cached one day",
       ["find", "/", "-xdev", "-type", "f", "-perm", "-0002", "-printf", "%m %u %g %s %TF %p\n"],
       timeout=600, ttl=86400, ok_codes=(0, 1), untrusted=True)
preset("security", "file-capabilities", "security-read", "Files with capabilities, cached one day", ["getcap", "-r", "/usr", "/opt"],
       timeout=300, ttl=86400, ok_codes=(0, 1), untrusted=True)
preset("security", "suricata-alerts", "security-read", "Latest Suricata alerts: time, addresses, signature id, severity", fn="suricata_alerts", timeout=30)

# -- containers ------------------------------------------------------------------------
preset("containers", "docker-ps", "containers", "Docker containers",
       ["docker", "ps", "-a", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}"], untrusted=True)
preset("containers", "docker-stats", "containers", "Docker resource use",
       ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}"], timeout=30, untrusted=True)
preset("containers", "docker-images", "containers", "Docker images", ["docker", "images", "--format", "{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}"], untrusted=True)
preset("containers", "docker-disk", "containers", "Docker disk use, cached one hour", ["docker", "system", "df", "--format", "json"], timeout=60, ttl=3600)
preset("containers", "docker-state", "containers", "State of one container (container=NAME)",
       ["docker", "inspect", "--format", "{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}} {{.RestartCount}}", "{container}"],
       params={"container": "docker_name"})
preset("containers", "podman-ps", "containers", "Podman containers", ["podman", "ps", "-a", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}"], untrusted=True)
preset("containers", "lxc", "containers", "LXD/Incus instances", ["lxc", "list", "--format", "csv", "-c", "ns4t"], untrusted=True)
preset("containers", "libvirt", "containers", "libvirt VMs", ["virsh", "-r", "-c", "qemu:///system", "list", "--all"], untrusted=True)
preset("containers", "crictl", "containers", "CRI containers and pods", [["crictl", "ps", "-a"], ["crictl", "pods"]], untrusted=True)
preset("containers", "proxmox", "containers", "Proxmox guests", [["pct", "list"], ["qm", "list"]], timeout=30, untrusted=True)

# -- services --------------------------------------------------------------------------
preset("services", "nginx", "services", "nginx counters (stub_status at /basic_status)",
       ["curl", "-q", "-fsS", "--max-time", "3", "http://127.0.0.1/basic_status"])
preset("services", "apache", "services", "Apache counters (mod_status)", ["curl", "-q", "-fsS", "--max-time", "3", "http://127.0.0.1/server-status?auto"],
       post="apache_counters")
preset("services", "postgres", "services", "PostgreSQL readiness", ["pg_isready", "-h", "/var/run/postgresql", "-p", "5432", "-t", "3"], ok_codes=(0, 1, 2, 3))
preset("services", "mail-queue", "services-root", "Mail queue counts, addresses removed", ["postqueue", "-j"], post="mail_counts", ok_codes=(0, 1, 69, 75))

# -- security_scans: latest result of what the timer ran, never run by the agent --------
preset("security_scans", "status", "security-scans", "Scanners enabled and when they last ran", fn="scan_status")
for _name in SCANNERS:
    preset("security_scans", _name, "security-scans", f"Latest {_name} result", fn="scan_result", untrusted=True)

# -- profiling -------------------------------------------------------------------------
preset("profiling", "cpu-counters", "profiling", "CPU counters, 5 seconds",
       ["perf", "stat", "-a", "-e", "cycles,instructions,cache-misses,cache-references", "--", "sleep", "5"], timeout=15, physical=True)
preset("profiling", "disk-latency", "profiling", "Disk latency histogram", ["biolatency-bpfcc", "1", "5"], timeout=30, physical=True)
preset("profiling", "scheduler-latency", "profiling", "Run queue latency histogram", ["runqlat-bpfcc", "1", "5"], timeout=30, physical=True)

# -- packet_capture --------------------------------------------------------------------
_TCPDUMP = ["tcpdump", "-i", "{interface}", "-p", "-n", "-q", "-l", "-s", "128", "-c", "500", "--"]
preset("packet_capture", "connections", "packet-capture", "New and closing connections, ICMP and ARP, at most 30 s or 500 packets (interface=NAME)",
       _TCPDUMP + ["tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0 or icmp or arp"],
       params={"interface": "interface"}, timeout=30, ok_codes=(0, 124, -15, -9), untrusted=True)
preset("packet_capture", "port", "packet-capture", "Traffic of one listening port, at most 30 s or 500 packets (interface=NAME port=N)",
       _TCPDUMP + ["tcp port {port} or udp port {port}"],
       params={"interface": "interface", "port": "listening_port"}, timeout=30, ok_codes=(0, 124, -15, -9), untrusted=True)


def group(category):
    return "ai-diag-" + category.replace("_", "-")


def physical_machine():
    """True on bare metal: neither a VM nor a container."""
    import subprocess
    out = subprocess.run(["systemd-detect-virt"], capture_output=True, text=True).stdout.strip()
    return out == "none"


def in_container():
    import subprocess
    return subprocess.run(["systemd-detect-virt", "--container", "--quiet"]).returncode == 0


def detected(category):
    if category == "hardware":
        return physical_machine()
    return any(shutil.which(tool, path="/usr/sbin:/usr/bin:/sbin:/bin") for tool in DETECT.get(category, ()))


def packages(category, scanners=()):
    wanted = []
    container = in_container()
    for package, condition, _ in PACKAGES.get(category, ()):
        if condition == "physical" and container:
            continue
        if condition == "nvme" and (container or not os.path.isdir("/sys/class/nvme")):
            continue
        if condition == "bmc" and (container or not os.path.exists("/dev/ipmi0")):
            continue
        if condition == "scanner" and package not in scanners:
            continue
        wanted.append(package)
    return wanted


def render_units(directory, sandbox):
    """Write one .socket and one @.service per profile. sandbox: "full" or "degraded"."""
    os.makedirs(directory, exist_ok=True)
    for name, p in PROFILES.items():
        with open(f"{directory}/ai-diag-{name}.socket", "w", encoding="utf-8") as f:
            f.write(f"""[Unit]
Description=add-ai-user diagnostics socket: {name}

[Socket]
ListenStream={SOCK_DIR}/{name}.sock
SocketUser=root
SocketGroup={group(p['category'])}
SocketMode=0660
DirectoryMode=0755
Accept=yes
MaxConnections={p['connections']}
# Above this the socket would fail for good, so an agent in a loop must not reach it.
TriggerLimitIntervalSec=2s
TriggerLimitBurst=2000

[Install]
WantedBy=sockets.target
""")
        lines = [
            "[Unit]", f"Description=add-ai-user diagnostics: {name}", "CollectMode=inactive-or-failed", "",
            "[Service]", "Type=exec", f"ExecStart={LIB}/diag-helper {name}",
            "StandardInput=socket", "StandardOutput=socket", "StandardError=journal",
            f"RuntimeMaxSec={p['runtime'] + 30}" if p["runtime"] < 900 else "RuntimeMaxSec=930", "TimeoutStopSec=2",
            "NoNewPrivileges=yes", "RestrictSUIDSGID=yes", "LockPersonality=yes", "SystemCallArchitectures=native",
            "SystemCallFilter=@system-service", "SystemCallFilter=~@mount @swap @reboot @clock @cpu-emulation @obsolete",
            f"RestrictAddressFamilies={p['families']}",
            "MemoryMax=512M", "CPUQuota=50%", "TasksMax=64", "Nice=15", "IOSchedulingClass=idle",
            f"StateDirectory=ai-diag/{name}", f"CacheDirectory=ai-diag/{name}", "UMask=0077",
        ]
        if p["filter_debug"]:
            lines.append("SystemCallFilter=~@debug")
        if p["user"] != "root":
            lines += [f"User={p['user']}", f"Group={p['user']}",
                      f"CapabilityBoundingSet={p['caps']}", f"AmbientCapabilities={p['caps']}"]
        else:
            lines.append("CapabilityBoundingSet=~CAP_SYS_MODULE CAP_SYS_BOOT CAP_SYS_TIME CAP_MKNOD CAP_SETUID CAP_SETGID CAP_SETFCAP CAP_SETPCAP")
        if p["groups"]:
            lines.append(f"SupplementaryGroups={p['groups']}")
        if sandbox == "full":
            lines += ["Environment=AI_DIAG_SANDBOX=1", "ProtectSystem=strict", "ProtectHome=read-only",
                      "ProtectKernelTunables=yes", "ProtectKernelModules=yes", "ProtectControlGroups=yes", "ProtectClock=yes",
                      "ProtectHostname=yes", "RestrictNamespaces=yes", "RestrictRealtime=yes"]
            if p["private_tmp"]:
                lines.append("PrivateTmp=yes")
            if not p["devices"]:
                lines.append("PrivateDevices=yes")
            if not p["kernel_logs"]:
                lines.append("ProtectKernelLogs=yes")
        with open(f"{directory}/ai-diag-{name}@.service", "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")


def main(argv):
    command = argv[0] if argv else ""
    if command == "categories":
        print("\n".join(CATEGORIES))
    elif command == "describe":
        _, description, tools = CATEGORIES[argv[1]]
        print(description)
        print("Tools: " + tools)
        wanted = packages(argv[1], SCANNERS if argv[1] == "security_scans" else ())
        print("Installs if missing: " + (", ".join(wanted) if wanted else "nothing"))
    elif command == "default":
        print(CATEGORIES[argv[1]][0])
    elif command == "detected":
        return 0 if detected(argv[1]) else 1
    elif command == "packages":
        print(" ".join(packages(argv[1], argv[2:])))
    elif command == "units-off":
        print(" ".join(unit for items in PACKAGES.values() for package, _, units in items
                       if package in argv[1:] for unit in units))
    elif command == "group":
        print(group(argv[1]))
    elif command == "groups":
        print("\n".join(group(c) for c in CATEGORIES))
    elif command == "agents-block":
        print("Your rights, through `ai-diag <category> <diagnostic>` (`ai-diag list` shows them all):")
        for category in argv[1:]:
            names = [p["name"] for p in PRESETS.values() if p["category"] == category]
            print(f"- {category}: {', '.join(names)}")
    elif command == "units":
        render_units(argv[1], argv[2])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
