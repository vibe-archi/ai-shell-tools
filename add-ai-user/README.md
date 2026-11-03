# add-ai-user

Create Linux accounts for AI agents whose every SSH session has to go through tmux, so
that you can **watch what they do, live, and read it back later**.

AI coding agents (Claude Code, Codex, ...) that work on a server over SSH run commands
nobody sees. On an account created by `add-ai-user.sh`, a plain `ssh` is refused: the
agent has to open a tmux session and type its commands into it. You attach to the same
tmux server and watch, and every pane is recorded in `~/tmux-logs` anyway.

> This is a **visibility** tool, not a sandbox. tmux can run anything once you are in a
> pane, and the agent owns its logs. It keeps honest agents in plain sight; it does not
> stop a hostile one.

## What you get

- **An SSH gate** (`ForceCommand` for the members of the `add-ai-user` group): only `tmux`
  commands on the account's default tmux server go through, plus scp / sftp. Shells,
  other commands, private tmux servers (`-L`, `-S`) and every tmux command that runs
  something outside a visible pane (`run-shell`, `if-shell`, a command given to
  `new-window`, `#(...)` formats, ...) are refused with an explanation.
- **Instructions for agents** per account, in `~/AGENTS.md`: how to connect, a short and
  descriptive session name, and the command to give their user to watch it. A refused
  connection points to it, and you can add your own instructions
  ([Instructions for agents](#instructions-for-agents)).
- **An optional restricted account type**, for an agent that watches a system without being
  able to change it: read-only diagnostics you choose category by category
  ([Restricted accounts](#restricted-accounts)).
- **Recording of every tmux pane** in `~/tmux-logs/<session>/`, in 50 MB files, compressed
  once closed, deleted after 30 days, capped at 2 GB per account. Recording pauses when
  the disk has less than 2 GB free.
- **A comfortable tmux**: [Oh my tmux!](https://github.com/gpakosz/.tmux) with
  [byobu](https://www.byobu.org/)'s F-keys, mouse support, an F1 cheat sheet and an F9 menu.
- **`tmux-logs`** to list, read, replay and search the recordings.

## Requirements

- Debian or Ubuntu with systemd, OpenSSH 8.2+ (`/etc/ssh/sshd_config.d/`).
- tmux 3.4+ recommended (Ubuntu 24.04+, Debian 13+). Older versions work, without some of
  the F9 menu entries.
- Missing packages are installed with apt: `tmux git python3 gzip less nano`
  (and `openssh-server`).

## Getting started

```bash
git clone https://github.com/vibe-archi/ai-shell-tools.git && cd ai-shell-tools/add-ai-user
sudo ./add-ai-user.sh bob
```

Then follow the questions. Nothing is changed before the last answer:

```
Account type [s = standard, r = restricted] s
==> Password of bob: it unlocks sudo, and logs in over SSH without a key
Password:
Password again:
==> SSH public key of bob: paste it, or leave it empty to log in with the password
SSH public key: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... agent@laptop
  key:         ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...k9xYbV2cTn8uE5fHs7dLp agent@laptop
  fingerprint: 256 SHA256:Wq3mJr0k9xYbV2cTn8uE5fHs7dLpA1gZ4iKoR6tMvNe agent@laptop (ED25519)
Is this the right key? [y = yes, n = enter it again] y
Disable SSH password login for bob (SSH key only)? [Y/n] y
```

- **Account type**: standard, or restricted for an agent that only watches the system; a
  restricted account is then asked what it can read ([Restricted accounts](#restricted-accounts)).
- **Password**: at least 8 characters, typed twice. A new standard account is a sudoer and sudo
  asks for this password: when the agent needs it, attach to its session without `-r` and type
  it in the pane.
- **SSH key**: optional. Without one, the account logs in with its password.
- **Password login**: asked once a key is given. Turned off, SSH only accepts the key; the
  password still unlocks sudo. The choice applies to this account whatever `sshd_config` says
  (a cloud image often turns password login off for everyone).

The first run installs the system part, then the script creates `bob`, writes `~bob/AGENTS.md`,
starts bob's log janitor and prints the commands to connect and to watch.

## Options instead of questions

Every answer can be given on the command line, to script the setup or to change an account
later. With a terminal, the script only asks what the options leave open.

```bash
# a key, no password login: only the password is still asked
sudo ./add-ai-user.sh --standard --key ~/agent_key.pub --no-password-login bob

# nothing asked: the password is the first line of bob.pass (delete the file afterwards),
# the host name shown to agents is given, and rules.txt is added to the instructions for agents
sudo ./add-ai-user.sh --standard --password-file bob.pass --key ~/agent_key.pub --no-password-login \
  --host server.example.com --message rules.txt bob

# no key: bob logs in with its password; not a sudoer
sudo ./add-ai-user.sh --standard --no-key --no-sudo bob

# a restricted account for an agent that connects over SSH, default categories
sudo ./add-ai-user.sh --restricted --allow defaults --agent-location remote --key ~/agent_key.pub watcher

# later, on the existing account: a new password, another key, password login back on
sudo ./add-ai-user.sh --update --password bob
sudo ./add-ai-user.sh --update --key ~/laptop_key.pub bob
sudo ./add-ai-user.sh --update --password-login bob
```

```
Usage: sudo ./add-ai-user.sh [options] <user>
       sudo ./add-ai-user.sh --update [options] <user>
       sudo ./add-ai-user.sh --system-only [--host <name>]
       sudo ./add-ai-user.sh --remove <user>
       sudo ./add-ai-user.sh --uninstall

Login:
  -k, --key <file|key>  authorize SSH public key(s), repeatable
      --no-key          don't ask for a key (password login, or keys added later)
  -p, --password        set a new password on an existing account (asked)
      --password-file <file>
                        the password, first line of <file> ("-": standard input)
      --no-password-login
                        SSH login with a key only (the password still unlocks sudo)
      --password-login  SSH login with the password too (always the case without a key)
      --no-sudo         a standard account without sudo (a new standard account is a sudoer)
  -s, --sudo            add an existing standard account to the sudo group

Other options:
  -m, --message <file>  your own instructions in ~<user>/AGENTS.md, below the managed block
                        ("default" removes them)
  -u, --update          <user> already exists: (re)apply the add-ai-user setup to it
      --host <name>     host name shown to agents
      --system-only     install or update the system part only
      --remove <user>   take <user> out of add-ai-user (the account and its files are kept)
      --uninstall       remove add-ai-user from the system (users and their files are kept)

Account type:
      --standard        standard account; turns a restricted account back into a standard one
      --restricted      read-only account, see below
      --allow <list>    categories without asking: defaults, all, none or a comma-separated list
      --agent-location  remote (over SSH, no new outbound connection) or local (a CLI on the server)
  -y, --yes             confirm making an existing account restricted
```

An existing account keeps its password, sudo and password login unless an option changes them;
it is only asked for a password it lacks and needs (for sudo, or without a key).

Running `add-ai-user.sh` again is safe: it updates the system part (and Oh my tmux!) in place.
`--update` replaces the user's `~/.config/tmux/tmux.conf.local` and keeps the previous
one as `tmux.conf.local.bak-<date>`.

## Connecting

A human attaches to (or creates) a session:

```bash
ssh -t bob@server.example.com tmux new -A -s main
```

An agent drives a session with tmux commands only:

```bash
ssh bob@server.example.com tmux new -d -s fix-login                          # once
ssh bob@server.example.com "tmux send-keys -t fix-login 'make test' Enter"   # type a command
ssh bob@server.example.com tmux capture-pane -p -t fix-login -S -100         # read the screen
```

The command line is read twice, by your shell and on the server: keep the double quotes
around the whole tmux command. With `ssh ... tmux send-keys -t fix-login 'make test' Enter`,
your shell removes the single quotes, and tmux receives `make` and `test` as two separate
keys and types `maketest`.

To know when a command is over, make it signal a tmux channel and wait for it:

```bash
ssh bob@server.example.com "tmux send-keys -t fix-login 'make test; tmux wait-for -S done' Enter"
ssh bob@server.example.com tmux wait-for done      # returns when make test has finished
```

Anything else is refused:

```
$ ssh bob@server.example.com

  Connection refused: direct connection without tmux.

  On this account everything goes through tmux (default server), so that the
  work stays visible and is logged in ~/tmux-logs. Scp and sftp are allowed.

  AI: read the instructions of this account before anything else:
      ssh bob@server.example.com cat AGENTS.md
  Human: ssh -t bob@server.example.com tmux new -A -s <name>
```

## Instructions for agents

`~/AGENTS.md` holds everything an agent has to know on the account: how to connect, how to
name its tmux session, and that it must give its user the command to watch that session.
Agents are told to read it in several ways:

- `ssh <user>@<host> cat AGENTS.md` is answered by the gate, without a tmux session, and every
  refused connection points to this command;
- `tmux new` over SSH says it on stderr, and a new tmux shell prints where the file is;
- a Claude Code or Codex CLI started on the account reads it by itself, through
  `~/.claude/CLAUDE.md` (`@~/AGENTS.md`) and the `~/.codex/AGENTS.md` link.

The file has two parts:

- A managed block between `<!-- add-ai-user:begin ... -->` and `<!-- add-ai-user:end -->`, rewritten
  by `--update` from `/etc/add-ai-user/AGENTS.md`. Edit that template to change the default text;
  `{user}` and `{host}` are replaced.
- Your own instructions, anywhere outside the block: `--update` keeps them. Edit the file, or use
  `--message <file>` to replace them and `--message default` to remove them.

The file belongs to a standard account, so its agents could change it too (you would see it in
the recordings). On a restricted account the real file is `/etc/add-ai-user/agents/<user>.md`,
owned by root; `~/AGENTS.md` links to it and the gate reads it directly.

An account set up by an older version keeps its text: the first `--update` moves a customized
`~/.ai/con-refused.txt` into `AGENTS.md` and renames the old file `con-refused.txt.migrated`.

## Restricted accounts

For an agent that runs continuously to watch logs, security, performance and so on, without being
able to install, change or reconfigure anything. The agent still works over SSH or from a Claude
or Codex CLI on the server: it is an account with fewer rights, not a service.

```bash
sudo ./add-ai-user.sh --restricted --key ~/agent_key.pub watcher
sudo ./add-ai-user.sh --restricted --allow defaults --agent-location remote --key ~/agent_key.pub watcher
```

Without `--allow`, the script asks about each category, says what it covers and lists its tools.
Then it asks where the agent runs. An existing account can be converted with `--update
--restricted`: the script lists what will change (privileged groups, closed sessions, sudo rules and
files outside the home it can't deal with) and asks for confirmation.

The agent reads through `ai-diag`, typed in its tmux pane or run by its CLI:

```
$ ai-diag list network
$ ai-diag network firewall
# status=ok scope=host-global generated_at=2026-11-03T00:00:01Z
{"nftables": [...
$ ai-diag logs unit unit=ssh.service since=1h
```

| Category | Default | What it reads |
| --- | --- | --- |
| `base` | always | processes without arguments, services, packages, disk usage, addresses, time |
| `logs` | yes | recent log entries with user names and secret-looking values removed; this text goes to the model provider in a hosted session |
| `performance` | yes | `vmstat`, `iostat`, `sar`, `top -b`, PSI; turns on the sysstat history |
| `network` | yes | sockets, firewall rules, counters, DNS, certificates, probes to approved targets |
| `storage` | yes | SMART and NVMe health, RAID, LVM, ZFS, btrfs, directory sizes |
| `kernel` | yes | kernel messages, modules, parameters, taint, deleted files held open |
| `accounts` | yes | users, groups, logins, failed logins per address, sudo and SSH policy as derived facts |
| `persistence` | yes | timers, unit overrides, cron and startup files as metadata and hashes |
| `security` | yes | AppArmor, audit, fail2ban, CrowdSec, process hardening, setuid and world-writable files |
| `hardware` | if bare metal | CPU, PCI, USB, sensors, memory errors, BMC, without serial numbers |
| `containers` | if detected | containers and VMs with state and resource use; no exec, environment or raw inspect |
| `services` | if detected | nginx and Apache counters, PostgreSQL readiness, mail queue counts |
| `security_scans` | no | latest result of lynis, debsums, rkhunter, chkrootkit, debsecan, run weekly by a timer |
| `profiling` | no | aggregate CPU counters and latency histograms |
| `packet_capture` | no | addresses, ports and lengths for at most 30 s, never payloads |

**What the account can't do.** It has no sudo and leaves the privileged groups (`sudo`, `docker`,
`lxd`, `disk`, `adm`, `systemd-journal`...). Its login shell sets `no_new_privs`, so setuid programs
and file capabilities give nothing. polkit refuses it everything, cron and `at` refuse it, SSH
forwards nothing for it, and its processes have memory, task and CPU limits
(`RESTRICTED_*` in the configuration).

**Where the privileged readings come from.** Each diagnostic is a fixed command run by a sandboxed
collector on a Unix socket reserved to the group of its category. A parameter only chooses among
values the collector lists itself (units, interfaces, approved targets...), so a request can't
supply a path or an option. Output is capped at 256 KiB and stripped of terminal escapes, requests
are rate limited per user and written to the journal (`journalctl -g '^ai-diag '`).

**Outbound connections.** `--agent-location remote` (the agent connects from outside) blocks new
outbound connections of the account with nftables, DNS and loopback included; active network tests
go through `ai-diag`, to the loopback, the gateway, the resolvers and the targets you list in
`/etc/add-ai-user/restricted/targets`. `local` (a CLI on the server) leaves them open because the
CLI needs its API, and the script warns about it: the agent can send what it reads anywhere it can
reach. A domain allow list through a proxy is not implemented yet.

**Packages.** Read-only tools of the chosen categories are installed, without starting their
services. Tools tied to a technology (fail2ban, mdadm, Docker...) are never installed: they are used
if present, otherwise the diagnostic answers `unavailable`.

**Changing and removing.** `--update --allow <list> <user>` changes the categories and closes the
sessions of the account, because a running process keeps its old groups. `--update --standard <user>`
turns it back into a standard account; the privileged groups it had before are not given back.

**Limits you should know about:**

- Disk space: without quotas the home can still fill the disk. A single file stops at 1 GiB, not the
  total. `/tmp` is shared with the system.
- Anything the account can already read with ordinary Unix permissions stays readable, as does
  everything `ai-diag` returns: choose categories knowing the text goes to the model.
- Log and process names are attacker-influenced. They are marked `untrusted` and the agent is told
  not to obey them, which reduces prompt injection but doesn't remove it.
- Removal of secrets from logs works by pattern, so it can miss some.
- Files it owned outside its home before the conversion remain its own: the script lists them.
- In a container, the kernel, SMART, BMC, dmidecode, perf and BPF diagnostics answer `unavailable`.
- Not covered yet: aide, ClamAV, YARA, OpenSCAP and needrestart in `security_scans`, service
  diagnostics that need credentials (database roles, Redis...), Docker logs, UPS.

## Watching and reading back

- `ssh -t <user>@<host> tmux attach -r -t <session>` shows an agent's session read-only;
  drop `-r` to be able to type too. On the server: `tmux ls`, then `tmux attach -t
  <session>`, or **F9 > Choose session / window**.
- `tmux-logs` lists the latest recordings, `tmux-logs view <name>` reads one,
  `tmux-logs replay <name>` prints it raw so that full-screen apps (Claude Code, htop...)
  are redrawn, `tmux-logs grep <pattern>` searches them all, `tmux-logs du` shows the
  space used. `<name>` can be any part of a file name.

## Key bindings

Byobu's keys, on top of Oh my tmux!. **F1** shows them all, **F9** opens a menu.

| Key | Action |
| --- | --- |
| F2 | new window (in the current directory) |
| F3 / F4, Alt+← / Alt+→ | previous / next window |
| Ctrl+F2 / Shift+F2 | split side by side / top and bottom |
| Shift+arrows | move between panes |
| Alt+Shift+arrows | resize the pane |
| Shift+F11 | zoom the pane |
| F6 | detach |
| F7, Alt+PgUp | scroll back (copy mode) |
| F8 / Ctrl+F8 | rename the window / session |
| Alt+↑ / Alt+↓ | previous / next session |
| Shift+F9 / Ctrl+F9 | type a command in every pane / window |
| Alt+F9 | synchronize typing across panes |
| Shift+F12 | turn the F-keys off (for htop, mc...) and back on |
| Alt+F12 | mouse on / off |
| F12 or Ctrl+b | tmux prefix (Ctrl+a is left to the shell) |

## Configuration

`/etc/add-ai-user/add-ai-user.conf`, shared by every add-ai-user account:

```bash
SSH_HOST=server.example.com   # host name shown to agents
LOG_CHUNK_MB=50               # a pane log starts a new file every LOG_CHUNK_MB
LOG_MIN_FREE_MB=2048          # recording pauses below this much free disk space
LOG_KEEP_DAYS=30              # logs older than this are deleted
LOG_MAX_TOTAL_MB=2048         # per account cap, the oldest compressed logs go first
RESTRICTED_MEMORY_MAX=50%     # limits of each restricted account, applied by --update
RESTRICTED_TASKS_MAX=1024
RESTRICTED_CPU_QUOTA=200%
```

Per account: `~/AGENTS.md` (instructions for agents, see above) and
`~/.config/tmux/tmux.conf.local` (tmux settings, Oh my tmux! style). It also shows, for 5
seconds when someone connects, that the account was set up with add-ai-user, by
[vibe.archi](https://vibe.archi/): remove the `client-session-changed` hook there to hide it.

## What gets installed

| Path | What |
| --- | --- |
| `/usr/local/lib/add-ai-user/ssh-gate` | the SSH gate (Python) |
| `/usr/local/lib/add-ai-user/oh-my-tmux/` | Oh my tmux!, shared by every account |
| `/usr/local/lib/add-ai-user/tmux/` | tmux template config, F1 help, recording and broadcast scripts |
| `/usr/local/lib/add-ai-user/tmux-logs-janitor` | compresses, expires and caps the logs |
| `/usr/local/bin/tmux-logs` | log reader |
| `/etc/add-ai-user/add-ai-user.conf` | settings |
| `/etc/add-ai-user/AGENTS.md`, `AGENTS-restricted.md` | templates of the managed block of `~/AGENTS.md` |
| `/etc/ssh/sshd_config.d/60-add-ai-user.conf` | `Match Group add-ai-user` + `ForceCommand`; password login per account |
| groups `add-ai-key-only`, `add-ai-password-login` | password login off / on for their members |
| `/etc/systemd/system/add-ai-user-janitor@.{service,timer}` | one janitor timer per account |
| `~/AGENTS.md` | instructions for agents |
| `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` | make the CLIs read `~/AGENTS.md` |
| `~/.config/tmux/tmux.conf` | link to Oh my tmux! |
| `~/.config/tmux/tmux.conf.local` | the account's tmux settings |
| `~/tmux-logs/` | the recordings |

Only with a restricted account:

| Path | What |
| --- | --- |
| `/usr/local/lib/add-ai-user/restricted/` | catalog, collector, `ai-diag`, login shell, scan runner |
| `/usr/local/bin/ai-diag` | what the agent runs |
| `/etc/systemd/system/ai-diag-<profile>.socket`, `ai-diag-<profile>@.service` | one socket and one sandboxed collector per privilege level |
| `/etc/systemd/system/add-ai-user-outbound.service` | loads the outbound rules |
| `/etc/systemd/system/add-ai-user-scans.{service,timer}` | weekly scans, when scanners are enabled |
| `/etc/systemd/system/user@<uid>.service.d/`, `user-<uid>.slice.d/` | `no_new_privs` and limits of the account |
| `/etc/add-ai-user/restricted/` | state of each account, approved targets, scanners, outbound rules |
| `/etc/add-ai-user/agents/<user>.md` | the real `AGENTS.md` of the account |
| `/etc/polkit-1/rules.d/60-add-ai-user.rules` | polkit refuses the account everything |
| `/etc/ssh/sshd_config.d/61-add-ai-restricted.conf` | no forwarding |
| `/etc/cron.deny`, `/etc/at.deny` | one line for the account |
| `/var/lib/add-ai-user/scans/` | latest output of the scanners |
| user `ai-diag`, groups `add-ai-restricted` and `ai-diag-<category>` | identity of the collectors, rights of the accounts |

## Tests

```bash
tests/test-gate.sh    # 47+ commands the gate must refuse or allow (run as an add-ai-user account)
tests/test-logs.sh    # pane-logger chunks and janitor rules, in a temporary directory
sudo tests/test-login.sh   # throwaway accounts: password, sudo, password login on and off, real SSH
                           # logins on 127.0.0.1, refusals; deletes them at the end
tests/test-restricted.sh   # run as a restricted account, in a pane: what it can't do, every granted
                           # diagnostic, bad parameters, rate limit. --all adds the slow scans
sudo tests/probe-restricted.sh   # what a new host or container allows: sandbox, capabilities, nft
```

## How it works

See [docs/how-it-works.md](docs/how-it-works.md): the gate's rules, the recording pipeline,
the janitor, and why things are done this way.

## Credits

- [Oh my tmux!](https://github.com/gpakosz/.tmux) by Gregory Pakosz (WTFPL / MIT), cloned
  at install time; `lib/tmux/tmux.conf.local` is based on its template.
- Key layout from [byobu](https://www.byobu.org/) by Dustin Kirkland.
