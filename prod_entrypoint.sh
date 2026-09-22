#!/bin/bash
# Release entrypoint: wait for Postgres, run migrations, start the server.
set -euo pipefail

host="${DATABASE_HOST:-}"
port="${DATABASE_PORT:-5432}"

# Derive the host/port from DATABASE_URL (ecto://user:pass@host:port/db) when
# DATABASE_HOST is not set explicitly.
if [ -z "$host" ] && [ -n "${DATABASE_URL:-}" ]; then
  hostport="${DATABASE_URL#*@}"
  hostport="${hostport%%/*}"
  host="${hostport%%:*}"
  case "$hostport" in
    *:*) port="${hostport##*:}" ;;
  esac
fi
host="${host:-db}"

max_attempts=15
attempt=1

echo "Waiting for PostgreSQL at ${host}:${port}..."
until pg_isready -h "$host" -p "$port" -q; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt "$max_attempts" ]; then
    echo "Unable to connect to PostgreSQL after $max_attempts attempts. Exiting."
    exit 1
  fi
  echo "Attempt $attempt of $max_attempts. Waiting..."
  sleep 5
done
echo "PostgreSQL is up and running!"

cd /app

# Prefer the release overlays from rel/overlays/bin; fall back to the raw
# release commands if the image was built without them.
if [ -x /app/bin/migrate ]; then
  /app/bin/migrate
else
  /app/bin/website_45s_v3 eval "Website45sV3.Release.migrate"
fi

if [ -x /app/bin/server ]; then
  exec /app/bin/server
else
  PHX_SERVER=true exec /app/bin/website_45s_v3 start
fi
