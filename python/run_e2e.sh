#!/usr/bin/env bash
# Runs every tbot scenario in parallel against an already-running app and
# fails if any of them fails. Logs land in tbot_<name>.log and failure
# screenshots/HTML in $TBOT_ARTIFACT_DIR.
#
#   APP_BASE_URL=http://localhost:4000/play python/run_e2e.sh
#
# The scenarios use separate queues (public vs. two private lobbies), so they
# can't match into each other's games. All browsers share one IP, which the
# app rate-limits: 7 queue joins and 5 server bots per run stay well inside
# the per-IP budgets (40 joins/hour, 6 bots/10 min).
set -uo pipefail

cd "$(dirname "$0")/.."

export APP_BASE_URL="${APP_BASE_URL:-http://localhost:4000/play}"
export TBOT_ARTIFACT_DIR="${TBOT_ARTIFACT_DIR:-artifacts}"
export TBOT_LOBBY_FILE="$TBOT_ARTIFACT_DIR/private_lobby_url"
mkdir -p "$TBOT_ARTIFACT_DIR"
rm -f "$TBOT_LOBBY_FILE" tbot_*.log

# name|environment
scenarios=(
  "public-1|TBOT_SCENARIO=public"
  "public-2|TBOT_SCENARIO=public"
  "public-3|TBOT_SCENARIO=public"
  "public-4|TBOT_SCENARIO=public"
  "private-host|TBOT_SCENARIO=private-host TBOT_WAIT_FOR_PLAYERS=2"
  "private-guest|TBOT_SCENARIO=private-guest TBOT_REJOIN=1"
  "abandon|TBOT_SCENARIO=abandon"
)

names=()
pids=()
for entry in "${scenarios[@]}"; do
  name="${entry%%|*}"
  # shellcheck disable=SC2086 # the env list is meant to word-split
  env TBOT_INSTANCE="$name" ${entry#*|} \
    python -u python/tbot.py > "tbot_$name.log" 2>&1 &
  names+=("$name")
  pids+=("$!")
done

failed=()
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    failed+=("${names[$i]}")
  fi
done

for name in "${names[@]}"; do
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::tbot $name"; else echo "── tbot $name"; fi
  cat "tbot_$name.log"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi
done

if [ "${#failed[@]}" -ne 0 ]; then
  echo "Failed scenarios: ${failed[*]}"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    for name in "${failed[@]}"; do
      echo "::error title=tbot $name failed::$(grep -m1 'Run failed' "tbot_$name.log" || echo 'see log')"
    done
  fi
  exit 1
fi

echo "All ${#names[@]} tbot scenarios passed."
