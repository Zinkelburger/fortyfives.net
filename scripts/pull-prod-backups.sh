#!/bin/sh
# Copies production's newest SQLite backup into a restic repository on this
# machine, so losing the Contabo host does not lose the data too. Run weekly
# by anacron (see deploy/contabo/README.md); safe to run by hand any time.
#
#   scripts/pull-prod-backups.sh [ssh-host]   (default: twic-vps)
#
# restic stores each piece of data once, so a weekly snapshot only adds what
# changed (mostly new replays, which the app already gzips) instead of another
# full copy. Snapshots: one per week for a year, one per month for five years.
# Production keeps replays for 60 days, so every replay is in some kept
# snapshot. The repository has no password; this disk is encrypted.
#
# Restore: restic -r ~/Backups/fortyfives.net/restic --insecure-no-password \
#            restore latest --target /tmp/restore
# Progress and failures go to ~/Backups/fortyfives.net/pull.log.
set -eu
host=${1:-twic-vps}
remote=/var/lib/docker/volumes/fortyfives_sqlite_backups/_data
dest=${FORTYFIVES_BACKUP_DIR:-$HOME/Backups/fortyfives.net}
export RESTIC_REPOSITORY="$dest/restic"
restic() { command restic --insecure-no-password -q "$@"; }

mkdir -p "$dest/.partial"
chmod 700 "$dest"
exec >> "$dest/pull.log" 2>&1
exec 9> "$dest/.lock"
flock -n 9 || { echo "$(date -Is) another run is in progress"; exit 0; }

log() { echo "$(date -Is) $*"; }
trap 'log "FAILED (exit $?)"' EXIT

log "start, from $host"
[ -d "$RESTIC_REPOSITORY" ] || restic init

# Daily backups only (not the pre-release copies); names sort by time.
name=$(ssh -o BatchMode=yes -o ConnectTimeout=30 "$host" \
  "cd $remote && ls -1 fortyfives-2*.db | sort | tail -n 1")

if restic snapshots --tag "$name" --json | grep -q '"id"'; then
  log "$name already saved"
else
  # Always the same path, so restic treats each run as the next version.
  file="$dest/.partial/fortyfives.db"
  rsync -tz --partial -e "ssh -o BatchMode=yes" "$host:$remote/$name" "$file"
  # immutable=1: read without creating -wal/-shm files next to it.
  check=$(sqlite3 "file:$file?immutable=1" "PRAGMA integrity_check")
  [ "$check" = ok ] || { log "integrity check failed for $name: $check"; exit 1; }
  restic backup --host fortyfives.net --tag "$name" \
    --time "$(date -d @"$(stat -c %Y "$file")" '+%F %T')" "$file"
  rm -f "$file"
  log "saved $name"
fi

restic forget --host fortyfives.net --keep-weekly 52 --keep-monthly 60 --prune
log "done, $(restic snapshots --json | grep -o '"id"' | wc -l) snapshots, $(du -sh "$RESTIC_REPOSITORY" | cut -f1)"
trap - EXIT
