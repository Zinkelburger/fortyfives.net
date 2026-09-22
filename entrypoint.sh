#!/bin/bash
# Development (Mix) entrypoint: wait for Postgres, migrate, run phx.server.
set -euo pipefail

host="${DATABASE_HOST:-localhost}"
port="${DATABASE_PORT:-5432}"
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

# Create the database if needed, then migrate and start the server.
mix ecto.create --quiet
mix ecto.migrate
exec mix phx.server
