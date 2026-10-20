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
- **Rules for agents** per account: the content of `~/.ai/con-refused.txt` is shown below
  the standard refusal message. The default rules ask agents to give their session a
  short, descriptive name and to tell their user the command to watch it
  ([Rules for agents](#rules-for-agents)).
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
`rules.txt` to `~bob/.ai/con-refused.txt` and starts bob's log janitor. Without
`--message`, bob gets the default rules.

Without `--key`, when the user has no key yet, the script asks for one before changing
anything: paste the public key, check its fingerprint, then confirm it or enter it again.

```
==> No --key given: paste the SSH public key bob will log in with
SSH public key: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... agent@laptop
  key:         ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...k9xYbV2cTn8uE5fHs7dLp agent@laptop
  fingerprint: 256 SHA256:Wq3mJr0k9xYbV2cTn8uE5fHs7dLpA1gZ4iKoR6tMvNe agent@laptop (ED25519)
Is this the right key? [y = yes, n = enter it again] y
```

```
Usage: sudo ./add-ai-user.sh [options] <user>
       sudo ./add-ai-user.sh --update [options] <user>
       sudo ./add-ai-user.sh --system-only [--host <name>]
       sudo ./add-ai-user.sh --remove <user>
       sudo ./add-ai-user.sh --uninstall

  -k, --key <file|key>  authorize SSH public key(s), repeatable
      --no-key          don't ask for a key (password login, or keys added later)
  -m, --message <file>  rules shown below the "connection refused" message (default:
                        /etc/add-ai-user/con-refused.txt; "default" applies it again)
  -p, --password        set the user's password (asked interactively)
  -s, --sudo            add the user to the sudo group (asks for a password if it has none)
  -u, --update          <user> already exists: (re)apply the add-ai-user setup to it
      --host <name>     host name shown in the refusal message
      --system-only     install or update the system part only
      --remove <user>   take <user> out of add-ai-user (the account and its files are kept)
      --uninstall       remove add-ai-user from the system (users and their files are kept)
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
  work stays visible and is logged in ~/tmux-logs.

  Human: ssh -t bob@server.example.com tmux new -A -s <name>
  AI:    ssh bob@server.example.com tmux new -d -s <name>
         ssh bob@server.example.com "tmux send-keys -t <name> '<command>' Enter"
         ssh bob@server.example.com tmux capture-pane -p -t <name>
         (to run a command, type it into a tmux shell with send-keys; keep the
         double quotes, or your shell drops the inner ones)
  Files: scp / sftp are still allowed.

  Rules for AI agents on this account:

  1. Name your tmux session after your task: short and descriptive, lowercase
     words separated by dashes (fix-login-bug, deploy-api, review-pr-42), never
     a generic name such as "work", "main" or "s1".

  2. As soon as the session exists, give your user its name and the command to
     watch it from outside, in case they want to:

       ssh -t bob@server.example.com tmux attach -r -t <session>

     (-r is read-only: they see everything without typing into your session.
     F6 or Ctrl+b d detaches.)
```

## Rules for agents

The text of `~<user>/.ai/con-refused.txt` is shown below the standard refusal message:
it is where you tell the agents of an account how to work. The gate reads it at each
refused connection, so a change applies at once.

- New accounts get the default rules, `/etc/add-ai-user/con-refused.txt` (shown above):
  edit that file to change them for the next accounts. `{user}` and `{host}` are replaced
  by the account and host names when the rules are copied.
- `--message <file>` gives an account its own rules; `--update --message default <user>`
  puts the default ones back. `--update` without `--message` keeps the account's rules.
- Or edit `~<user>/.ai/con-refused.txt` directly. It belongs to the account, so its
  agents could change it too (you would see it in the recordings).

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
SSH_HOST=server.example.com   # host name shown in the refusal message
LOG_CHUNK_MB=50               # a pane log starts a new file every LOG_CHUNK_MB
LOG_MIN_FREE_MB=2048          # recording pauses below this much free disk space
LOG_KEEP_DAYS=30              # logs older than this are deleted
LOG_MAX_TOTAL_MB=2048         # per account cap, the oldest compressed logs go first
```

Per account: `~/.ai/con-refused.txt` (rules for agents, see above) and
`~/.config/tmux/tmux.conf.local` (tmux settings, Oh my tmux! style).

## What gets installed

| Path | What |
| --- | --- |
| `/usr/local/lib/add-ai-user/ssh-gate` | the SSH gate (Python) |
| `/usr/local/lib/add-ai-user/oh-my-tmux/` | Oh my tmux!, shared by every account |
| `/usr/local/lib/add-ai-user/tmux/` | tmux template config, F1 help, recording and broadcast scripts |
| `/usr/local/lib/add-ai-user/tmux-logs-janitor` | compresses, expires and caps the logs |
| `/usr/local/bin/tmux-logs` | log reader |
| `/etc/add-ai-user/add-ai-user.conf` | settings |
| `/etc/add-ai-user/con-refused.txt` | default rules for agents, copied to new accounts |
| `/etc/ssh/sshd_config.d/60-add-ai-user.conf` | `Match Group add-ai-user` + `ForceCommand` |
| `/etc/systemd/system/add-ai-user-janitor@.{service,timer}` | one janitor timer per account |
| `~/.config/tmux/tmux.conf` | link to Oh my tmux! |
| `~/.config/tmux/tmux.conf.local` | the account's tmux settings |
| `~/tmux-logs/` | the recordings |

## Tests

```bash
tests/test-gate.sh    # 47+ commands the gate must refuse or allow (run as an add-ai-user account)
tests/test-logs.sh    # pane-logger chunks and janitor rules, in a temporary directory
```

## How it works

See [docs/how-it-works.md](docs/how-it-works.md): the gate's rules, the recording pipeline,
the janitor, and why things are done this way.

## Credits

- [Oh my tmux!](https://github.com/gpakosz/.tmux) by Gregory Pakosz (WTFPL / MIT), cloned
  at install time; `lib/tmux/tmux.conf.local` is based on its template.
- Key layout from [byobu](https://www.byobu.org/) by Dustin Kirkland.
