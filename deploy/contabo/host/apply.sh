#!/bin/sh
# Applies this directory to the host: auditd and its rules, journald
# retention, SSH hardening, firewall, fail2ban, the alert scripts and the
# daily host check. See "Auditing and alerts" in ../README.md.
#
#   deploy/contabo/host/apply.sh [ssh-host]   (default: twic-vps)
#
# Safe to run again; a second run changes nothing. Run it after editing
# anything under files/, after deliberately changing root's authorized_keys,
# and on a rebuilt host once the site is up.
set -eu
host=${1:-twic-vps}
here=$(cd "$(dirname "$0")" && pwd)

tar -C "$here" -cf - install.sh files | ssh "$host" '
  dir=$(mktemp -d) && tar -xf - -C "$dir" && sh "$dir/install.sh"
  status=$?
  rm -rf "$dir"
  exit $status'
