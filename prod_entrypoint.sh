#!/bin/sh

# Initialize variables
host="db"
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

# Change to the release directory
cd /app || exit

# Run migrations
/app/bin/website_45s_v3 eval "Website45sV3.Release.migrate"

# Start the Phoenix server
exec /app/bin/website_45s_v3 start
