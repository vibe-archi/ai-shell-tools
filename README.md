# ai-shell-tools

Shell scripts to set up AI-friendly work environments on Linux servers: places where AI
agents (Claude Code, Codex, ...) can work over SSH while humans keep an eye on them.

| Tool | What it does |
| --- | --- |
| [add-ai-user](add-ai-user/) | Creates a user whose every SSH session goes through tmux: you can watch an agent live and read back everything it did (`~/tmux-logs`). Oh my tmux! with byobu-style keys. |

## Requirements

Debian or Ubuntu with systemd. Each tool installs the packages it needs with apt.

## License

[MIT](LICENSE)
