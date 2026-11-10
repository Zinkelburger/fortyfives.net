#!/bin/sh
# Copies production's journal (sshd, firewall, auditd, every container) to
# this machine, so someone who breaks into the Contabo host and wipes its
# logs does not take the record of how they got in with them. Run daily by
# anacron (see deploy/contabo/README.md); safe to run by hand any time.
#
#   scripts/pull-prod-logs.sh [ssh-host]   (default: twic-vps)
#
# Each run appends what journald has collected since the last one as
# ~/Backups/fortyfives.net/logs/journal-<UTC time>.jsonl.gz: one JSON object
# per line, every journald field kept. The first run takes everything the
# host still has. Files older than 400 days are deleted.
#
# Read them:
#   zcat journal-*.jsonl.gz | jq -r 'select(.SYSLOG_IDENTIFIER=="sshd") | .MESSAGE'
#   zgrep -h 'Accepted publickey' journal-*.jsonl.gz | jq -r '.MESSAGE'
#   zgrep -h '"audisp-syslog"' journal-*.jsonl.gz | jq -r .MESSAGE | grep EXECVE
# Progress and failures go to ~/Backups/fortyfives.net/pull-logs.log.
set -eu
host=${1:-twic-vps}
dest=${FORTYFIVES_BACKUP_DIR:-$HOME/Backups/fortyfives.net}
logs=$dest/logs
cursor_file=$logs/.cursor

mkdir -p "$logs/.partial"
chmod 700 "$dest" "$logs"
exec >> "$dest/pull-logs.log" 2>&1
exec 9> "$logs/.lock"
flock -n 9 || { echo "$(date -Is) another run is in progress"; exit 0; }

log() { echo "$(date -Is) $*"; }
trap 'log "FAILED (exit $?)"' EXIT

log "start, from $host"

# journald's cursor names the last entry we already have; the host is asked
# for everything after it and says where it stopped (the "-- cursor:" line).
after=
if [ -s "$cursor_file" ]; then
  after="--after-cursor='$(cat "$cursor_file")'"
fi
part=$logs/.partial/journal.jsonl.gz
ssh -o BatchMode=yes -o ConnectTimeout=30 "$host" \
  "journalctl -o json --no-pager --show-cursor $after | gzip -c" > "$part"
gzip -t "$part"

cursor=$(zcat "$part" | tail -n 1 | sed -n 's/^-- cursor: //p')
if [ -z "$cursor" ]; then
  rm -f "$part"
  log "nothing new"
else
  # Keep only the entries; the cursor line is not JSON.
  name=journal-$(date -u +%Y%m%dT%H%M%SZ).jsonl.gz
  zcat "$part" | grep -v '^-- cursor: ' | gzip -c > "$logs/$name"
  rm -f "$part"
  echo "$cursor" > "$cursor_file"
  entries=$(zcat "$logs/$name" | wc -l)
  alerts=$(zcat "$logs/$name" | grep -c '"SYSLOG_IDENTIFIER":"fortyfives-alert"' || true)
  log "saved $name: $entries entries, $alerts alert line(s), $(du -h "$logs/$name" | cut -f1)"
fi

find "$logs" -name 'journal-*.jsonl.gz' -mtime +400 -delete
log "done, $(find "$logs" -name 'journal-*.jsonl.gz' | wc -l) files, $(du -sh "$logs" | cut -f1)"
trap - EXIT
