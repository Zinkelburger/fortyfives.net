#!/bin/sh

# Initialize variables
host="localhost"
port="5432"
max_attempts=15
current_attempt=1

# Wait for Postgres to start
echo "Waiting for PostgreSQL to start..."

while ! pg_isready -h "$host" -p "$port" -q; do
  current_attempt=$(( current_attempt + 1 ))
  if [ "$current_attempt" -gt "$max_attempts" ]; then
    echo "Unable to connect to PostgreSQL after $max_attempts attempts. Exiting."
    exit 1
  fi

  echo "Attempt $current_attempt of $max_attempts. Waiting..."
  sleep 5
done

echo "PostgreSQL is up and running!"

# Run migrations
mix ecto.migrate

# Start the Phoenix server
exec mix phx.server
