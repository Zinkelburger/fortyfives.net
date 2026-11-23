#!/bin/sh
# When is nobody on fortyfives.net? Games and visitors per UTC hour and per
# half hour, from the production database (read-only). Used to pick the time
# of fortyfives-quiet-reboot.timer; see "Reboots" in README.md.
#
#   deploy/contabo/quiet-hours.sh [days] [ssh-host]   (defaults: 60, twic-vps)
set -eu
days=${1:-60}
host=${2:-twic-vps}
case $days in ''|*[!0-9]*) echo "days must be a number" >&2; exit 2 ;; esac

ssh "$host" 'docker exec -i fortyfives-db_backup-1 sh -c "sqlite3 \"file:\$DATABASE_PATH?mode=ro\""' <<EOF
.mode column
.headers on
-- site_events.inserted_at uses a T separator, so compare with strftime.
CREATE TEMP VIEW since AS SELECT strftime('%Y-%m-%dT%H:%M:%S', 'now', '-$days days') AS t;

SELECT 'last $days days, UTC' AS window, min(inserted_at) AS first_game, max(inserted_at) AS last_game
FROM game_logs, since WHERE inserted_at >= since.t;

WITH g AS (
  SELECT strftime('%H', inserted_at) AS hour, count(*) AS games, sum(human_count > 1) AS multi_human
  FROM game_logs, since WHERE inserted_at >= since.t GROUP BY hour
), v AS (
  SELECT strftime('%H', inserted_at) AS hour,
         count(DISTINCT visitor_id || substr(inserted_at, 1, 10)) AS visitor_days
  FROM site_events, since WHERE inserted_at >= since.t GROUP BY hour
)
SELECT v.hour AS utc_hour, coalesce(g.games, 0) AS games, coalesce(g.multi_human, 0) AS multi_human,
       v.visitor_days
FROM v LEFT JOIN g USING (hour) ORDER BY v.hour;

SELECT strftime('%H', inserted_at) || ':' || printf('%02d', (cast(strftime('%M', inserted_at) AS int) / 30) * 30)
         AS quietest_half_hours,
       count(*) AS games, sum(human_count > 1) AS multi_human
FROM game_logs, since WHERE inserted_at >= since.t
GROUP BY 1 ORDER BY games, 1 LIMIT 6;
EOF
