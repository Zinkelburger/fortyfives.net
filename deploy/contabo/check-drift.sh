#!/bin/sh
# Compares this directory with what is deployed on the Contabo host.
# Read-only on the host; .env is compared by key names, never values.
#
#   deploy/contabo/check-drift.sh [ssh-host]   (default: twic-vps)
#
# Exits non-zero when anything differs. After a deliberate change on the
# host, copy the file back here (or update env.keys) and commit it.
set -u
host=${1:-twic-vps}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
remote=/home/fortyfives
status=0

compare() { # <remote path> <local path>
  if ssh "$host" "cat $remote/$1" | diff -u --label "host:$1" --label "repo:${2#"$repo"/}" - "$2"; then
    echo "same: $1"
  else
    status=1
  fi
}

keys() { grep -E '^[A-Z_]+=' | sed 's/=.*//'; }

compare docker-compose.yml "$here/docker-compose.yml"
compare nginx/conf.d/site.conf "$here/nginx/conf.d/site.conf"
compare scripts/backup-sqlite.sh "$repo/scripts/backup-sqlite.sh"

# certbot rewrites its version and ACME renewal-info timestamps on every run;
# only the renewal parameters are ours.
params() { sed -n '/^\[renewalparams\]/,/^\[acme_renewal_info\]/p'; }
renewal=/etc/letsencrypt/renewal/fortyfives.net.conf
local_params=$(mktemp)
params < "$here/letsencrypt/renewal/fortyfives.net.conf" > "$local_params"
if ssh "$host" "cat $renewal" | params | diff -u --label "host:$renewal" --label "repo:letsencrypt/renewal" - "$local_params"; then
  echo "same: $renewal"
else
  status=1
fi
rm -f "$local_params"

if [ "$(ssh "$host" "docker inspect -f '{{.State.Running}}' fortyfives-certbot-1")" = true ]; then
  echo "running: certbot"
else
  echo "NOT RUNNING: certbot (nothing else renews the TLS certificate)"
  status=1
fi

local_keys=$(mktemp)
trap 'rm -f "$local_keys"' EXIT
keys < "$here/env.keys" > "$local_keys"
if ssh "$host" "cat $remote/.env" | keys | diff -u --label "host:.env keys" --label "repo:env.keys" - "$local_keys"; then
  echo "same: .env keys"
else
  status=1
fi

exit $status
