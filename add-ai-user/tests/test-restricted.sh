#!/bin/bash
# test-restricted.sh: run as a restricted account, in a tmux pane. Checks what the account can't
# do, then asks every granted diagnostic for a well-formed answer and tries to abuse the collectors.
fails=0

no() {  # no <description> <command...>: the command must fail
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL could: $what"; fails=$((fails + 1))
  else
    echo " ok  can't: $what"
  fi
}

yes() {
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo " ok  can:   $what"
  else
    echo "FAIL can't: $what"; fails=$((fails + 1))
  fi
}

[ "$(awk '/^NoNewPrivs/ {print $2}' /proc/self/status)" = 1 ] && echo " ok  no_new_privs is set" ||
  { echo "FAIL no_new_privs is not set"; fails=$((fails + 1)); }

no 'sudo'                  sudo -n true
no 'su'                    su -c true root </dev/null
no 'write in /etc'         touch /etc/ai-test
no 'write in /usr'         touch /usr/ai-test
no 'read /etc/shadow'      cat /etc/shadow
no 'crontab'               crontab -l
no 'at'                    at -l
no 'enable-linger'         loginctl enable-linger "$USER"
no 'restart a service'     systemctl restart ssh
no 'set the timezone'      timedatectl set-timezone UTC
no 'change AGENTS.md'      sh -c 'echo x >>"$(readlink -f ~/AGENTS.md)"'
no 'run the helper socket as another profile' sh -c 'printf "{\"category\":\"base\",\"preset\":\"uptime\"}\n" | python3 -c "
import socket,sys,json
s=socket.socket(socket.AF_UNIX); s.connect(\"/run/ai-diag/logs.sock\"); s.sendall(sys.stdin.buffer.read())
sys.exit(0 if json.loads(s.makefile().readline())[\"status\"]==\"ok\" else 1)"'
yes 'write in the home'    sh -c 'touch ~/.ai-test && rm ~/.ai-test'
yes 'ai-diag list'         ai-diag list
yes 'tmux'                 tmux list-sessions

python3 -I - <<'EOF'
import json
import os
import socket
import sys
import time

sys.path.insert(0, "/usr/local/lib/add-ai-user/restricted")
import catalog

STATUSES = {"ok", "partial", "unavailable", "denied", "invalid", "rate_limited", "timeout", "truncated"}
SAMPLES = {"unit": "ssh.service", "since": "1h", "interface": "lo", "target": "loopback", "dns_type": "A",
           "local_user": "root", "listening_port": "22"}
FUZZ = ["--help", "-oProxyCommand=id", "/etc/shadow", "../../etc/shadow", "a;id", "$(id)", "`id`", "a\nb",
        "x" * 300, "ssh.service --output=/tmp/x"]
fails = 0
counts = {}


def ask(preset, params):
    """A request, waiting for the rate limit: the tests run far more requests than an agent."""
    while True:
        frame = ask_once(preset, params)
        if frame.get("status") != "rate_limited":
            return frame
        time.sleep(3)


def ask_once(preset, params):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.settimeout(preset["timeout"] + 30)
        conn.connect(f"/run/ai-diag/{preset['profile']}.sock")
        conn.sendall(json.dumps(dict(category=preset["category"], preset=preset["name"], params=params)).encode() + b"\n")
        data = b""
        while chunk := conn.recv(65536):
            data += chunk
    return json.loads(data)


def granted(category):
    import grp
    return grp.getgrnam(catalog.group(category)).gr_gid in os.getgroups()


slow = {"setuid-files", "world-writable", "file-capabilities", "directory-sizes"}
for key, preset in catalog.PRESETS.items():
    category = preset["category"]
    if not granted(category):
        try:
            ask_once(preset, {})
            print(f"FAIL {key}: answered without the group")
            fails += 1
        except PermissionError:
            pass
        continue
    if preset["name"] in slow and "--all" not in sys.argv:
        continue
    params = {f: SAMPLES[k] for f, k in preset["params"].items() if k in SAMPLES}
    frame = ask(preset, params)
    status = frame.get("status")
    counts[status] = counts.get(status, 0) + 1
    good = status in STATUSES and "scope" in frame and isinstance(frame.get("output"), str)
    if not good or status in ("denied", "timeout") or (status == "invalid" and len(params) == len(preset["params"])):
        print(f"FAIL {key}: {status}: {str(frame.get('output'))[:200]}")
        fails += 1
    else:
        print(f" ok  {key}: {status}")
    for value in FUZZ:
        for field, kind in preset["params"].items():
            frame = ask(preset, {**params, field: value})
            if frame.get("status") not in ("invalid", "unavailable"):
                print(f"FAIL {key}: {field}={value!r} was accepted: {frame.get('status')}")
                fails += 1

try:
    frame = ask(catalog.PRESETS["base/uptime"], {"nope": "1"})
    if frame["status"] != "invalid":
        print("FAIL unknown parameter accepted")
        fails += 1
except OSError as e:
    print(f"FAIL base socket: {e}")
    fails += 1

seen = set()
for _ in range(120):
    seen.add(ask_once(catalog.PRESETS["base/uptime"], {})["status"])
if "rate_limited" in seen:
    print(" ok  rate limit reached in a burst")
else:
    print(f"FAIL no rate limit in a burst of 120: {seen}")
    fails += 1
print("statuses:", counts)
sys.exit(1 if fails else 0)
EOF
fails=$((fails + $?))
echo "$fails failure(s)"
