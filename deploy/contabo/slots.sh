#!/usr/bin/env bash
# Blue/green switching, run in the compose project directory on the host
# (/home/fortyfives; release.sh sends this script over ssh). The local test
# (deploy/contabo/test/run.sh) runs it against a copy of the project.
#
#   slots.sh state               live and draining slot, image and games of each
#   slots.sh live                "<live slot> <its image>"
#   slots.sh start IMAGE         run IMAGE in the idle slot; wait until it answers
#   slots.sh switch              nginx sends new visitors to the other running slot;
#                                the old one drains (its games go on, its other
#                                pages reload onto the new slot)
#   slots.sh wait MINUTES        until the draining slot has no games (exit 3 if not)
#   slots.sh retire [--force]    stop the draining slot (or an idle running one);
#                                refuses while it has games unless --force
#   slots.sh take-compose FILE   install FILE as docker-compose.yml, keeping the
#                                current images and scales of the slots and db_backup
#   slots.sh rpc SLOT EXPR       run Elixir in a slot
#
# The live slot is the default in nginx/slot/live.conf; a slot is idle when
# it is not running (scale 0). Environment: COMPOSE (default "docker compose").
set -euo pipefail

COMPOSE=${COMPOSE:-docker compose}
file=docker-compose.yml
map=nginx/slot/live.conf

die() { echo "slots.sh: $*" >&2; exit 1; }
compose() { $COMPOSE "$@" </dev/null; }
other() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }

# --- state -----------------------------------------------------------------

header() { sed -n 's/^# live=\([a-z]*\) draining=\([a-z-]*\)$/\1 \2/p' "$map"; }
live() { local h; h=$(header); [ -n "$h" ] || die "$map has no '# live=... draining=...' line"; echo "${h% *}"; }
draining() { local h; h=$(header); h=${h#* }; [ "$h" = - ] || echo "$h"; }

get_key() { # <service> <key>: the value in docker-compose.yml
  awk -v svc="  $1:" -v key="    $2:" '
    /^  [^ #][^:]*:/ { in_svc = ($0 == svc) }
    in_svc && index($0, key) == 1 { sub(/^ *[^:]*: */, ""); print; exit }' "${3:-$file}"
}

set_key() { # <service> <key> <value> [file]: rewrites one line in place
  local f=${4:-$file}
  awk -v svc="  $1:" -v key="    $2:" -v val="$3" '
    /^  [^ #][^:]*:/ { in_svc = ($0 == svc) }
    in_svc && index($0, key) == 1 { print key " " val; found = 1; next }
    { print }
    END { if (!found) exit 1 }' "$f" > "$f.tmp" || { rm -f "$f.tmp"; die "no '$2:' line under $1 in $f"; }
  cat "$f.tmp" > "$f"
  rm -f "$f.tmp"
}

running() { [ -n "$(compose ps -q --status running "web-$1" 2>/dev/null)" ]; }

rpc() { compose exec -T "web-$1" bin/website_45s_v3 rpc "$2"; }

answers() { [ "$(compose exec -T "web-$1" wget -qO- http://127.0.0.1:4000/healthz 2>/dev/null)" = ok ]; }

slot_status() { # "<games> <queued> <live|draining>", empty if the slot does not answer
  local s
  s=$(rpc "$1" 'IO.write(Website45sV3.Slot.status())' 2>/dev/null) || return 0
  [[ $s =~ ^[0-9]+\ [0-9]+\ (live|draining)$ ]] && echo "$s"
}

write_map() { # <live> [draining]: rewrites live.conf and reloads nginx
  local before
  before=$(cat "$map")
  {
    echo "# Written by deploy/contabo/slots.sh. A browser that a draining slot"
    echo "# served stays there (ff_slot cookie); X-FF-Slot picks a slot."
    echo "# live=$1 draining=${2:--}"
    echo 'map "$http_x_ff_slot:$cookie_ff_slot" $ff_upstream {'
    echo "    default web-$1;"
    echo '    "~^blue:" web-blue;'
    echo '    "~^green:" web-green;'
    [ -z "${2:-}" ] || echo "    \"~^:$2\$\" web-$2;"
    echo '}'
  } > "$map.tmp"
  cat "$map.tmp" > "$map"
  rm -f "$map.tmp"
  if ! out=$(compose exec -T nginx nginx -t 2>&1); then
    printf '%s\n' "$before" > "$map"
    die "nginx rejected the new $map (put the old one back): $out"
  fi
  reload_nginx
}

reload_nginx() {
  compose exec -T nginx nginx -s reload >/dev/null 2>&1 || die "nginx -s reload failed"
  # Workers from before the reload finish the requests they hold with the
  # old map; give them a moment before anything depends on the new one.
  sleep 2
}

# --- commands --------------------------------------------------------------

cmd_state() {
  local l d s img
  l=$(live); d=$(draining)
  echo "live=$l draining=${d:--}"
  for s in blue green; do
    img=$(get_key "web-$s" image)
    if running "$s"; then
      echo "$s: running ${img} ($(slot_status "$s" || true))"
    else
      echo "$s: stopped (last image ${img})"
    fi
  done
}

cmd_start() {
  local image=${1:?image} l idle start
  l=$(live); idle=$(other "$l")
  [ "$(draining)" != "$idle" ] || die "$idle is still draining; 'slots.sh wait' and 'slots.sh retire' first"
  running "$l" || die "the live slot $l is not running"
  cp -p "$file" "$file.before-start"
  set_key "web-$idle" image "$image"
  set_key "web-$idle" scale 1
  echo "starting $idle on $image"
  if ! out=$(compose up -d --no-deps "web-$idle" 2>&1); then
    echo "$out" | tail -15
    fail_start "$idle" "docker compose up failed"
  fi
  start=$(date +%s)
  until answers "$idle"; do
    if [ $(( $(date +%s) - start )) -ge 180 ]; then
      compose logs --tail 30 "web-$idle" || true
      fail_start "$idle" "$idle did not answer /healthz within 180 s"
    fi
    sleep 2
  done
  echo "$idle answers /healthz after $(( $(date +%s) - start )) s"
  rm -f "$file.before-start"
  # nginx looks the new container up every 10 s; a reload does it now, so
  # X-FF-Slot reaches it at once.
  reload_nginx
}

fail_start() { # <slot> <reason>: stops the slot and puts the compose file back
  compose stop "web-$1" >/dev/null 2>&1 || true
  compose rm -f "web-$1" >/dev/null 2>&1 || true
  mv "$file.before-start" "$file"
  die "$2; stopped $1 again, the live slot was not touched"
}

cmd_switch() {
  local l new s
  l=$(live); new=$(other "$l")
  running "$new" && answers "$new" || die "$new is not running and answering; nothing switched"
  # A rollback flips back to a slot that was draining.
  s=$(rpc "$new" 'IO.write(Website45sV3.Slot.undrain())') || die "$new did not answer rpc; nothing switched"
  if running "$l"; then
    write_map "$new" "$l"
    echo "nginx: new visitors go to $new ($s); $l drains"
    if s=$(rpc "$l" 'IO.write(Website45sV3.Slot.drain())'); then
      echo "$l: $s"
    else
      echo "WARNING: $l did not take the drain call; its pages stay there until it is retired"
    fi
  else
    write_map "$new"
    echo "nginx: everyone goes to $new ($s); $l was not running"
  fi
}

cmd_wait() {
  local minutes=${1:?minutes} d start s last="" fails=0
  d=$(draining)
  [ -n "$d" ] || { echo "nothing is draining"; return; }
  running "$d" || { echo "$d is not running"; return; }
  start=$(date +%s)
  while :; do
    s=$(slot_status "$d")
    if [ -n "$s" ]; then
      fails=0
      [ "${s%% *}" = 0 ] && { echo "$d has no games left"; return; }
      [ "${s%% *}" = "$last" ] || echo "$(date -u +%H:%M:%S) $d: ${s%% *} game(s) still running"
      last=${s%% *}
    else
      fails=$((fails + 1))
      [ $fails -lt 6 ] || die "$d does not answer rpc"
    fi
    if [ $(( $(date +%s) - start )) -ge $(( minutes * 60 )) ]; then
      echo "$d still has ${last:-?} game(s) after $minutes minutes"
      exit 3
    fi
    sleep 10
  done
}

cmd_retire() {
  local force=0 l d s img
  [ "${1:-}" != --force ] || force=1
  l=$(live); d=$(draining)
  [ -n "$d" ] || d=$(other "$l")
  if running "$d"; then
    s=$(slot_status "$d")
    if [ -n "$s" ] && [ "${s%% *}" != 0 ] && [ $force = 0 ]; then
      die "$d still has ${s%% *} game(s); 'slots.sh wait', or retire --force to end them"
    fi
  fi
  [ -z "$(draining)" ] || write_map "$l"
  set_key "web-$d" scale 0
  compose stop "web-$d" >/dev/null 2>&1 || true
  compose rm -f "web-$d" >/dev/null 2>&1 || true
  echo "$d stopped; $l serves everyone"
  img=$(get_key "web-$l" image)
  if [ "$(get_key db_backup image)" != "$img" ]; then
    set_key db_backup image "$img"
    compose up -d --no-deps db_backup >/dev/null 2>&1 || die "db_backup did not start on $img"
    echo "db_backup now on the live image"
  fi
}

cmd_take_compose() { # <file>: the repo's compose file, with the host's images and scales
  local new=${1:?file} svc key
  [ -s "$new" ] || die "$new is empty"
  for svc in web-blue web-green db_backup; do
    for key in image scale; do
      [ "$svc/$key" != db_backup/scale ] || continue
      set_key "$svc" "$key" "$(get_key "$svc" "$key")" "$new"
    done
  done
  compose -f "$new" config -q || die "$new does not pass 'docker compose config'"
  cat "$new" > "$file"
  rm -f "$new"
  echo "installed the new docker-compose.yml (images and scales kept)"
}

case ${1:-} in
  state) cmd_state ;;
  live) l=$(live); echo "$l $(get_key "web-$l" image)" ;;
  start) shift; cmd_start "$@" ;;
  switch) cmd_switch ;;
  wait) shift; cmd_wait "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  take-compose) shift; cmd_take_compose "$@" ;;
  rpc) shift; rpc "$@" ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
