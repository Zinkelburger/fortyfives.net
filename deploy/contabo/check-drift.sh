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

# Auditing, alerting and hardening (host/apply.sh installs these).
for file in $(cd "$here/host/files" && find . -type f | sed 's|^\./||' | sort); do
  if ssh "$host" "cat /$file" | diff -u --label "host:/$file" --label "repo:deploy/contabo/host/files/$file" - "$here/host/files/$file"; then
    echo "same: /$file"
  else
    status=1
  fi
done

host_state() { # <what> <command that prints "ok" when fine>
  if [ "$(ssh "$host" "$2" 2>/dev/null)" = ok ]; then
    echo "ok: $1"
  else
    echo "NOT OK: $1 (rerun deploy/contabo/host/apply.sh)"
    status=1
  fi
}
host_state "auditd running with the exec rules" \
  'systemctl is-active -q auditd && auditctl -l | grep -q "key=exec" && echo ok'
host_state "audit records forwarded to journald" \
  'grep -q "^active = yes" /etc/audit/plugins.d/syslog.conf && echo ok'
host_state "login alert in /etc/pam.d/sshd" \
  'grep -q "pam_exec.so quiet /usr/local/sbin/fortyfives-login-alert" /etc/pam.d/sshd && echo ok'
host_state "daily host check timer" \
  'systemctl is-active -q fortyfives-host-check.timer && echo ok'
host_state "alert address set" \
  'grep -q "^ALERT_TO=.\+@" /etc/fortyfives/alert.env && echo ok'

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
