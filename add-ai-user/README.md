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

On the system, everything uses the short name **addai**: the `addai` group (its members
are the "addai accounts"), `/usr/local/lib/addai`, `/etc/addai`, `addai-janitor@<user>`.

## What you get

- **An SSH gate** (`ForceCommand` for the members of the `addai` group): only `tmux`
  commands on the account's default tmux server go through, plus scp / sftp. Shells,
  other commands, private tmux servers (`-L`, `-S`) and every tmux command that runs
  something outside a visible pane (`run-shell`, `if-shell`, a command given to
  `new-window`, `#(...)` formats, ...) are refused with an explanation.
- **A custom refusal message** per account: the content of `~/.ai/con-refused.txt` is shown
  below the standard one, a good place for the rules an agent must follow.
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

## Quick start

```bash
git clone https://github.com/vibe-archi/ai-shell-tools.git && cd ai-shell-tools/add-ai-user
sudo ./add-ai-user.sh --host server.example.com --key ~/agent_key.pub --message rules.txt bob
```

This installs the system part (once), creates `bob`, authorizes the key, copies
`rules.txt` to `~bob/.ai/con-refused.txt` and starts bob's log janitor.

```
Usage: sudo ./add-ai-user.sh [options] <user>
       sudo ./add-ai-user.sh --update [options] <user>
       sudo ./add-ai-user.sh --system-only [--host <name>]
       sudo ./add-ai-user.sh --remove <user>
       sudo ./add-ai-user.sh --uninstall

  -k, --key <file|key>  authorize SSH public key(s), repeatable
  -m, --message <file>  text shown below the "connection refused" message
  -p, --password        set the user's password (asked interactively)
  -s, --sudo            add the user to the sudo group (asks for a password if it has none)
  -u, --update          <user> already exists: (re)apply the addai setup to it
      --host <name>     host name shown in the refusal message
      --system-only     install or update the system part only
      --remove <user>   take <user> out of addai (the account and its files are kept)
      --uninstall       remove addai from the system (users and their files are kept)
```

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
ssh bob@server.example.com tmux new -d -s work                         # once
ssh bob@server.example.com "tmux send-keys -t work 'make test' Enter"   # type a command
ssh bob@server.example.com tmux capture-pane -p -t work -S -100         # read the screen
```

The command line is read twice, by your shell and on the server: keep the double quotes
around the whole tmux command. With `ssh ... tmux send-keys -t work 'make test' Enter`,
your shell removes the single quotes, and tmux receives `make` and `test` as two separate
keys and types `maketest`.

To know when a command is over, make it signal a tmux channel and wait for it:

```bash
ssh bob@server.example.com "tmux send-keys -t work 'make test; tmux wait-for -S done' Enter"
ssh bob@server.example.com tmux wait-for done      # returns when make test has finished
```

Anything else is refused:

```
$ ssh bob@server.example.com

  Connection refused: direct connection without tmux.

  On this account everything goes through tmux (default server), so that the
  work stays visible and is logged in ~/tmux-logs.

  Human: ssh -t bob@server.example.com tmux new -A -s <name>
  AI:    ssh bob@server.example.com tmux new -d -s <name>
         ssh bob@server.example.com "tmux send-keys -t <name> '<command>' Enter"
         ssh bob@server.example.com tmux capture-pane -p -t <name>
         (to run a command, type it into a tmux shell with send-keys; keep the
         double quotes, or your shell drops the inner ones)
  Files: scp / sftp are still allowed.

<content of ~bob/.ai/con-refused.txt>
```

## Watching and reading back

- `tmux ls`, then `tmux attach -t <session>`, or **F9 > Choose session / window**:
  you share the agent's screen, live.
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

`/etc/addai/addai.conf`, shared by every addai account:

```bash
SSH_HOST=server.example.com   # host name shown in the refusal message
LOG_CHUNK_MB=50               # a pane log starts a new file every LOG_CHUNK_MB
LOG_MIN_FREE_MB=2048          # recording pauses below this much free disk space
LOG_KEEP_DAYS=30              # logs older than this are deleted
LOG_MAX_TOTAL_MB=2048         # per account cap, the oldest compressed logs go first
```

Per account: `~/.ai/con-refused.txt` (refusal message) and
`~/.config/tmux/tmux.conf.local` (tmux settings, Oh my tmux! style).

## What gets installed

| Path | What |
| --- | --- |
| `/usr/local/lib/addai/ssh-gate` | the SSH gate (Python) |
| `/usr/local/lib/addai/oh-my-tmux/` | Oh my tmux!, shared by every account |
| `/usr/local/lib/addai/tmux/` | tmux template config, F1 help, recording and broadcast scripts |
| `/usr/local/lib/addai/tmux-logs-janitor` | compresses, expires and caps the logs |
| `/usr/local/bin/tmux-logs` | log reader |
| `/etc/addai/addai.conf` | settings |
| `/etc/ssh/sshd_config.d/60-addai.conf` | `Match Group addai` + `ForceCommand` |
| `/etc/systemd/system/addai-janitor@.{service,timer}` | one janitor timer per account |
| `~/.config/tmux/tmux.conf` | link to Oh my tmux! |
| `~/.config/tmux/tmux.conf.local` | the account's tmux settings |
| `~/tmux-logs/` | the recordings |

## Tests

```bash
tests/test-gate.sh    # 47+ commands the gate must refuse or allow (run as an addai user)
tests/test-logs.sh    # pane-logger chunks and janitor rules, in a temporary directory
```

## How it works

See [docs/how-it-works.md](docs/how-it-works.md): the gate's rules, the recording pipeline,
the janitor, and why things are done this way.

## Credits

- [Oh my tmux!](https://github.com/gpakosz/.tmux) by Gregory Pakosz (WTFPL / MIT), cloned
  at install time; `lib/tmux/tmux.conf.local` is based on its template.
- Key layout from [byobu](https://www.byobu.org/) by Dustin Kirkland.
