# Instructions for AI agents on this account

You are on the account `{user}` of `{host}`. Read this whole file before doing anything else.

## Connecting from outside

Over SSH, everything goes through tmux, so that your work stays visible and is logged in
`~/tmux-logs`. Shells and other commands are refused; `scp` and `sftp` are allowed.

```
ssh {user}@{host} tmux new -d -s <session>
ssh {user}@{host} "tmux send-keys -t <session> '<command>' Enter"
ssh {user}@{host} tmux capture-pane -p -t <session>
```

Keep the double quotes around the whole tmux command, or your shell drops the inner ones.
To know when a command is over, make it signal a tmux channel and wait for that channel:

```
ssh {user}@{host} "tmux send-keys -t <session> '<command>; tmux wait-for -S done' Enter"
ssh {user}@{host} tmux wait-for done
```

## Rules

1. Name your tmux session after your task: short and descriptive, lowercase words separated
   by dashes (fix-login-bug, deploy-api, review-pr-42), never a generic name such as "work",
   "main" or "s1".
2. As soon as the session exists, give your user its name and the command to watch it from
   outside, in case they want to:

   ```
   ssh -t {user}@{host} tmux attach -r -t <session>
   ```

   `-r` is read-only: they see everything without typing into your session. F6 or Ctrl+b d
   detaches.
