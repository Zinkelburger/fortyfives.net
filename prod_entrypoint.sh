#!/bin/bash
set -euo pipefail
: "${DATABASE_PATH:?Set DATABASE_PATH to the persistent SQLite file}"
cd /app
/app/bin/migrate
exec /app/bin/server
