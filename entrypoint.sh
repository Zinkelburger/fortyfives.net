#!/bin/bash
set -euo pipefail
mix ecto.create --quiet
mix ecto.migrate
exec mix phx.server
