#!/usr/bin/env bash
# Releases fortyfives.net to the Contabo host. Run from anywhere in the repo.
#
#   release.sh status                     what prod runs, games in progress, unreleased commits
#   release.sh tag [vX] [--no-ci-wait]    tag origin/main once its CI passed; waits for the image
#   release.sh deploy vX [options]        put image vX live (see "deploy options" below)
#   release.sh finish vX [--co-author "Name <email>"]
#                                         commit docs/releases/vX.md + compose + slot map, push
#   release.sh rollback vX [--now]        go back to the image before vX
#   release.sh restart                    the live image again in the other slot (picks up
#                                         .env changes without stopping anyone's game)
#
# Prod runs blue/green (deploy/contabo/slots.sh): `deploy` starts vX in the
# idle slot, checks it through nginx, switches, then waits for the games on
# the old slot to end before stopping it. Nobody waits for idle tables and
# the site never answers 502.
#
# deploy options:
#   --wait MIN       wait up to MIN minutes for the old slot's games (default 60)
#   --dry-run        check everything (tag, image, compose files, migrations) and stop
#   --push-compose   the repo's docker-compose.yml has changes the host lacks
#                    (e.g. a new environment variable): upload it, keeping the
#                    host's images and scales
#   --migrations-ok  vX adds database migrations and they are safe for the old
#                    version, which keeps running on the same database until its
#                    games end (add columns or tables; never rename or drop)
#
# Typical release: `release.sh tag && release.sh deploy vX`, then fill in the
# "Changes" part of docs/releases/vX.md and `release.sh finish vX`.
# `tag` waits for CI (about 10 minutes) and `deploy` for the old slot's
# games, so run them in the background when calling from an agent with a
# command timeout.
#
# Every step can be run again after it was cut short: `tag vX` waits again
# for vX's image, `deploy vX` picks up where it stopped (start, switch, wait,
# stop the old slot, record). A non-zero exit always means "not done"; the
# last lines say why and what to run next.
#
# Environment: FF_HOST (ssh host, default twic-vps), FF_SITE (default
# https://fortyfives.net).
set -euo pipefail

host=${FF_HOST:-twic-vps}
site=${FF_SITE:-https://fortyfives.net}
remote=/home/fortyfives
image=docker.io/thwar/fortyfives.net
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
compose="$here/docker-compose.yml"
slotmap="$here/nginx/slot/live.conf"
cd "$repo"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "needs $1"; }
ssh() { command ssh -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$@"; }
other() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }

slots() { # runs deploy/contabo/slots.sh on the host; arguments must be plain words
  ssh "$host" "cd $remote && bash -s -- $*" < "$here/slots.sh"
}

live() { # "<slot> <image>" of the live slot
  local l
  l=$(slots live) || return 1
  [[ $l =~ ^(blue|green)\ $image@sha256:[0-9a-f]{64}$ ]] || { echo "unexpected live slot: $l" >&2; return 1; }
  echo "$l"
}

copy_back() { # host's docker-compose.yml and slot map -> the repo copies
  if ssh "$host" "cat $remote/docker-compose.yml" > "$tmp/compose.host" && [ -s "$tmp/compose.host" ] &&
    ssh "$host" "cat $remote/nginx/slot/live.conf" > "$tmp/map.host" && [ -s "$tmp/map.host" ]; then
    cat "$tmp/compose.host" > "$compose"
    cat "$tmp/map.host" > "$slotmap"
  else
    die "could not read the host's docker-compose.yml or slot map; the repo copies are unchanged. Run the same command again."
  fi
}

digest_of() { # <tag> -> sha256:..., empty if the tag has no image yet
  skopeo inspect --raw "docker://$image:$1" 2>/dev/null | sha256sum | awk '{print "sha256:" $1}' |
    grep -v e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 || true
}

tag_of() { # <image@digest> -> the newest of the last 10 tags built as it, or empty
  local t
  for t in $(git tag --sort=-v:refname -l 'v*' | sed -n 1,10p); do
    if [ "$image@$(digest_of "$t")" = "$1" ]; then echo "$t"; return; fi
  done
}

newest_tag() { git tag --sort=-v:refname -l 'v*' | sed -n 1p; }

is_skip_ci() { # <commit>: GitHub starts no workflow for it, not even for a tag on it
  grep -qE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]' <<<"$(git log -1 --format=%B "$1")"
}

check_version() { [[ ${1:-} =~ ^v[0-9]+(\.[0-9]+)+$ ]] || die "expected a version like v2.0.1.33, got '${1:-}'"; }

# --- status --------------------------------------------------------------

cmd_status() {
  need skopeo
  local l slot cur tag pending
  git fetch -q --tags origin
  slots state
  l=$(live) || die "could not read the live slot"
  slot=${l% *}; cur=${l#* }
  tag=$(tag_of "$cur")
  echo "prod:     ${tag:-unknown tag} on $slot (${cur#*@sha256:})"
  echo "newest:   $(newest_tag)"
  if [ -n "$tag" ]; then
    pending=$(git log --format='  %h %s' "$tag..origin/main" | grep -v 'skip ci' || true)
    if [ -n "$pending" ]; then echo "on main, not released:"; echo "$pending"; else echo "main has nothing unreleased"; fi
  fi
}

# --- tag -----------------------------------------------------------------

ci_wait() { # <sha>: waits for the push/PR workflows on this commit, fails if any failed
  local sha=$1 start rows pending failed
  start=$(date +%s)
  say "Waiting for CI on ${sha:0:7}"
  while :; do
    rows=$(gh run list --commit "$sha" --limit 50 \
      --json databaseId,workflowName,status,conclusion,event,createdAt -q '
        [.[] | select(.event == "push" or .event == "pull_request")
             | select(.workflowName | test("Build and Push") | not)]
        | group_by(.workflowName) | map(max_by(.createdAt)) | .[]
        | "\(.databaseId)\t\(.status)\t\(.conclusion)\t\(.workflowName)"')
    if [ -z "$rows" ]; then
      [ $(( $(date +%s) - start )) -lt 180 ] ||
        die "no CI runs found for ${sha:0:7}. CI only runs on the newest commit of a push, and not at all when that one is [skip ci]; push a new commit on top and tag again."
    else
      pending=$(awk -F'\t' '$2 != "completed"' <<<"$rows")
      if [ -z "$pending" ]; then
        failed=$(awk -F'\t' '$3 != "success" && $3 != "skipped" && $3 != "neutral"' <<<"$rows")
        if [ -n "$failed" ]; then
          echo "Failed:"; awk -F'\t' '{print "  " $4 " (run " $1 "): " $3}' <<<"$failed"
          echo "If it is the flaky e2e, rerun with: gh run rerun <run> --failed, then tag again."
          exit 1
        fi
        awk -F'\t' '{print "  ok: " $4}' <<<"$rows"
        return
      fi
    fi
    [ $(( $(date +%s) - start )) -lt 2400 ] || die "CI still running after 40 minutes"
    sleep 20
  done
}

cmd_tag() {
  need gh; need skopeo
  local v="" wait_ci=1 sha last run="" skipped=0 ahead digest state start
  while [ $# -gt 0 ]; do
    case $1 in
      --no-ci-wait) wait_ci=0 ;;
      v*) v=$1 ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  git fetch -q --tags origin
  last=$(newest_tag)

  if [ -n "$v" ] && git rev-parse -q --verify "refs/tags/$v" >/dev/null; then
    # An earlier `tag` got as far as creating the tag before it was cut short.
    check_version "$v"
    digest=$(digest_of "$v")
    if [ -n "$digest" ]; then
      echo "$v is already tagged and built: $image@$digest"
      echo "Next: deploy/contabo/release.sh deploy $v"
      return
    fi
    echo "$v is already tagged ($(git log -1 --format='%h %s' "$v^{commit}")); waiting for its image"
    git ls-remote --exit-code --tags origin "refs/tags/$v" >/dev/null 2>&1 || git push -q origin "$v"
  else
    # A tag on a [skip ci] commit builds no image, so tag the newest commit
    # below the release records.
    sha=$(git rev-parse origin/main)
    while is_skip_ci "$sha"; do
      skipped=$((skipped + 1))
      sha=$(git rev-parse -q --verify "$sha^") || die "every commit on origin/main is [skip ci]"
    done
    if [ -n "$last" ] && git merge-base --is-ancestor "$sha" "$last^{commit}"; then
      die "nothing new on origin/main since $last. (To wait again for $last's image: release.sh tag $last)"
    fi
    if [ -z "$v" ]; then
      [ -n "$last" ] || die "no v* tag yet; pass the version"
      v=${last%.*}.$(( 10#${last##*.} + 1 ))
    fi
    check_version "$v"
    echo "Tagging $(git log -1 --format='%h %s' "$sha") as $v (previous: ${last:-none})"
    [ $skipped = 0 ] || echo "  $skipped [skip ci] commit(s) above it on origin/main are not in the image"
    ahead=$(git rev-list --count origin/main..HEAD)
    [ "$ahead" = 0 ] || echo "  note: $ahead local commit(s) are not on origin/main and not in this release"
    [ $wait_ci = 0 ] || ci_wait "$sha"
    git tag -a "$v" -m "$v" "$sha"
    git push -q origin "$v"
  fi

  say "Waiting for the image build"
  for _ in $(seq 1 30); do
    run=$(gh run list --workflow build-and-push.yml --limit 10 --json databaseId,headBranch \
      -q "[.[] | select(.headBranch == \"$v\")][0].databaseId // empty") || run=""
    [ -n "$run" ] && break
    sleep 10
  done
  [ -n "$run" ] || die "no image build started for $v. Check: gh run list --workflow build-and-push.yml. Then: release.sh tag $v"
  start=$(date +%s)
  while :; do
    state=$(gh run view "$run" --json status,conclusion -q '"\(.status) \(.conclusion)"') || state="unknown"
    case $state in
      "completed success") break ;;
      completed*) die "image build ended with '${state#completed }': gh run view $run --log-failed" ;;
    esac
    [ $(( $(date +%s) - start )) -lt 2400 ] || die "image build (run $run) still going after 40 minutes. Then: release.sh tag $v"
    sleep 15
  done
  for _ in $(seq 1 12); do
    digest=$(digest_of "$v")
    [ -n "$digest" ] && break
    sleep 5
  done
  [ -n "$digest" ] || die "the build passed but Docker Hub does not list $image:$v yet. In a minute: release.sh tag $v"
  echo "$image@$digest"
  echo "Next: deploy/contabo/release.sh deploy $v"
}

# --- deploy --------------------------------------------------------------

site_check() { # <slot> [--direct]: one line per check, "FAIL" in front of a bad one; returns 1 if any failed.
  # Without --direct each request carries X-FF-Slot, which nginx follows.
  local slot=$1 p code got body bad=0 hdr=()
  [ "${2:-}" = --direct ] || hdr=(-H "X-FF-Slot: $slot")
  for p in /healthz /healthz/auth / /play /analysis; do
    code=$(curl -s -D "$tmp/headers" -o "$tmp/body" -w '%{http_code}' --max-time 10 "${hdr[@]}" "$site$p" || true)
    got=$(tr -d '\r' < "$tmp/headers" | awk 'tolower($1) == "x-ff-slot:" {print $2}')
    body=$(head -c 300 "$tmp/body")
    if [ "$code" != 200 ] || [ "$got" != "$slot" ] ||
      { [ $p = /healthz ] && [ "$body" != ok ]; } ||
      { [ $p = /healthz/auth ] && ! grep -q '"status":"ok"' <<<"$body"; }; then
      echo "FAIL $p ${code:-no answer} from ${got:-no slot}${body:+: ${body:0:120}}"; bad=1
    else
      echo "$p 200 from $slot"
    fi
  done
  return $bad
}

write_notes() { # <version> <new image> <started> <activated> <retired> <log errors> <checks text>
  local v=$1 new=$2 started=${3%Z} activated=${4%Z} retired=${5%Z} errors=$6 checks=$7 notes prev commit
  notes="docs/releases/$v.md"
  [ -e "$notes" ] && { echo "$notes exists, not touching it"; return; }
  prev=$(git describe --tags --abbrev=0 "$v^" 2>/dev/null || true)
  commit=$(git rev-parse --short "$v^{commit}")
  {
    echo "# Release $v"
    echo
    echo "Application commit: \`$commit\`. Deployed on ${started%T*}: started ${started#*T},"
    echo "live from ${activated#*T}, old slot stopped ${retired#*T} UTC (blue/green)."
    echo
    echo "## Changes"
    echo
    echo "TODO: rewrite these commit subjects as the changes players and operators notice."
    echo
    git log --no-merges --format='- %s' "${prev:+$prev..}$v" | grep -v 'skip ci' || true
    echo
    echo "## Checks"
    echo
    echo "Image \`$new\`."
    echo "Pre-release backup \`/backups/fortyfives-pre-$v.db\` passed its"
    echo "integrity check; release record in \`backups/release-$v/\`."
    echo
    echo "Through nginx (\`release.sh deploy\`):"
    echo
    sed 's/^/- /' <<<"$checks"
    echo "- $errors error/warning line(s) in the new slot's log since the switch."
  } | sed 's/[[:space:]]*$//' > "$notes"
  echo "wrote $notes (fill in Changes)"
}

migrations_since() { # <old image> <version>: migration files vX adds over the old image's tag
  local old
  old=$(tag_of "$1")
  [ -n "$old" ] || old=$(git describe --tags --abbrev=0 "$2^" 2>/dev/null || true)
  [ -n "$old" ] || return 0
  git diff --name-only --diff-filter=A "$old" "$2" -- priv/repo/migrations
}

record() { ssh "$host" "R=$remote/backups/release-$1; $2"; }

cmd_deploy() {
  need skopeo
  local v="" wait_min=60 push=0 dry=0 mig_ok=0 digest new l slot cur idle state migs rc=0 checks
  while [ $# -gt 0 ]; do
    case $1 in
      --wait) wait_min=${2:?}; shift ;;
      --push-compose) push=1 ;;
      --dry-run) dry=1 ;;
      --migrations-ok) mig_ok=1 ;;
      v*) v=$1 ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  check_version "$v"
  git fetch -q --tags origin
  git rev-parse -q --verify "refs/tags/$v" >/dev/null || die "no tag $v (run: release.sh tag)"
  digest=$(digest_of "$v")
  [ -n "$digest" ] || die "no image for $v on Docker Hub yet (release.sh tag $v waits for it)"
  new=$image@$digest
  l=$(live) || die "could not read the live slot on the host"
  slot=${l% *}; cur=${l#* }; idle=$(other "$slot")
  state=$(record "$v" 'if [ -e $R/retired ]; then echo retired; elif [ -e $R/activated ]; then echo activated; elif [ -e $R/started ]; then echo started; else echo none; fi')

  if [ "$state" = retired ] || [ "$state" = activated ]; then
    [ "$cur" = "$new" ] || die "$v was deployed before and prod has since moved to another image (${cur#*@sha256:}). Tag a new version."
    echo "$v went live on $slot at $(record "$v" 'cat $R/activated')"
    [ $dry = 0 ] || { echo "dry run: nothing left to switch"; slots state; return; }
    finish_deploy "$v" "$new" "$slot" "$wait_min"
    return
  fi
  [ "$cur" != "$new" ] || die "prod already runs $v's image on $slot, but there is no record of deploying it (backups/release-$v). Look at the host by hand."

  echo "deploying $v to $idle: ${cur#*@sha256:} ($slot) -> ${digest#sha256:}"
  # The repo copy must match the host, or copying the host's file back
  # afterwards would lose repo edits.
  ssh "$host" "cat $remote/docker-compose.yml" > "$tmp/compose.before" && [ -s "$tmp/compose.before" ] ||
    die "could not read the host's docker-compose.yml"
  if ! diff -u --label host --label repo "$tmp/compose.before" "$compose"; then
    [ $push = 1 ] || die "deploy/contabo/docker-compose.yml differs from the host (diff above). Pass --push-compose to upload the repo's version (the host's images and scales are kept), or copy the host's back first."
  elif [ $push = 1 ]; then
    echo "repo and host compose files already match; --push-compose not needed"
    push=0
  fi

  migs=$(migrations_since "$cur" "$v")
  if [ -n "$migs" ]; then
    echo "$v adds migrations; the old version keeps using the database until its games end:"
    sed 's/^/  /' <<<"$migs"
    [ $mig_ok = 1 ] || die "check that the old version still works with them (new tables or columns are fine; renames, drops and new NOT NULL columns are not), then pass --migrations-ok"
  fi

  if [ $dry = 1 ]; then
    if [ $push = 1 ]; then
      ssh "$host" "cat > $remote/docker-compose.yml.dryrun" < "$compose"
      ssh "$host" "cd $remote && { docker compose -f docker-compose.yml.dryrun config -q; rc=\$?; rm -f docker-compose.yml.dryrun; exit \$rc; }" ||
        die "the repo's docker-compose.yml does not pass 'docker compose config' on the host"
      echo "the repo's docker-compose.yml is valid on the host"
    fi
    slots state
    echo "dry run: stopping before any change"
    return
  fi

  if [ "$state" = none ]; then
    say "Pulling the image and backing up"
    ssh "$host" "docker pull -q $new" >/dev/null
    ssh "$host" "V=$v NEW=$new CUR=$cur SLOT=$slot sh -s" <<'EOF' || die "the backup did not finish (reason above); nothing was changed. Run the same deploy again."
set -eu
umask 077
cd /home/fortyfives
R=backups/release-$V
mkdir -p -m 700 "$R"
cp -p docker-compose.yml "$R/docker-compose.before.yml"
cp -p nginx/slot/live.conf "$R/live.conf.before"
cp -p .env "$R/env.before"
echo "$CUR" > "$R/previous-image"
echo "$SLOT" > "$R/previous-slot"
echo "$NEW" > "$R/new-image"
ok=$(docker exec fortyfives-db_backup-1 sh -c "sqlite3 \"\$DATABASE_PATH\" '.timeout 30000' '.backup /backups/fortyfives-pre-$V.db' && sqlite3 /backups/fortyfives-pre-$V.db 'PRAGMA integrity_check'" </dev/null)
[ "$ok" = ok ] || { echo "backup integrity check: $ok"; exit 1; }
date -u +%Y-%m-%dT%H:%M:%SZ > "$R/started"
chmod 600 "$R"/*
echo "backup /backups/fortyfives-pre-$V.db ok"
EOF
  fi

  if [ $push = 1 ]; then
    ssh "$host" "cat > $remote/docker-compose.yml.incoming" < "$compose"
    slots take-compose docker-compose.yml.incoming || die "the repo's docker-compose.yml was not installed (reason above); nothing else changed"
  fi

  say "Starting $v in $idle"
  slots start "$new" || die "$idle did not come up on $v (reason above). Prod is unchanged on $slot."

  say "Checking $idle through nginx before the switch"
  if ! checks=$(site_check "$idle"); then
    echo "$checks"
    slots retire >/dev/null || true
    die "$v does not pass the checks above, so nothing was switched and $idle was stopped again. Prod is unchanged on $slot."
  fi
  echo "$checks"

  say "Switching"
  slots switch || die "the switch did not finish (reason above). 'release.sh status' shows where prod is; 'release.sh deploy $v' tries again."
  record "$v" 'date -u +%Y-%m-%dT%H:%M:%SZ > $R/activated; chmod 600 $R/activated'
  finish_deploy "$v" "$new" "$idle" "$wait_min"
}

finish_deploy() { # <version> <image> <live slot> <wait minutes>: checks, waits for the old slot, records
  local v=$1 new=$2 slot=$3 wait_min=$4 checks rc=0 activated epoch errors drift
  say "Checking the site"
  checks=$(site_check "$slot" --direct) || rc=$?
  echo "$checks"
  [ $rc = 0 ] || echo "WARNING: prod is on $v, but the checks marked FAIL did not pass. To go back: release.sh rollback $v"

  if [ "$(record "$v" 'test -e $R/retired && echo yes || true')" != yes ]; then
    say "Waiting for the old slot's games (up to $wait_min minutes)"
    rc=0; slots wait "$wait_min" || rc=$?
    [ $rc != 3 ] || die "prod is on $v; the old slot still has games and keeps running until they end. Run 'release.sh deploy $v' again later to keep waiting."
    [ $rc = 0 ] || die "could not wait for the old slot (reason above). Run 'release.sh deploy $v' again."
    slots retire || die "the old slot was not stopped (reason above). Run 'release.sh deploy $v' again."
    record "$v" 'date -u +%Y-%m-%dT%H:%M:%SZ > $R/retired; chmod 600 $R/retired'
  fi

  activated=$(record "$v" 'cat $R/activated')
  epoch=$(date -d "$activated" +%s)
  errors=$(ssh "$host" "journalctl -t fortyfives-web-$slot-1 --since @$epoch --no-pager -o cat | grep -E '\[error\]|\[warning\]'" || true)
  if [ -n "$errors" ]; then
    echo "log errors/warnings since the switch:"; sed -n 1,10p <<<"$errors" | cut -c1-200
  else
    echo "no errors or warnings in the $slot log since the switch"
  fi

  say "Recording"
  copy_back
  git --no-pager diff --stat -- "$compose" "$slotmap"
  if drift=$("$here/check-drift.sh" "$host" 2>&1); then
    echo "check-drift: host matches the repo"
  else
    echo "check-drift: the host differs from the repo:"
    grep -vE '^(same|ok|running):' <<<"$drift" || true
  fi
  write_notes "$v" "$new" "$(record "$v" 'cat $R/started')" "$activated" "$(record "$v" 'cat $R/retired')" \
    "$(grep -c . <<<"$errors" || true)" "$checks"
  echo "Next: fill in Changes in docs/releases/$v.md, then deploy/contabo/release.sh finish $v"
}

# --- finish --------------------------------------------------------------

cmd_finish() {
  local v="" coauthor=""
  while [ $# -gt 0 ]; do
    case $1 in
      --co-author) coauthor=${2:?}; shift ;;
      v*) v=$1 ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  check_version "$v"
  local notes="docs/releases/$v.md"
  [ -f "$notes" ] || die "no $notes"
  grep -q 'TODO' "$notes" && die "$notes still has a TODO"
  [ "$(git branch --show-current)" = main ] || die "not on main"
  # The record commit is [skip ci]: anything pushed along with it would reach
  # main without CI, and the next `tag` would find no CI run for it.
  git fetch -q origin
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] ||
    die "local main and origin/main differ ($(git rev-list --count origin/main..HEAD) commit(s) not pushed, $(git rev-list --count HEAD..origin/main) not pulled). Push or pull first, then finish again."
  git add -- "$notes" "$compose" "$slotmap"
  # Only these paths, whatever else is staged.
  git commit -q -m "Record $v deployment [skip ci]${coauthor:+

Co-Authored-By: $coauthor}" -- "$notes" "$compose" "$slotmap"
  git push -q origin main || die "push failed; the record commit is local. git pull --rebase, then git push."
  git --no-pager log --oneline -1
}

# --- rollback ------------------------------------------------------------

draining_of() { sed -n 's/^live=[a-z]* draining=\([a-z-]*\)$/\1/p' <<<"$1"; }
running_image_of() { sed -n "s/^$2: running \([^ ]*\).*/\1/p" <<<"$1"; }

drain_and_retire() { # <minutes> <what to run again>: waits for the draining slot, then stops it
  local rc=0
  slots wait "$1" || rc=$?
  [ $rc != 3 ] || die "the old slot still has games and keeps running until they end. Run '$2' again later to keep waiting."
  [ $rc = 0 ] || die "could not wait for the old slot (reason above). Run '$2' again."
  slots retire || die "the old slot was not stopped (reason above). Run '$2' again."
}

cmd_rollback() {
  local v="" now=0 prev new l slot cur st old
  while [ $# -gt 0 ]; do
    case $1 in
      --now) now=1 ;;
      v*) v=$1 ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  check_version "$v"
  prev=$(record "$v" 'cat $R/previous-image') || die "no release record for $v on the host ($remote/backups/release-$v)"
  new=$(record "$v" 'cat $R/new-image')
  l=$(live) || die "could not read the live slot on the host"
  slot=${l% *}; cur=${l#* }; old=$(other "$slot")
  st=$(slots state)

  if [ "$cur" = "$prev" ]; then
    echo "prod already runs the image before $v on $slot"
  elif [ "$cur" != "$new" ]; then
    die "prod runs ${cur#*@sha256:}, which is neither $v's image nor the one before it. Look at 'release.sh status'."
  elif [ "$(draining_of "$st")" = "$old" ] && [ "$(running_image_of "$st" "$old")" = "$prev" ]; then
    say "Switching back to $old, which still runs the image before $v"
    slots switch || die "the switch back did not finish (reason above)"
    slot=$old
  else
    [ "$(draining_of "$st")" = - ] || die "$(draining_of "$st") is draining another image; wait for it ('release.sh status') first"
    say "Starting the image before $v in $old"
    slots start "$prev" || die "it did not come up (reason above); prod is unchanged on $slot"
    site_check "$old" || { slots retire >/dev/null || true; die "the old image fails the checks above; stopped it again, prod is unchanged on $slot"; }
    slots switch || die "the switch back did not finish (reason above)"
    slot=$old
  fi
  record "$v" 'test -e $R/rolled-back || { date -u +%Y-%m-%dT%H:%M:%SZ > $R/rolled-back; chmod 600 $R/rolled-back; }'
  echo "new visitors get the image before $v on $slot"

  if [ $now = 1 ]; then
    slots retire --force || die "the slot running $v was not stopped (reason above)"
  else
    drain_and_retire 60 "release.sh rollback $v (or with --now to end $v's games)"
  fi
  site_check "$slot" --direct || echo "not every check passed (FAIL above)"
  copy_back
  echo "Database migrations from $v are not undone. If the old image cannot run on"
  echo "the new schema, restore /backups/fortyfives-pre-$v.db (see deploy/contabo/README.md)."
  echo "Commit deploy/contabo/docker-compose.yml and nginx/slot/live.conf, and note the rollback in docs/releases/$v.md."
}

# --- restart -------------------------------------------------------------

cmd_restart() { # the live image again, in the other slot
  local l slot cur st
  l=$(live) || die "could not read the live slot on the host"
  slot=${l% *}; cur=${l#* }
  st=$(slots state)
  if [ "$(draining_of "$st")" = - ]; then
    say "Starting the live image in $(other "$slot")"
    slots start "$cur" || die "it did not come up (reason above); prod is unchanged on $slot"
    site_check "$(other "$slot")" || { slots retire >/dev/null || true; die "it fails the checks above; stopped it again, prod is unchanged on $slot"; }
    slots switch || die "the switch did not finish (reason above)"
  else
    echo "$(draining_of "$st") is still draining from an earlier restart or deploy"
  fi
  drain_and_retire 120 "release.sh restart"
  copy_back
  echo "Done. Commit deploy/contabo/docker-compose.yml and nginx/slot/live.conf."
}

case ${1:-} in
  status) shift; cmd_status "$@" ;;
  tag) shift; cmd_tag "$@" ;;
  deploy) shift; cmd_deploy "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  restart) shift; cmd_restart "$@" ;;
  *) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
