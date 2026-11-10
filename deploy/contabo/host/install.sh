#!/bin/sh
# Sets up auditing, alerting and the baseline hardening on the host. Runs on
# the host as root, from a copy of this directory; `apply.sh` sends it there.
# Safe to run again: every step checks before it changes anything, and a
# second run on an up-to-date host changes nothing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
files=$here/files
state=/var/lib/fortyfives
conf=/etc/fortyfives
site=/home/fortyfives

say() { echo "[host] $*"; }

# put <path under files/> <mode>: installs the file when it differs.
# Returns 0 when it changed something.
put() {
  if cmp -s "$files/$1" "/$1"; then return 1; fi
  install -D -m "$2" "$files/$1" "/$1"
  say "installed /$1"
}

# --- Packages ---------------------------------------------------------------
missing=
for pkg in auditd audispd-plugins fail2ban ufw unattended-upgrades; do
  dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
done
if [ -n "$missing" ]; then
  say "installing$missing"
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing
fi

# --- auditd -----------------------------------------------------------------
# Ten 50 MB files; the host writes a few MB a day.
audit_changed=
set_conf() { # <file> <key> <value>
  grep -Eq "^$2 = $3\$" "$1" && return 0
  if grep -Eq "^$2 *=" "$1"; then
    sed -i "s|^$2 *=.*|$2 = $3|" "$1"
  else
    echo "$2 = $3" >> "$1"
  fi
  audit_changed=1
  say "$(basename "$1"): $2 = $3"
}
set_conf /etc/audit/auditd.conf max_log_file 50
set_conf /etc/audit/auditd.conf num_logs 10
# Forward every record to syslog, so it lands in journald as well and leaves
# the host with the journal (scripts/pull-prod-logs.sh).
set_conf /etc/audit/plugins.d/syslog.conf active yes

put etc/audit/rules.d/50-fortyfives.rules 640 && audit_changed=1
systemctl enable -q auditd
systemctl is-active -q auditd || systemctl start auditd
if [ -n "$audit_changed" ]; then
  augenrules --load >/dev/null
  systemctl reload auditd 2>/dev/null || systemctl restart auditd
  say "audit rules loaded: $(auditctl -l | wc -l)"
fi

# --- journald ---------------------------------------------------------------
if put etc/systemd/journald.conf.d/50-fortyfives.conf 644; then
  systemctl restart systemd-journald
fi

# --- SSH, firewall, fail2ban, updates ----------------------------------------
if put etc/ssh/sshd_config.d/00-hardening.conf 644; then
  sshd -t && systemctl reload ssh
fi
for port in 22 80 443; do
  ufw status | grep -Eq "^$port/tcp +ALLOW" || ufw allow "$port/tcp" >/dev/null
done
ufw status | grep -q '^Status: active' || ufw --force enable >/dev/null
for unit in fail2ban unattended-upgrades; do
  systemctl is-enabled -q "$unit" 2>/dev/null || systemctl enable -q "$unit"
  systemctl is-active -q "$unit" || systemctl start "$unit"
done

# --- Alerts -----------------------------------------------------------------
mkdir -p "$state" "$conf"
chmod 700 "$state" "$conf"
put usr/local/sbin/fortyfives-alert 755 || true
put usr/local/sbin/fortyfives-login-alert 755 || true
put usr/local/sbin/fortyfives-host-check 755 || true

# Alerts go to the site's admin accounts (ADMIN_USER_IDS in the site's .env)
# unless /etc/fortyfives/alert.env already names someone.
if ! grep -q '^ALERT_TO=.' "$conf/alert.env" 2>/dev/null; then
  ids=$(sed -n 's/^ADMIN_USER_IDS=//p' "$site/.env" 2>/dev/null | tail -n 1 | tr -d '"'"'"' ')
  to=
  if echo "$ids" | grep -Eq '^[0-9]+(,[0-9]+)*$'; then
    to=$(docker exec fortyfives-db_backup-1 sh -c \
      "sqlite3 \"file:\$DATABASE_PATH?mode=ro\" \"select group_concat(email, ', ') from users where id in ($ids)\"" \
      2>/dev/null || true)
  fi
  umask 077
  echo "ALERT_TO=\"$to\"" > "$conf/alert.env"
  if [ -n "$to" ]; then
    say "alerts will be emailed to the site's admin account(s)"
  else
    say "NO ALERT ADDRESS: set ALERT_TO in $conf/alert.env (alerts only reach journald until then)"
  fi
fi

# Addresses that have already logged in do not alert.
if [ ! -e "$state/ssh-known-sources" ]; then
  journalctl -u ssh -o cat --no-pager 2>/dev/null |
    sed -n 's/^Accepted [a-z]* for [^ ]* from \([^ ]*\) port.*/\1/p' |
    sort -u > "$state/ssh-known-sources"
  say "known SSH addresses: $(wc -l < "$state/ssh-known-sources")"
fi
# The key list the daily check compares against.
sha256sum /root/.ssh/authorized_keys > "$state/authorized_keys.sha256"

pam_line='session    optional     pam_exec.so quiet /usr/local/sbin/fortyfives-login-alert'
if ! grep -q fortyfives-login-alert /etc/pam.d/sshd; then
  cp -p /etc/pam.d/sshd "$state/pam.d-sshd.before"
  printf '\n# Alert on a login from an address not seen before (deploy/contabo/host).\n%s\n' \
    "$pam_line" >> /etc/pam.d/sshd
  say "added the login alert to /etc/pam.d/sshd (previous file: $state/pam.d-sshd.before)"
fi

# --- Daily check ------------------------------------------------------------
units_changed=
put etc/systemd/system/fortyfives-host-check.service 644 && units_changed=1
put etc/systemd/system/fortyfives-host-check.timer 644 && units_changed=1
[ -z "$units_changed" ] || systemctl daemon-reload
systemctl is-enabled -q fortyfives-host-check.timer 2>/dev/null ||
  systemctl enable -q --now fortyfives-host-check.timer

say "done"
/usr/local/sbin/fortyfives-host-check --print
