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
Match all
```

With `ForceCommand`, sshd runs the gate instead of whatever the client asked for, and puts
the client's command in `SSH_ORIGINAL_COMMAND` (empty for an interactive login).

Why not a fake login shell (`chsh -s gate`)? tmux starts its panes with the login shell,
so the panes themselves would be refused; `su`, `sudo -iu`, cron... would break too.
`ForceCommand` only applies to SSH, and the account can't change it.

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

Refusals and allowed commands are logged to syslog (`journalctl -t add-ai-user-gate`). A refusal
prints the standard message, followed by the content of `~/.ai/con-refused.txt` when the
file exists (up to 64 KB).

`tests/test-gate.sh` runs the gate on 47 commands (37 refused, 10 allowed), plus the
custom message when there is one.

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

Oh my tmux! is cloned once in `/usr/local/lib/add-ai-user/oh-my-tmux` and linked from every
account's `~/.config/tmux/tmux.conf`; running `add-ai-user.sh` again updates it.

## 5. Working as an agent through the gate

Only tmux commands go through, so an agent (or a human script) works like this:

```bash
H=bob@server.example.com
ssh $H tmux new -d -s work
ssh $H "tmux send-keys -t work -l -- 'make test; tmux wait-for -S done-1' \; send-keys -t work Enter"
ssh $H tmux wait-for done-1                    # blocks until the command has finished
ssh $H tmux capture-pane -p -J -t work -S -200   # its output
```

Files are copied with scp, then used from a pane. Everything the agent types is visible
in the pane, recorded in `~/tmux-logs`, and each SSH command is in the gate's syslog.

## Tested on

Ubuntu 26.04 (tmux 3.6, OpenSSH 10.2, Python 3.14), in a Proxmox LXC container, with
connections from Windows (OpenSSH for Windows).
