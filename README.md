# ai-shell-tools

Shell scripts to set up AI-friendly work environments on Linux servers: places where AI
agents (Claude Code, Codex, ...) can work over SSH while humans keep an eye on them.

| Tool | What it does |
| --- | --- |
| [add-ai-user](add-ai-user/) | Creates a user account for an AI agent where everything happens in tmux, so that you can watch it work live and read back everything it did. |
| [setup-ubuntu-rdp](setup-ubuntu-rdp/) | Turns an Ubuntu VPS into a remote desktop (XFCE + Chrome) that you open with any RDP client, through an SSH tunnel or publicly. No GPU needed. |

## add-ai-user

**Watch what AI agents do on your server.**

AI coding agents often work on a server through SSH: they run commands one after the
other, and nobody sees them. `add-ai-user.sh` creates a Linux account made for such an
agent, where everything has to happen in tmux:

- **No hidden commands.** A plain `ssh` (an interactive shell, or `ssh host <command>`)
  is refused, with a message that tells the agent how to work instead: open a tmux
  session, type its commands into it with `tmux send-keys`, read the screen with
  `tmux capture-pane`. Tricks that would run something outside a visible pane (a private
  tmux server, `tmux run-shell`, ...) are refused too. scp and sftp still work.
- **Watch it live.** You attach to the same tmux session and see the agent type, as if
  you were looking over its shoulder.
- **Read it back later.** Every tmux pane is recorded in `~/tmux-logs`: compressed, kept
  30 days, capped at 2 GB per account. `tmux-logs` lists, reads, replays and searches
  the recordings.
- **Your rules.** The text of `~/.ai/con-refused.txt` is added to the refusal message, to
  tell agents how they must work on this account. The default rules ask them to name
  their session after their task and to share the command to watch it.
- **A comfortable tmux for humans too.** Oh my tmux! with byobu-style F-keys, mouse
  support, an F1 cheat sheet and an F9 menu.

It is a visibility tool, not a sandbox: once in a pane, an agent can do whatever the
account can do. It keeps honest agents in plain sight; it does not stop a hostile one.

### Quick start

On the server (Debian or Ubuntu, as root):

```bash
git clone https://github.com/vibe-archi/ai-shell-tools.git
cd ai-shell-tools/add-ai-user
sudo ./add-ai-user.sh --host server.example.com bob   # asks for bob's SSH public key
```

Then:

```bash
ssh bob@server.example.com tmux new -d -s fix-login                          # the agent...
ssh bob@server.example.com "tmux send-keys -t fix-login 'make test' Enter"   # ...types
ssh bob@server.example.com tmux capture-pane -p -t fix-login                 # ...and reads
ssh -t bob@server.example.com tmux attach -r -t fix-login                    # you watch
```

By default, the rules shown to a refused agent ask it to give its tmux session a short,
descriptive name and to tell you the command to watch it, like the last line above.

More: [add-ai-user/README.md](add-ai-user/README.md) (options, key bindings, logs,
configuration) and [add-ai-user/docs/how-it-works.md](add-ai-user/docs/how-it-works.md)
(the SSH gate's rules, the recording pipeline, design choices).

## setup-ubuntu-rdp

**A remote desktop on your VPS, no GPU needed.**

`setup-ubuntu-rdp.sh` installs an XFCE desktop with Google Chrome on an Ubuntu server
and makes it reachable with any RDP client (Windows, Linux, macOS). The desktop is drawn
in the server's memory and sent as compressed images, so a plain VPS, VM or container
is enough. Close the window and the desktop keeps running; reconnect and it is still
there.

- **Access through an SSH tunnel** (recommended, RDP only on `127.0.0.1`), or **public**
  with an optional address restriction (ufw) and **fail2ban** (5 failed logins in 10
  minutes: banned for 1 hour). Switch later with `--local` / `--public`.
- **A patched xrdp** (>= 0.10.6.1): when the Ubuntu repositories are older, the script
  rebuilds the packages of a newer Ubuntu release from their signed sources.
- A dedicated, non-sudoer desktop account; the script asks its name and password.

```bash
cd ai-shell-tools/setup-ubuntu-rdp
sudo ./setup-ubuntu-rdp.sh
```

More: [setup-ubuntu-rdp/README.md](setup-ubuntu-rdp/README.md).

## Requirements

Debian or Ubuntu with systemd (`setup-ubuntu-rdp`: Ubuntu 24.04+). Each tool installs the
packages it needs with apt.

## License

[MIT](LICENSE)
