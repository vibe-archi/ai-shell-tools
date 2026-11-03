# How add-ai-user works

This setup was first built by hand for one account (`ai`) on an Ubuntu 26.04 container, then
turned into `add-ai-user.sh` so that any account can get the same setup. This page explains
each piece and the choices behind it.

## The goal

AI agents connect to the server over SSH. We want to be able to look, at any time, at what
they are doing, and to read back what they did. The answer: everything they do happens
in tmux panes, on the account's default tmux server, which we can attach to; and every
pane is recorded.

It is a usage rule, not a security boundary: whoever can type into a pane can do
anything the account can do, including deleting its own logs.

## 1. The SSH gate

### Where it plugs in

`/etc/ssh/sshd_config.d/60-add-ai-user.conf`:

```
Match Group add-ai-user
    ForceCommand /usr/local/lib/add-ai-user/ssh-gate
Match Group add-ai-key-only
    PasswordAuthentication no
    KbdInteractiveAuthentication no
Match Group add-ai-password-login
    PasswordAuthentication yes
Match all
```

With `ForceCommand`, sshd runs the gate instead of whatever the client asked for, and puts
the client's command in `SSH_ORIGINAL_COMMAND` (empty for an interactive login).

Why not a fake login shell (`chsh -s gate`)? tmux starts its panes with the login shell,
so the panes themselves would be refused; `su`, `sudo -iu`, cron... would break too.
`ForceCommand` only applies to SSH, and the account can't change it.

### Password login

Each account gets a password: it unlocks sudo on a standard account, and logs in over SSH
when there is no key. Whether SSH accepts it is chosen per account, with two groups. Once
sshd knows the user name, it reads the `Match` blocks that apply and their values replace
the global ones, so `add-ai-key-only` turns password login off even where `sshd_config`
allows it, and `add-ai-password-login` turns it on where a cloud image turned it off for
everyone (`PasswordAuthentication no` in `sshd_config.d`). An account without a key is
always in `add-ai-password-login`, since its password is the only way in; with a key, the
script asks. `--remove` takes the account out of both groups: `sshd_config` decides again.

The password is read without echo, typed twice, and handed to `chpasswd` on its standard
input, so it never appears in a command line.

### What the gate does

`/usr/local/lib/add-ai-user/ssh-gate` (Python 3, no dependencies):

1. Empty command: refused ("direct connection without tmux").
2. The sftp subsystem (`.../sftp-server`, `internal-sftp`): allowed, so scp (which uses
   sftp since OpenSSH 9) and sftp keep working.
3. Anything else is split into words **like a POSIX shell would, without running it**
   (quotes, backslashes, `~`, comments). What a shell would turn into a second command, a
   pipe, a redirection or a substitution (`;`, `&`, `|`, `<`, `>`, `(`, `` ` ``, `$`,
   newline) is refused: the gate runs one tmux command line, nothing else.
4. The first word must be `tmux`. Global options are limited to `-2 -u -N -l -V`: no
   `-L`/`-S` (a private server you would not see in `tmux ls`), no `-f`, `-c` (runs a
   shell command), `-C` (control mode can send any command).
5. The arguments are split into tmux commands at `;` (an argument ending with an
   unescaped `;`, as tmux does), and each command name is resolved like tmux does (exact
   alias, exact name, else unique prefix: `run` and `ru` are `run-shell`).
6. Each command must be in the allow list: sessions, windows and panes management,
   `send-keys`, `capture-pane`, `display-message`, `wait-for`, buffers, `show-*`,
   `list-*`. Refused, among others: `run-shell`, `if-shell`, `pipe-pane`, `source-file`,
   `set-option`, `set-hook`, `bind-key`, `command-prompt`, `display-menu`,
   `display-popup`, `respawn-*`, `clear-history`, `kill-server`.
7. `new-session`, `new-window`, `split-window` must not get a command to run (their panes
   are always shells, the agent types into them) nor `-e` (environment).
   `send-keys -K` (goes through key bindings), `-X` (copy-mode commands, `copy-pipe` runs a
   command) and `-R` are refused. Any argument containing `#(` is refused: tmux formats
   run `#(command)` in the background.
8. Attaching (`attach`, or `new` without `-d`) needs a terminal: without `ssh -t`, the
   gate says so instead of letting tmux fail.
9. Allowed: the gate `exec`s `tmux -u <the same arguments>`, with `LANG=C.UTF-8` when the
   client sent no UTF-8 locale (ssh from Windows sends none).

Refusals and allowed commands are logged to syslog (`journalctl -t add-ai-user-gate`).

A refused connection is usually an agent's first contact with the account, so the refusal points
to the instructions: `ssh user@host cat AGENTS.md`. The gate answers `cat <any path>/AGENTS.md`
itself, with no tmux session: an unquoted `~/AGENTS.md` is expanded by the client's shell, and
what is printed is always the file of this account (up to 256 KB). On a restricted account it reads
`/etc/add-ai-user/agents/<user>.md`, which a broken link in the home can't hide.

`tests/test-gate.sh` runs the gate on about 55 commands, and checks that a refusal points to the
instructions and that they can be read.

## 2. Recording every pane

```
tmux hook (after-new-session / after-new-window / after-split-window, config load)
  -> /usr/local/lib/add-ai-user/tmux/log-panes
       for each pane not recorded yet: tmux pipe-pane -o "pane-logger <base>"
  -> /usr/local/lib/add-ai-user/tmux/pane-logger <base>
       stdin (everything the pane displays) -> <base>.001.log, .002.log, ...
```

- Files: `~/tmux-logs/<session>/<YYYY-MM-DD_HHMMSS>_w<window>p<pane>_<pane id>.NNN.log`.
- `pane-logger` writes `LOG_CHUNK_MB` (50) per file with `head -c`, then opens the next
  one: rotation without copy/truncate, so nothing is lost, and the current file can be
  followed with `tail -f`.
- Below `LOG_MIN_FREE_MB` (2 GB) free on the disk, it keeps reading the pane (tmux must
  not block) but writes nothing, and notes it in `<base>.SUSPENDED`.
- The gate refuses `pipe-pane`, `set-hook` and `source-file` over SSH, so an agent can't
  turn the recording off from outside. From inside a pane it can: visibility, not
  security.

Full-screen programs (Claude Code, Codex, htop) redraw the screen all the time: their
logs grow fast, but compress 20 to 50 times. `tmux-logs replay` prints a log raw so that
the terminal redraws them as they were.

## 3. The janitor

`add-ai-user-janitor@<user>.timer` runs `/usr/local/lib/add-ai-user/tmux-logs-janitor` as `<user>`
every 2 minutes:

1. Compresses (gzip) every `.log` that no process has open (it reads the symlinks of
   `/proc/*/fd`) and that has not changed for a minute; deletes empty ones.
2. Deletes `.gz` files older than `LOG_KEEP_DAYS` (30).
3. If `~/tmux-logs` is over `LOG_MAX_TOTAL_MB` (2 GB), deletes the oldest `.gz` files until
   it is under.

It runs as the user, not as root, so it never follows a link planted in a user directory
with root's rights. logrotate was not used: it handles files one by one and can't cap a
directory where every pane creates new files.

Every 2 minutes rather than every hour: a pane printing a huge file must not fill the disk
between two runs (the free space guard of `pane-logger` is the second safety net).

## 4. tmux: Oh my tmux! with byobu's keys

The first idea was to keep byobu and give it Oh my tmux!'s look. They conflict: both
generate the status line, colours and prefixes, and byobu loads its own tmux
configuration, so each reload would undo the other. So: Oh my tmux! as the base, and
byobu's best parts ported into `tmux.conf.local`:

- byobu's F-keys (F2-F9, Shift/Ctrl/Alt variants, Alt+arrows, Shift+arrows), F12 as
  second prefix; Oh my tmux!'s `Ctrl+a` second prefix is removed so that `Ctrl+a` goes
  back to "start of line" in the shell.
- F1: a cheat sheet in a popup (`lib/tmux/help`); F9: a menu replacing byobu-config.
- Shift+F12 switches to an empty key table (`fkeys-off`) so that htop or mc get the
  F-keys; the status bar shows `F-keys OFF`.
- Status bar: byobu-like system info (load, memory, disk) through Oh my tmux! custom
  variables (`mem()` and `disk()` at the end of `tmux.conf.local`).
- Mouse on, 100 000 lines of history, vi copy mode, new windows in the current directory.
- UTF-8: ssh from Windows sends no locale, so tmux would replace its symbols with `_`.
  The gate and `~/.bashrc` set `LANG=C.UTF-8` when needed, and `tmux.conf.local` sets it
  in tmux's global environment for popups and editors.
- A credit, "set up with add-ai-user, by https://vibe.archi/", in the status line for 5
  seconds when a client connects. The `client-session-changed` hook also covers `tmux new
  -A` creating the session, which `client-attached` misses; it shows the message only while
  `client_activity` still equals `client_created`, so not again when a key switches
  sessions. An agent's `tmux new -d` has no client: its output stays clean.

Oh my tmux! is cloned once in `/usr/local/lib/add-ai-user/oh-my-tmux` and linked from every
account's `~/.config/tmux/tmux.conf`; running `add-ai-user.sh` again updates it.

## 5. Working as an agent through the gate

Only tmux commands go through, so an agent (or a human script) works like this:

```bash
H=bob@server.example.com
ssh $H tmux new -d -s fix-login
ssh $H "tmux send-keys -t fix-login -l -- 'make test; tmux wait-for -S done-1' \; send-keys -t fix-login Enter"
ssh $H tmux wait-for done-1                         # blocks until the command has finished
ssh $H tmux capture-pane -p -J -t fix-login -S -200   # its output
```

Files are copied with scp, then used from a pane. Everything the agent types is visible
in the pane, recorded in `~/tmux-logs`, and each SSH command is in the gate's syslog.

## 6. Restricted accounts

The gate gives visibility; a restricted account also takes the rights away. The agent is not a
service but a user who logs in or starts a CLI, so the limits apply to its session.

### Taking the rights away

```
sshd -> login-shell -> setpriv --no-new-privs -> bash -c ssh-gate -> tmux server -> panes
```

- sshd runs `ForceCommand` through the login shell, so the wrapper covers the gate, the tmux server
  and every pane, and also `su` and CLIs started on the server. `no_new_privs` can't be removed and
  is inherited: `sudo` refuses to start, setuid programs and file capabilities give nothing.
- A drop-in sets `NoNewPrivileges=yes` on `user@<uid>.service`, whose services are not children of the
  login shell. Another sets memory, task and CPU limits on `user-<uid>.slice`.
- polkit answers no to any request from the group `add-ai-restricted`. Without this rule, an
  unprivileged user can run `loginctl enable-linger` on itself (tested).
- A process keeps the groups it started with, so a change of categories closes the sessions of the
  account: a right taken away would otherwise stay in the running tmux server.
- No private `/tmp`: a `pam_namespace` tmpfs per session would hide the tmux socket from the next
  SSH call. No disk quota either, since containers rarely offer one. `ulimit -f` only caps single files.

### Reading through collectors

Capabilities don't make a tool read-only: `nft` with `CAP_NET_ADMIN` can also flush the ruleset. What
keeps a collector read-only is that it runs one fixed argument list:

```
ai-diag network firewall -> /run/ai-diag/network-admin.sock (root:ai-diag-network 0660)
  -> ai-diag-network-admin@.service (Accept=yes, one instance per connection)
  -> diag-helper network-admin -> execve(nft -n -t -j list ruleset)
```

- `lib/restricted/catalog.py` is the only definition: categories, profiles, diagnostics. The questions
  of the install, the units, the helper, `ai-diag` and the rights listed in `AGENTS.md` all come from it.
- One socket and one service per privilege level (`network`, `network-proc`, `network-admin`...): a
  single helper would hold the union of all capabilities. A diagnostic can only be asked on the socket
  of its profile. Each socket is reserved to the group of its category.
- Non-root with the capability it needs wherever the probe showed this is enough; root only for
  what requires it (`ufw`, `sshd -T`, `smartctl`...), with its capability set reduced.
- The file system is read-only for the collector (`ProtectSystem=strict`) except its own state and
  cache directories. The helper checks at each request that writing under `/usr` fails, and refuses
  to answer otherwise. An install probe decides whether the sandbox is available; only a container may
  go without it, and the script says so.
- Parameters are checked against lists built when asked: units from `systemctl`, interfaces from
  `/sys/class/net`, disks from `/sys/block`, targets from the admin's list and the system's gateway and
  resolvers, with link-local and multicast addresses refused after resolution. Nothing typed by the agent
  reaches a command line unless it equals a listed value.
- The command runs without a shell, with a clean environment (`PAGER=cat`, `SYSTEMD_PAGERSECURE=1`,
  `LANG=C`...) and in its own process group, killed at the time limit. Output is capped, and ANSI, C0/C1 and
  bidirectional characters are removed.
- Filters remove what a raw tool would give away: user names in sshd and PAM log lines, since a password
  typed as a login ends up there; serial numbers; GECOS fields; WireGuard keys. Failed logins are
  reduced to counts per address, split between existing and unknown accounts.
- Every answer is a frame with a status and a scope. A tool or data that isn't there gives
  `unavailable`, not an empty success, so that an agent doesn't report a gap as a healthy result.
- Each request goes to the journal: UID, profile, diagnostic, validated parameters, status, size and
  duration. A refused request only logs the fact, so that it can't be used to inject text in the logs. The
  account has no journal access, so it can't read or change that trace.

### Outbound connections

`meta skuid` in an nftables `output` chain rejects new connections of the UIDs whose agent is remote, and
accepts established ones so that sshd can still answer. Collectors run under other UIDs, so their network
tests pass. `IPAddressDeny=` was not used since it has no effect in a container. This filter was tested
in the same Proxmox LXC: the account gets `connection refused` to the outside and a collector still connects.

### Scanners

A scanner can take hours, and an agent must not be able to start it in a loop or update its baseline. So a
weekly timer runs `run-scans` with fixed commands, and the collector only returns the latest output with its
date. Their packaged timers are disabled at install, and their cron scripts stay off: `debsums` and `rkhunter`
default to it on Ubuntu 26.04, and the one of `chkrootkit` exits under systemd.

## Tested on

Ubuntu 26.04 (tmux 3.6, OpenSSH 10.2, Python 3.14, systemd 259), in a Proxmox LXC container, with
connections from Windows (OpenSSH for Windows). The diagnostics that only exist on bare metal or in a VM
(SMART, BMC, perf, BPF...) have not run on real hardware yet: in this container they answer `unavailable`.
Codex was checked to read `~/AGENTS.md` by itself. Claude Code was not, since it wasn't logged in on the test
machine: its loading of the file relies on the `@~/AGENTS.md` import documented for `CLAUDE.md`.
