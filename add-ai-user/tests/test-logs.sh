#!/bin/bash
# test-logs.sh: pane-logger chunking + tmux-logs-janitor (compress, expire, cap) in a temp dir
lib=${ADDAI_LIB:-/usr/local/lib/addai}
d=$(mktemp -d) && mkdir -p "$d/s"

echo "== pane-logger: 3336 bytes, chunks of 1000"
head -c 2500 /dev/urandom | base64 -w0 | ADDAI_CONF=/dev/null LOG_CHUNK_BYTES=1000 "$lib/tmux/pane-logger" "$d/s/x"
ls -l "$d/s" | awk 'NR > 1 { print $5, $9 }'
rm -f "$d"/s/*

echo "== janitor"
head -c 400000 /dev/urandom > "$d/s/closed.log"; touch -d '5 minutes ago' "$d/s/closed.log"
: > "$d/s/empty.log"; touch -d '5 minutes ago' "$d/s/empty.log"
head -c 1000 /dev/urandom > "$d/s/open.log"; touch -d '5 minutes ago' "$d/s/open.log"
(exec 3>> "$d/s/open.log"; sleep 20) &
for i in 1 2 3; do head -c 100000 /dev/urandom | gzip > "$d/s/old$i.log.gz"; touch -d "$((10 - i)) days ago" "$d/s/old$i.log.gz"; done
echo x | gzip > "$d/s/expired.log.gz"; touch -d '40 days ago' "$d/s/expired.log.gz"
sleep 1
echo "before:"; ls "$d/s" | tr '\n' ' '; echo
ADDAI_CONF=/dev/null LOG_DIR=$d LOG_MAX_TOTAL_BYTES=450000 "$lib/tmux-logs-janitor"
echo "after:"; ls "$d/s" | tr '\n' ' '; echo; du -sb "$d" | cut -f1
kill %1 2>/dev/null; rm -rf "$d"
