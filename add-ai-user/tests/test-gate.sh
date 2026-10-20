#!/bin/bash
# test-gate.sh [gate]: feed SSH_ORIGINAL_COMMAND cases to the addai ssh-gate (no TTY) and check
# which ones are refused. Allowed cases really run tmux, so they are all harmless.
gate=${1:-/usr/local/lib/addai/ssh-gate}
fails=0

t() {
  local expect=$1 cmd=$2 out rc got reason
  out=$(SSH_ORIGINAL_COMMAND="$cmd" SSH_CLIENT="127.0.0.1 0 22" "$gate" </dev/null 2>&1); rc=$?
  if [ $rc -ne 0 ] && grep -q 'Connection refused' <<<"$out"; then got=refused; else got=allowed; fi
  reason=$(grep -o 'Connection refused: .*' <<<"$out" | sed 's/^Connection refused: //')
  [ "$got" = "$expect" ] && ok=" ok " || { ok=FAIL; fails=$((fails + 1)); }
  printf '%s %-8s %-52s %s\n' "$ok" "$got" "$cmd" "$reason"
}

t refused ''
t refused 'bash'
t refused 'ls -la'
t refused 'tmux -L other ls'
t refused 'tmux -S /tmp/sock ls'
t refused 'tmux -f /dev/null new -d'
t refused 'tmux -c id'
t refused 'tmux -CC'
t refused 'tmux run-shell id'
t refused 'tmux run id'
t refused 'tmux ru id'
t refused 'tmux if true "run id"'
t refused 'tmux new -d id'
t refused "tmux new -d -s x 'bash -c id'"
t refused 'tmux neww -t main htop'
t refused 'tmux splitw -t main -- top'
t refused 'tmux new -d -e FOO=1'
t refused 'tmux ls ; id'
t refused 'tmux ls | cat'
t refused 'tmux ls && bash'
t refused 'tmux ls > /tmp/x'
t refused 'tmux $(id)'
t refused 'tmux send-keys -t main "$(id)"'
t refused "tmux display -p '#(id)'"
t refused 'tmux send-keys -t main -K C-l'
t refused 'tmux send -X -t main copy-pipe id'
t refused 'tmux set -g default-command bash'
t refused "tmux set-hook -g after-new-window 'run id'"
t refused 'tmux source-file /tmp/x'
t refused 'tmux pipe-pane -t main cat'
t refused 'tmux clear-history -t main'
t refused 'tmux kill-server'
t refused 'tmux ls \; run-shell id'
t refused 'tmux ls\; run-shell id'
t refused 'tmux new -s needs-tty'
t refused 'tmux attach -t main'
t refused 'rsync --server -e.LsfxCIvu . /tmp'
t allowed 'tmux ls'
t allowed 'tmux -u ls'
t allowed 'tmux has -t main'
t allowed "tmux list-windows -t main -F '#{window_index}:#{window_name}'"
t allowed 'tmux new -d -s gatetest -c ~/'
t allowed "tmux send-keys -t gatetest -l -- 'echo \"hello; it works\" | wc -c' \\; send-keys -t gatetest Enter"
t allowed 'tmux capture-pane -p -t gatetest -S -3'
t allowed 'tmux kill-session -t gatetest'
t allowed 'tmux wait-for -S nothing-waits'
t allowed '/usr/lib/openssh/sftp-server'

custom=~/.ai/con-refused.txt
if [ -s "$custom" ]; then
  out=$(SSH_ORIGINAL_COMMAND='' "$gate" </dev/null 2>&1)
  if grep -qF -- "$(head -1 "$custom")" <<<"$out"; then
    echo " ok  refused  (custom message of $custom shown)"
  else
    echo "FAIL refused  (custom message of $custom missing)"; fails=$((fails + 1))
  fi
fi
echo "$fails failure(s)"
