#!/bin/bash
# test-login.sh: run as root on a test machine. Creates throwaway accounts (aitest-login-*)
# with add-ai-user.sh and options only, then checks their password, sudo, sshd's effective
# settings and real SSH logins on 127.0.0.1, by key and by password. The accounts are
# deleted at the end. Needs sshd listening on 127.0.0.1.
set -uo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
[ "$(id -u)" -eq 0 ] || { echo "run me as root"; exit 1; }
tmp=$(mktemp -d)
users=(aitest-login-a aitest-login-b aitest-login-c aitest-login-d aitest-login-e)
pass=$(head -c 12 /dev/urandom | base64 | tr -d '+/=')x1
pass2=$(head -c 12 /dev/urandom | base64 | tr -d '+/=')x2
failures=0

cleanup() {
  local user
  for user in "${users[@]}"; do
    id "$user" >/dev/null 2>&1 || continue
    "$SRC/add-ai-user.sh" --remove "$user" >/dev/null 2>&1
    loginctl terminate-user "$user" 2>/dev/null
    userdel -r -f "$user" 2>/dev/null
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

check() {  # check <description> <command...>: the command must succeed
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $what"; else echo "FAIL  $what"; failures=$((failures + 1)); fi
}
check_not() {
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL  $what"; failures=$((failures + 1)); else echo "ok    $what"; fi
}

add() {  # add <user> <options...>, without a terminal so that nothing is asked
  local user=$1; shift
  "$SRC/add-ai-user.sh" "$@" "$user" </dev/null >>"$tmp/$user.log" 2>&1
}
in_group() { [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]; }
has_password() { [ "$(passwd -S "$1" | cut -d' ' -f2)" = P ]; }
sshd_says() {  # sshd_says <user> <value>: effective PasswordAuthentication for <user>
  local config  # read whole: with pipefail, grep -q in a pipe can fail on sshd's SIGPIPE
  config=$(sshd -T -C "user=$1,host=localhost,addr=127.0.0.1") || return 1
  grep -qix "passwordauthentication $2" <<<"$config"
}
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
login_key() {
  ssh "${ssh_opts[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
    -i "$tmp/key" "$1@127.0.0.1" cat AGENTS.md
}
login_password() {  # login_password <user> <password>
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" >"$tmp/askpass"
  chmod 700 "$tmp/askpass"
  SSH_ASKPASS=$tmp/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=none setsid -w ssh "${ssh_opts[@]}" \
    -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
    -o NumberOfPasswordPrompts=1 "$1@127.0.0.1" cat AGENTS.md </dev/null
}
sudo_with() { printf '%s\n' "$2" | runuser -u "$1" -- sudo -S -k -p '' true; }

ssh-keygen -q -t ed25519 -N '' -C test-login -f "$tmp/key"
printf '%s\n' "$pass" >"$tmp/pass"
printf '%s\n' "$pass2" >"$tmp/pass2"
for user in "${users[@]}"; do
  ! id "$user" >/dev/null 2>&1 || { echo "$user exists already: remove it first"; trap - EXIT; exit 1; }
done

a=aitest-login-a
echo "== $a: standard, password, key, no password login"
check "created" add $a --standard --password-file "$tmp/pass" --key "$tmp/key.pub" --no-password-login
check "has a password" has_password $a
check "is a sudoer" in_group $a sudo
check "sudo takes the password" sudo_with $a "$pass"
check_not "sudo refuses another password" sudo_with $a wrong-password
check "in add-ai-key-only" in_group $a add-ai-key-only
check "sshd: password authentication off" sshd_says $a no
check "SSH login with the key" login_key $a
check_not "SSH login with the password refused" login_password $a "$pass"

echo "== $a: --update --password-login, then a new password from standard input"
check "updated" add $a --update --password-login
check_not "out of add-ai-key-only" in_group $a add-ai-key-only
check "sshd: password authentication on" sshd_says $a yes
check "SSH login with the password" login_password $a "$pass"
check "updated" sh -c "'$SRC/add-ai-user.sh' --update --password-file - $a <'$tmp/pass2' >>'$tmp/$a.log' 2>&1"
check "sudo takes the new password" sudo_with $a "$pass2"
check_not "the old password is gone" sudo_with $a "$pass"
check "still a sudoer, still with password login" sh -c "id -nG $a | grep -qw sudo && sshd -T -C user=$a,host=localhost,addr=127.0.0.1 | grep -qix 'passwordauthentication yes'"

b=aitest-login-b
echo "== $b: standard, password, no key"
check "created" add $b --standard --password-file "$tmp/pass" --no-key
check "in add-ai-password-login" in_group $b add-ai-password-login
check "sshd: password authentication on" sshd_says $b yes
check "SSH login with the password" login_password $b "$pass"
check_not "SSH login with a wrong password refused" login_password $b wrong-password
check "is a sudoer" in_group $b sudo

c=aitest-login-c
echo "== $c: standard, key, --no-sudo, no terminal: key only by default"
check "created" add $c --standard --password-file "$tmp/pass" --key "$tmp/key.pub" --no-sudo
check_not "not a sudoer" in_group $c sudo
check "in add-ai-key-only" in_group $c add-ai-key-only
check "SSH login with the key" login_key $c

d=aitest-login-d
echo "== $d: refusals, nothing created"
check_not "no key and no password refused" add $d --standard
check_not "--no-password-login without a key refused" add $d --standard --password-file "$tmp/pass" --no-key --no-password-login
check_not "a password of 7 characters refused" sh -c "printf 'short12\n' | '$SRC/add-ai-user.sh' --standard --password-file - --no-key $d"
check_not "--sudo on a restricted account refused" add $d --restricted --allow none --agent-location remote --sudo --password-file "$tmp/pass" --no-key
check_not "-p without a terminal refused" add $d --standard -p --no-key
check_not "$d doesn't exist" id $d

e=aitest-login-e
echo "== $e: restricted, password, no key"
check "created" add $e --restricted --allow none --agent-location remote --password-file "$tmp/pass" --no-key
check_not "not a sudoer" in_group $e sudo
check "SSH login with the password" login_password $e "$pass"

echo "== the passwords never show up in the output"
check_not "nothing in the logs" grep -rqF -e "$pass" -e "$pass2" "$tmp"/*.log

if ((failures)); then
  echo "$failures failure(s); logs of the script:"
  tail -n +1 "$tmp"/*.log
  exit 1
fi
echo "all good"
