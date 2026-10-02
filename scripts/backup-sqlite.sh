#!/bin/sh
# SQLite's online backup includes committed WAL data, unlike copying the file.
set -eu
umask 077
mkdir -p /backups
trap 'exit 0' TERM INT
while :; do
  if [ ! -f "$DATABASE_PATH" ]; then
    sleep 10 & wait $!
    continue
  fi
  if [ -f "$DATABASE_PATH" ]; then
    target="/backups/fortyfives-$(date -u +%Y%m%dT%H%M%SZ).db"
    sqlite3 "$DATABASE_PATH" ".timeout 30000" ".backup '$target.tmp'"
    test "$(sqlite3 "$target.tmp" 'PRAGMA integrity_check')" = ok
    mv "$target.tmp" "$target"
    echo "Verified backup: $target"
    find /backups -name 'fortyfives-*.db' -mtime +14 -delete
  fi
  sleep 86400 & wait $!
done
