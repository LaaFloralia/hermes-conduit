#!/bin/bash
set -euo pipefail
set +x
umask 077
: "${MACBOOK_USER:?}" "${MACBOOK_PASSWORD:?}"
case "$MACBOOK_USER" in *[!a-zA-Z0-9_.-]*|'') exit 1 ;; esac
task_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/laa-macbook.XXXXXXXX")
trap '/bin/rm -rf "$task_dir"' EXIT
trap 'exit 1' HUP INT TERM
cat > "$task_dir/askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' "$MACBOOK_PASSWORD"
ASKPASS
/bin/chmod 700 "$task_dir/askpass"
export SSH_ASKPASS="$task_dir/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
/usr/bin/ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=yes -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$MACBOOK_USER@100.85.197.49" 'set -e; printf "__MEMORY__\n"; /usr/sbin/sysctl -n hw.memsize; printf "__VM__\n"; /usr/bin/vm_stat; printf "__DISK__\n"; /bin/df -k /System/Volumes/Data' 2>/dev/null &
ssh_pid=$!
( /bin/sleep 20; /bin/kill "$ssh_pid" 2>/dev/null || : ) &
watchdog=$!
if wait "$ssh_pid"; then
  /bin/kill "$watchdog" 2>/dev/null || :
else
  /bin/kill "$watchdog" 2>/dev/null || :
  printf '%s\n' 'MacBook capacity unavailable' >&2
  exit 1
fi
