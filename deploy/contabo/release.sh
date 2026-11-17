#!/usr/bin/env bash
# Releases fortyfives.net to the Contabo host. Run from anywhere in the repo.
#
#   release.sh status                     what prod runs, games in progress, unreleased commits
#   release.sh tag [vX] [--no-ci-wait]    tag origin/main once its CI passed; waits for the image
#   release.sh deploy vX [options]        put image vX live (see "deploy options" below)
#   release.sh finish vX [--co-author "Name <email>"]
#                                         commit docs/releases/vX.md + compose, push
#   release.sh rollback vX [--now]        go back to the image before vX
#
# deploy options:
#   --wait MIN       wait up to MIN minutes for idle tables (default 30)
#   --dry-run        check everything (tag, image, compose files, games) and stop
#   --push-compose   the repo's docker-compose.yml has changes the host lacks
#                    (e.g. a new environment variable): upload it with the new
#                    digest instead of only swapping the digest on the host
#
# Typical release: `release.sh tag && release.sh deploy vX`, then fill in the
# "Changes" part of docs/releases/vX.md and `release.sh finish vX`.
# `tag` waits for CI (about 10 minutes) and `deploy` for idle tables, so run
# them in the background when calling from an agent with a command timeout.
#
# Every step can be run again after it was cut short: `tag vX` waits again
# for vX's image, `deploy vX` finishes a half-done switch or repeats the
# checks and the record. A non-zero exit always means "not done"; the last
# lines say why and what to run next.
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
cd "$repo"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "needs $1"; }
ssh() { command ssh -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$@"; }

# "<games in progress> <players in the public queue>". Private lobbies that
# are still filling and analysis boards are not counted. The switch script in
# cmd_deploy carries a copy of this expression.
count_rpc='IO.write([Integer.to_string(DynamicSupervisor.count_children(Website45sV3.Game.GameSupervisor).active), 32, Integer.to_string(Website45sV3.Game.QueueStarter.player_count())])'
table_counts() {
  local c
  c=$(ssh "$host" "docker exec fortyfives-web-1 bin/website_45s_v3 rpc '$count_rpc'") || return 1
  [[ $c =~ ^[0-9]+\ [0-9]+$ ]] || return 1
  echo "$c"
}

prod_image() { # the image docker-compose.yml on the host names
  ssh "$host" "grep -m1 -o '$image@sha256:[0-9a-f]*' $remote/docker-compose.yml"
}

running_image() { # the image the web container was created from
  ssh "$host" "docker inspect -f '{{.Config.Image}}' fortyfives-web-1"
}

copy_compose_back() { # host's docker-compose.yml -> the repo copy
  if ssh "$host" "cat $remote/docker-compose.yml" > "$tmp/compose.host" && [ -s "$tmp/compose.host" ]; then
    cat "$tmp/compose.host" > "$compose"
  else
    die "could not read the host's docker-compose.yml; the repo copy is unchanged. Run the same command again."
  fi
}

digest_of() { # <tag> -> sha256:..., empty if the tag has no image yet
  skopeo inspect --raw "docker://$image:$1" 2>/dev/null | sha256sum | awk '{print "sha256:" $1}' |
    grep -v e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 || true
}

newest_tag() { git tag --sort=-v:refname -l 'v*' | sed -n 1p; }

is_skip_ci() { # <commit>: GitHub starts no workflow for it, not even for a tag on it
  grep -qE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]' <<<"$(git log -1 --format=%B "$1")"
}

check_version() { [[ ${1:-} =~ ^v[0-9]+(\.[0-9]+)+$ ]] || die "expected a version like v2.0.1.33, got '${1:-}'"; }

# --- status --------------------------------------------------------------

cmd_status() {
  need skopeo
  local cur run health c tag="" t
  git fetch -q --tags origin
  cur=$(prod_image)
  run=$(running_image)
  health=$(ssh "$host" "docker inspect -f '{{.State.Health.Status}}' fortyfives-web-1")
  c=$(table_counts) || c="? ?"
  for t in $(git tag --sort=-v:refname -l 'v*' | sed -n 1,5p); do
    if [ "$image@$(digest_of "$t")" = "$cur" ]; then tag=$t; break; fi
  done
  echo "prod:     ${tag:-unknown tag} (${cur#*@sha256:}) web $health, ${c% *} game(s) in progress, ${c#* } in the queue"
  [ "$run" = "$cur" ] || echo "WARNING:  the web container runs ${run#*@sha256:}, not the image in docker-compose.yml"
  echo "newest:   $(newest_tag)"
  if [ -n "$tag" ]; then
    local pending
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

wait_idle() { # <minutes>: until no game is in progress and the public queue is empty
  local limit=$1 start c last="" fails=0
  start=$(date +%s)
  while :; do
    if c=$(table_counts); then
      fails=0
      [ "$c" = "0 0" ] && { echo "no games in progress, nobody in the queue"; return; }
      [ "$c" = "$last" ] || echo "$(date +%H:%M:%S) ${c% *} game(s) in progress, ${c#* } in the queue; waiting"
      last=$c
    else
      fails=$((fails + 1))
      [ $fails -lt 4 ] || die "cannot read the game count from the host (4 tries in a row)"
    fi
    [ $(( $(date +%s) - start )) -lt $(( limit * 60 )) ] ||
      die "tables still busy after $limit minutes (${last:-count unknown}: games, queued); try again later or pass --wait MIN"
    sleep 30
  done
}

health_check() { # <expected image>: one line per check, "FAIL" in front of a bad one.
  # Returns 2 if the site never answered, 1 if any other check failed.
  local want=$1 start code body secs p got health="" bad=0
  start=$(date +%s)
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$site/healthz" || true)
    [ "$code" = 200 ] && break
    [ $(( $(date +%s) - start )) -lt 180 ] || { echo "FAIL /healthz still ${code:-no answer} after 180 s"; return 2; }
    sleep 3
  done
  secs=$(( $(date +%s) - start ))
  echo "/healthz $(curl -s --max-time 10 "$site/healthz" || true) (first 200 after ${secs} s)"
  body=$(curl -s --max-time 10 "$site/healthz/auth" || true)
  if grep -q '"status":"ok"' <<<"$body"; then echo "/healthz/auth $body"; else echo "FAIL /healthz/auth ${body:-no answer}"; bad=1; fi
  for p in / /play /analysis; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$site$p" || true)
    if [ "$code" = 200 ]; then echo "$p 200"; else echo "FAIL $p ${code:-no answer}"; bad=1; fi
  done
  for _ in $(seq 1 30); do
    health=$(ssh "$host" "docker inspect -f '{{.State.Health.Status}}' fortyfives-web-1" || true)
    [ "$health" = healthy ] && break
    sleep 3
  done
  got=$(running_image || true)
  if [ "$got" = "$want" ] && [ "$health" = healthy ]; then
    echo "container $got healthy"
  else
    echo "FAIL container ${got:-unknown} ${health:-unknown} (expected $want healthy)"; bad=1
  fi
  return $bad
}

write_notes() { # <version> <new image> <started> <activated> <log errors> <checks text>
  local v=$1 new=$2 started=$3 activated=$4 errors=$5 checks=$6 notes prev commit
  notes="docs/releases/$v.md"
  started=${started%Z}; activated=${activated%Z}
  [ -e "$notes" ] && { echo "$notes exists, not touching it"; return; }
  prev=$(git describe --tags --abbrev=0 "$v^" 2>/dev/null || true)
  commit=$(git rev-parse --short "$v^{commit}")
  {
    echo "# Release $v"
    echo
    echo "Application commit: \`$commit\`. Deployed on ${started%T*} from ${started#*T} to"
    echo "${activated#*T} UTC with no games in progress."
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
    echo "After deploying (\`release.sh deploy\`):"
    echo
    sed 's/^/- /' <<<"$checks"
    echo "- $errors error/warning line(s) in the web log since the switch."
  } | sed 's/[[:space:]]*$//' > "$notes"
  echo "wrote $notes (fill in Changes)"
}

after_switch() { # <version> <image>: checks the site, copies the compose file back, writes the notes
  local v=$1 new=$2 rec=$remote/backups/release-$1 started activated epoch errors checks drift rc=0
  started=$(ssh "$host" "cat $rec/started")
  activated=$(ssh "$host" "cat $rec/activated")

  say "Checking the site"
  checks=$(health_check "$new") || rc=$?
  echo "$checks"
  [ $rc != 2 ] || die "the site is not answering on $v. To go back: release.sh rollback $v --now"
  epoch=$(date -d "$activated" +%s)
  errors=$(ssh "$host" "journalctl -t fortyfives-web-1 --since @$epoch --no-pager -o cat | grep -E '\[error\]|\[warning\]'" || true)
  if [ -n "$errors" ]; then
    echo "log errors/warnings since the switch:"; sed -n 1,10p <<<"$errors" | cut -c1-200
  else
    echo "no errors or warnings in the web log since the switch"
  fi
  ssh "$host" "journalctl -t fortyfives-web-1 --since @$epoch --no-pager -o cat | grep -iE 'migrat' | sed -n 1,3p" || true

  say "Recording"
  copy_compose_back
  git --no-pager diff --stat -- "$compose"
  if drift=$("$here/check-drift.sh" "$host" 2>&1); then
    echo "check-drift: host matches the repo"
  else
    echo "check-drift: the host differs from the repo:"
    grep -vE '^(same|ok|running):' <<<"$drift" || true
  fi
  [ $rc = 0 ] ||
    die "prod is on $v, but the check(s) marked FAIL above did not pass. Look into them, then run 'release.sh deploy $v' again to repeat the checks and write docs/releases/$v.md, or go back with 'release.sh rollback $v --now'."
  write_notes "$v" "$new" "$started" "$activated" "$(grep -c . <<<"$errors" || true)" "$checks"
  echo "Next: fill in Changes in docs/releases/$v.md, then deploy/contabo/release.sh finish $v"
}

cmd_deploy() {
  need skopeo
  local v="" wait_min=30 push=0 dry=0 resume=0 digest new cur rec state c
  while [ $# -gt 0 ]; do
    case $1 in
      --wait) wait_min=${2:?}; shift ;;
      --push-compose) push=1 ;;
      --dry-run) dry=1 ;;
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
  cur=$(prod_image)
  rec=$remote/backups/release-$v
  state=$(ssh "$host" "if [ -e $rec/activated ]; then echo activated; elif [ -e $rec/started ]; then echo started; else echo none; fi")

  if [ "$state" = activated ]; then
    [ "$cur" = "$new" ] ||
      die "$v was deployed before and prod has since moved to another image (${cur#*@sha256:}). Tag a new version."
    echo "prod was switched to $v at $(ssh "$host" "cat $rec/activated")"
    [ $dry = 0 ] || { echo "dry run: nothing left to switch"; return; }
    echo "repeating the checks and the record"
    after_switch "$v" "$new"
    return
  fi

  if [ "$cur" = "$new" ]; then
    [ "$state" = started ] ||
      die "the host's docker-compose.yml is already on $v's image, but there is no release record ($rec): it was not switched by this script. Look at the host by hand."
    resume=1; push=0
    echo "an earlier deploy of $v stopped during the switch; this run finishes it"
  else
    echo "deploying $v: ${cur#*@sha256:} -> ${digest#sha256:}"
    # The repo copy must match the host (apart from the digest we are about to
    # change), or copying the host's file back afterwards would lose repo edits.
    ssh "$host" "cat $remote/docker-compose.yml" > "$tmp/compose.before" && [ -s "$tmp/compose.before" ] ||
      die "could not read the host's docker-compose.yml"
    if ! diff -u --label host --label repo "$tmp/compose.before" "$compose"; then
      [ $push = 1 ] || die "deploy/contabo/docker-compose.yml differs from the host (diff above). Pass --push-compose to upload the repo's version, or copy the host's back first."
      sed -E "s#$image@sha256:[0-9a-f]{64}#$new#g" "$compose" > "$tmp/compose.push"
    elif [ $push = 1 ]; then
      echo "repo and host compose files already match; --push-compose not needed"
      push=0
    fi
  fi

  if [ $dry = 1 ]; then
    if [ $push = 1 ]; then
      ssh "$host" "cat > $remote/docker-compose.yml.dryrun" < "$tmp/compose.push"
      ssh "$host" "cd $remote && { docker compose -f docker-compose.yml.dryrun config -q; rc=\$?; rm -f docker-compose.yml.dryrun; exit \$rc; }" ||
        die "the repo's docker-compose.yml does not pass 'docker compose config' on the host"
      echo "the repo's docker-compose.yml is valid on the host"
    fi
    c=$(table_counts) || c="? ?"
    echo "dry run: ${c% *} game(s) in progress, ${c#* } in the queue now; stopping before any change"
    return
  fi

  if [ $resume = 0 ]; then
    say "Pulling the image on the host"
    ssh "$host" "docker pull -q $new" >/dev/null
    say "Waiting for idle tables"
    wait_idle "$wait_min"
    if [ $push = 1 ]; then
      ssh "$host" "cat > $remote/docker-compose.yml.incoming" < "$tmp/compose.push"
      echo "uploaded the repo's docker-compose.yml (applied at the switch)"
    fi
  fi

  say "Backing up and switching"
  ssh "$host" "V=$v NEW=$new IMAGE=$image PUSH=$push sh -s" <<'EOF' || die "the switch to this version did not finish (reason above). 'release.sh status' shows what prod runs; 'release.sh deploy' with the same version tries again."
set -eu
umask 077
cd /home/fortyfives
R=backups/release-$V
trap 'rm -f docker-compose.yml.next docker-compose.yml.incoming' EXIT
# "<games in progress> <players in the public queue>", as count_rpc above.
busy() { docker exec fortyfives-web-1 bin/website_45s_v3 rpc 'IO.write([Integer.to_string(DynamicSupervisor.count_children(Website45sV3.Game.GameSupervisor).active), 32, Integer.to_string(Website45sV3.Game.QueueStarter.player_count())])' </dev/null; }

CUR=$(grep -m1 -o "$IMAGE@sha256:[0-9a-f]*" docker-compose.yml)
[ "$(grep -c "$CUR" docker-compose.yml)" = 2 ] || { echo "expected the current digest twice in docker-compose.yml"; exit 1; }
[ ! -e "$R/activated" ] || { echo "$R/activated exists: $V was deployed before. Use a new version."; exit 1; }

if [ "$CUR" = "$NEW" ]; then
  # An earlier run replaced the file and stopped before the containers were up.
  [ -s "$R/docker-compose.before.yml" ] || { echo "docker-compose.yml is on $V's image but $R has no copy of the file before it"; exit 1; }
  c=$(busy 2>/dev/null) || c="0 0" # web may not be running at all
  [ "$c" = "0 0" ] || { echo "tables are busy ($c: games, queued) on a half-finished switch; run deploy again when they are done"; exit 1; }
else
  c=$(busy)
  [ "$c" = "0 0" ] || { echo "tables just got busy ($c: games, queued); nothing was changed, run deploy again"; exit 1; }
  mkdir -p -m 700 "$R"
  cp -p docker-compose.yml "$R/docker-compose.before.yml"
  cp -p .env "$R/env.before"
  echo "$CUR" > "$R/previous-image"
  echo "$NEW" > "$R/new-image"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$R/started"
  chmod 600 "$R"/*
  ok=$(docker exec fortyfives-db_backup-1 sh -c "sqlite3 \"\$DATABASE_PATH\" '.timeout 30000' '.backup /backups/fortyfives-pre-$V.db' && sqlite3 /backups/fortyfives-pre-$V.db 'PRAGMA integrity_check'" </dev/null)
  [ "$ok" = ok ] || { echo "backup integrity check: $ok"; exit 1; }
  echo "backup /backups/fortyfives-pre-$V.db ok"
  if [ "$PUSH" = 1 ]; then
    mv docker-compose.yml.incoming docker-compose.yml.next
  else
    sed "s#$CUR#$NEW#g" docker-compose.yml > docker-compose.yml.next
  fi
  [ "$(grep -c "$NEW" docker-compose.yml.next)" = 2 ] || { echo "new digest not in both places"; exit 1; }
  docker compose -f docker-compose.yml.next config -q </dev/null
  # The backup takes a while; look again right before the restart.
  c=$(busy)
  [ "$c" = "0 0" ] || { echo "tables got busy during the backup ($c: games, queued); nothing was switched, run deploy again"; exit 1; }
  mv docker-compose.yml.next docker-compose.yml
fi

if ! out=$(docker compose up -d web db_backup </dev/null 2>&1); then
  echo "$out" | tail -15
  echo "docker compose up failed; putting the previous docker-compose.yml back"
  cp -p "$R/docker-compose.before.yml" docker-compose.yml
  docker compose up -d web db_backup </dev/null 2>&1 | tail -5
  echo "web now: $(docker inspect -f '{{.Config.Image}} {{.State.Status}}' fortyfives-web-1 2>&1)"
  exit 1
fi
echo "$out" | tail -3
got=$(docker inspect -f '{{.Config.Image}}' fortyfives-web-1)
[ "$got" = "$NEW" ] || { echo "web runs $got, not $NEW"; exit 1; }
date -u +%Y-%m-%dT%H:%M:%SZ > "$R/activated"
chmod 600 "$R"/*

# Only web and db_backup were restarted. Say so if the file changed for others.
before=$(docker compose --project-directory . -f "$R/docker-compose.before.yml" config --hash '*' </dev/null 2>/dev/null) || before=
after=$(docker compose config --hash '*' </dev/null 2>/dev/null) || after=
if [ -n "$before" ] && [ -n "$after" ]; then
  others=$(echo "$after" | while read -r svc hash; do
    case $svc in web | db_backup | "") continue ;; esac
    echo "$before" | grep -qx "$svc $hash" || printf '%s ' "$svc"
  done)
  [ -z "$others" ] || echo "NOTE: docker-compose.yml also changed for: $others(not restarted). When ready, on the host: cd /home/fortyfives && docker compose up -d $others"
fi
EOF
  after_switch "$v" "$new"
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
  git add -- "$notes" "$compose"
  # Only these two paths, whatever else is staged.
  git commit -q -m "Record $v deployment [skip ci]${coauthor:+

Co-Authored-By: $coauthor}" -- "$notes" "$compose"
  git push -q origin main || die "push failed; the record commit is local. git pull --rebase, then git push."
  git --no-pager log --oneline -1
}

# --- rollback ------------------------------------------------------------

cmd_rollback() {
  local v="" now=0 prev rec
  while [ $# -gt 0 ]; do
    case $1 in
      --now) now=1 ;;
      v*) v=$1 ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  check_version "$v"
  rec=$remote/backups/release-$v
  prev=$(ssh "$host" "cat $rec/previous-image") || die "no release record for $v on the host ($rec)"
  if [ $now = 0 ]; then
    if table_counts >/dev/null 2>&1; then
      say "Waiting for idle tables (--now skips this)"
      wait_idle 30
    else
      echo "the web container is not answering, so there are no tables to wait for"
    fi
  fi
  say "Switching back"
  ssh "$host" "V=$v sh -s" <<'EOF' || die "the rollback did not finish (reason above). 'release.sh status' shows what prod runs."
set -eu
umask 077
cd /home/fortyfives
R=backups/release-$V
trap 'rm -f docker-compose.yml.next' EXIT
PREV=$(cat "$R/previous-image")
NEW=$(cat "$R/new-image")
[ "$(grep -c "$NEW" docker-compose.yml)" = 2 ] || { echo "docker-compose.yml is not on $V's image"; exit 1; }
sed "s#$NEW#$PREV#g" docker-compose.yml > docker-compose.yml.next
if [ -s "$R/docker-compose.before.yml" ] && ! cmp -s docker-compose.yml.next "$R/docker-compose.before.yml"; then
  # The deploy changed more than the digest (--push-compose): go back to the whole file.
  cp -p "$R/docker-compose.before.yml" docker-compose.yml.next
  echo "restoring docker-compose.yml as it was before $V (the deploy changed more than the image)"
fi
docker compose -f docker-compose.yml.next config -q </dev/null
cp -p docker-compose.yml "$R/docker-compose.at-rollback.yml"
mv docker-compose.yml.next docker-compose.yml
if ! out=$(docker compose up -d web db_backup </dev/null 2>&1); then
  echo "$out" | tail -15
  echo "docker compose up failed. docker-compose.yml names the previous image; the containers need a look."
  exit 1
fi
echo "$out" | tail -3
date -u +%Y-%m-%dT%H:%M:%SZ > "$R/rolled-back"
echo "now on $PREV"
EOF
  say "Checking the site"
  health_check "$prev" || echo "not every check passed (FAIL above)"
  copy_compose_back
  echo "Database migrations from $v are not undone. If the old image cannot run on"
  echo "the new schema, restore /backups/fortyfives-pre-$v.db (see deploy/contabo/README.md)."
  echo "Commit deploy/contabo/docker-compose.yml and note the rollback in docs/releases/$v.md."
}

case ${1:-} in
  status) shift; cmd_status "$@" ;;
  tag) shift; cmd_tag "$@" ;;
  deploy) shift; cmd_deploy "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  *) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
