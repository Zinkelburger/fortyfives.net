# Production host (Contabo)

What runs fortyfives.net today, copied from the host so it can be rebuilt.
`docs/deploy.md` describes the repo's own stack (`docker-compose-nginx.yml`,
`nginx.conf`); production predates it and has not been moved over, so the
files here are the ones that matter for the live site.

Check that this directory still matches the host:

```sh
deploy/contabo/check-drift.sh        # read-only; .env compared by key names
```

After changing anything on the host, copy the file back here and commit it.

## Host

- Contabo VPS `89.117.75.142`, SSH alias `twic-vps` (root, key auth). The box
  also runs the chess "twic" API.
- Everything lives in `/home/fortyfives`, Compose project `fortyfives`:

| Host path | In this repo | Notes |
|---|---|---|
| `docker-compose.yml` | `deploy/contabo/docker-compose.yml` | The only compose file in use. `slots.sh` writes the image digests and scales of `web-blue`, `web-green` and `db_backup`. |
| `nginx/slot/live.conf` | `deploy/contabo/nginx/slot/live.conf` | Which slot is live, written by `slots.sh`. A directory mount, so it can be replaced. |
| `nginx/conf.d/site.conf` | `deploy/contabo/nginx/conf.d/site.conf` | Single-file bind mount: edit in place (`cat new > site.conf`), not `sed -i` or `mv`, then `nginx -t` and `nginx -s reload`. |
| `scripts/backup-sqlite.sh` | `scripts/backup-sqlite.sh` | Daily SQLite online backup, 14 days kept. |
| `.env` | `deploy/contabo/env.keys` (key names only) | Secrets stay on the host. |
| `/etc/letsencrypt/renewal/fortyfives.net.conf` | `deploy/contabo/letsencrypt/renewal/fortyfives.net.conf` | Written by certbot; the drift check compares only `[renewalparams]` and below. Keys and certificates stay on the host. |
| `backups/release-vX/` | — | Per-release record: `docker-compose.before.yml`, `live.conf.before`, `env.before`, `previous-image`, `previous-slot`, `new-image`, and the times `started`, `activated`, `retired`, `rolled-back` (UTC). |
| `docker-compose.sqlite.yml` | — | Leftover from the SQLite cutover; not used. |

- Docker volumes (all `external`): `fortyfives_app_data` (the SQLite
  database, `/data/fortyfives.db` in the app containers), `fortyfives_sqlite_backups`
  (`/backups` in `db_backup`), `fortyfives_db_data` (old PostgreSQL data,
  only for the `postgres-rollback` profile).
- TLS: Let's Encrypt, renewed by the `certbot` container (see
  [TLS certificate](#tls-certificate)).
- Cloudflare proxies the site, but the server also answers direct requests.
  nginx trusts `CF-Connecting-IP` only from Cloudflare's ranges (listed in
  `site.conf`) and overwrites `CF-Connecting-IP`, `X-Forwarded-For` and
  `X-Real-IP` with the result, which Phoenix uses as the client IP
  (`Turnstile.client_ip/1`) for rate limits. If Cloudflare adds ranges
  (https://www.cloudflare.com/ips), visitors on them share their edge's IP
  until the list is updated.

## TLS certificate

One ECDSA Let's Encrypt certificate covers `fortyfives.net` and
`www.fortyfives.net`. It lives in `/etc/letsencrypt` on the host (not a Docker
volume) and is bind-mounted read-only into nginx. Nothing on the host itself
renews it: there is no host certbot, cron job or systemd timer. The `certbot`
service in `docker-compose.yml` is the only renewer.

- **Renewal:** the container runs `certbot renew --webroot -w /var/www/certbot`
  every 12 hours. certbot renews once the certificate has 30 days left
  (certificates last 90 days). Renewal settings are in
  `/etc/letsencrypt/renewal/fortyfives.net.conf`; a copy is in
  `letsencrypt/renewal/` here (the ACME account key under `accounts/` is not).
- **Challenge:** HTTP-01 over the webroot. certbot writes the token to
  `./certbot/www`, and nginx serves it on port 80 at
  `/.well-known/acme-challenge/` without redirecting to HTTPS. This works
  through Cloudflare for both names. If that changes (an "Always Use HTTPS"
  rule, or a block on port 80), renewals fail.
- **Pickup:** there are no deploy hooks (`renewal-hooks/` is empty). nginx
  reloads itself every 24 hours, so a renewed certificate is served within a
  day.
- **The service must keep `restart: unless-stopped`.** Without it the
  container stays stopped after a host reboot, and the certificate quietly
  expires. That happened on the 2026-10-19 reboot and was caught on
  2026-10-24, with 55 days left.

Check:

```sh
ssh twic-vps 'docker ps --filter name=fortyfives-certbot-1 --format "{{.Status}}"'      # should be Up
ssh twic-vps 'openssl x509 -noout -enddate -in /etc/letsencrypt/live/fortyfives.net/cert.pem'
ssh twic-vps 'cd /home/fortyfives && docker compose exec -T certbot certbot renew --dry-run'  # staging; waits up to ~8 min first
```

If the certificate has already expired, or `renew` keeps failing, force a
renewal and reload nginx straight away:
`docker compose exec certbot certbot renew --force-renewal && docker compose exec nginx nginx -s reload`.

## Deploying a release

Production runs blue/green: two copies of the app, `web-blue` and
`web-green`, behind one nginx. One is live; the other is stopped (scale 0)
until a deploy starts the new image in it. Nobody waits for idle tables and
the site does not answer 502 at a switch.

`deploy/contabo/release.sh` does all of it:

```sh
deploy/contabo/release.sh status            # live slot, games on each, unreleased commits
deploy/contabo/release.sh tag               # waits for CI on origin/main, tags the next vX, waits for the image
deploy/contabo/release.sh deploy vX         # backs up, starts vX in the idle slot, checks, switches,
                                            # waits for the old slot's games, stops it, writes docs/releases/vX.md
# rewrite the "Changes" list in docs/releases/vX.md
deploy/contabo/release.sh finish vX         # commits the notes, compose file and slot map [skip ci], pushes
deploy/contabo/release.sh rollback vX       # back to the image before vX, the same way
deploy/contabo/release.sh restart           # the live image again in the other slot (after an .env change)
```

What a switch does to players:

| Player | After the switch |
|---|---|
| In a game | Stays on the old slot until the game ends; a refresh or reconnect goes back there. Their next page after the game is on the new slot. |
| In the public queue or a private lobby | The page reloads on the new slot, seated again with the bots they added. The lobby keeps its link. |
| Anywhere else (home, `/analysis`, settings) | The page reloads on the new slot. `/analysis` keeps the board, which is in the URL. |
| New visitor | New slot. |

A finished private game on the old slot sends its players to a rematch
lobby on the new slot.

How it works:

- `nginx/slot/live.conf` (written by `slots.sh`) maps each request to an
  upstream: the live slot by default; the draining slot for a browser whose
  `ff_slot` cookie names it; any slot for a request with an `X-FF-Slot`
  header (the deploy's checks use that to try the new slot before the
  switch). The app sets the cookie on every page it serves, and a draining
  slot sets it only for players seated in one of its games
  (`Website45sV3Web.SlotRouting`).
- At the switch `slots.sh` reloads nginx and calls `Website45sV3.Slot.drain/0`
  on the old slot, which tells every open page there to reload, except a
  seated player's. Lobby and queue pages reload with a signed handoff that
  seats the player again on the new slot.
- Both slots use the same SQLite database and `.env`. Responses carry
  `x-ff-slot: blue|green`.

`release.sh deploy` in order: back up the database, start vX in the idle
slot, check `/healthz`, `/healthz/auth`, `/`, `/play` and `/analysis` on it
through nginx (`X-FF-Slot`), switch, check again without the header, wait up
to `--wait` minutes (default 60) for the old slot's games, stop the old slot,
copy the compose file and slot map back, write the notes.

- **If the new slot fails to start or fails a check before the switch**, it
  is stopped again and prod is unchanged.
- **Migrations** run when the new slot starts, while the old one still uses
  the database. `deploy` lists the migrations vX adds and stops unless
  `--migrations-ok` says they are safe for the old version: new tables and
  nullable columns are; renames, drops and new `NOT NULL` columns are not
  (do those in two releases).
- **A non-zero exit means "not done"**, and the last lines say what to run
  next. If the old slot still has games after `--wait`, prod is already on
  vX; `deploy vX` again picks up the wait. Every step can be run again after
  it was cut short.
- **`rollback vX`** switches straight back while the old slot still runs
  (the usual case right after a deploy); otherwise it starts the previous
  image in the idle slot and switches to it. `--now` stops vX's slot without
  waiting for its games. Migrations are not undone.
- **`--push-compose`**: if the repo's `docker-compose.yml` has an edit the
  host lacks (a new environment variable), `deploy` stops; this uploads the
  repo's file, keeping the host's image and scale lines. Only the app slots
  and `db_backup` are restarted by a deploy; restart other services by hand.
  Files outside the compose file (like the analysis weights) are still
  copied by hand.
- **`finish`** commits only the notes, the compose file and the slot map,
  and refuses while local `main` and `origin/main` differ: anything pushed
  along with a `[skip ci]` commit reaches `main` without CI.
- **`tag`** skips `[skip ci]` commits at the top of `main` (a tag on one
  builds no image) and tags the newest commit below them. A failed tbot e2e
  run is usually the flaky one: `gh run rerun <run> --failed`, then `tag`
  again.

### Testing a change to the deploy

`deploy/contabo/test/run.sh` rehearses two switches on this machine (docker
or podman): the repo's compose file, nginx config and `slots.sh` with a
self-signed certificate, and browsers seated in a game, the queue and a
private lobby. It checks where each one ends up and that `/` never answers
anything but 200. The "Deploy rehearsal" workflow runs it on every push
that touches the deploy or the slot code. Run it before changing
`slots.sh`, `live.conf`, `site.conf`, the compose file or the slot code.

### By hand

`slots.sh` runs on the host in `/home/fortyfives`
(`ssh twic-vps 'cd /home/fortyfives && bash -s -- state' < deploy/contabo/slots.sh`):

```sh
slots.sh state              # live=green draining=-, image and games of each slot
slots.sh start IMAGE        # IMAGE in the idle slot; waits for /healthz
slots.sh switch             # nginx to the other running slot; the old one drains
slots.sh wait 60            # until the draining slot has no games
slots.sh retire             # stop it (--force: even with games)
```

Take a backup first:
`docker exec fortyfives-db_backup-1 sh -c 'sqlite3 "$DATABASE_PATH" ".timeout 30000" ".backup /backups/fortyfives-pre-vX.db" && sqlite3 /backups/fortyfives-pre-vX.db "PRAGMA integrity_check"'`
should print `ok`. Then copy `docker-compose.yml` and `nginx/slot/live.conf`
back here and add `docs/releases/vX.md`.

## Checking that players are fine

The database and the logs together answer "did anyone run into trouble?".

Summary of the last N days (games, no-show seats, queue departures,
sign-ups and sign-ins); the app also logs the last day's as "Daily health"
once a day:

```sh
ssh twic-vps 'cd /home/fortyfives && docker compose exec -T web-$(sed -n "s/^# live=\([a-z]*\) .*/\1/p" nginx/slot/live.conf) bin/website_45s_v3 rpc "IO.puts(Website45sV3.Analytics.Health.text(days: 7))"'
```

- **crashed** should be 0.
- **no-show seats** are humans seated at a table whose page never connected,
  so bots played their seat. Until v2.0.1.26 these were mostly players who
  had left the queue by navigating to another page, then got matched anyway.
  Any new one is worth a look at the logs around that game's start.

### Logs

Since v2.0.1.29 every container logs to the host's journald (persistent, in
`/var/log/journal`), tagged with its container name. The logs survive
deploys and container recreation; before that, each deploy wiped them.
`docker logs` still shows the current container's lines. For older runs:

```sh
ssh twic-vps 'journalctl -t fortyfives-web-blue-1 -t fortyfives-web-green-1 --utc --since "2026-11-10 06:00" --until "2026-11-10 07:00" --no-pager'
ssh twic-vps 'journalctl -t fortyfives-web-blue-1 -t fortyfives-web-green-1 --utc --since -2d --no-pager | grep "Private lobby"'
```

Tags: `fortyfives-web-blue-1` and `fortyfives-web-green-1` (`fortyfives-web-1`
before blue/green, 2026-11-17), `fortyfives-nginx-1`, `fortyfives-certbot-1`,
`fortyfives-db_backup-1`. App lines carry only a time of day; use journald's
timestamp for the date. The journal is capped at 4 GB for the whole host
(the site writes about 3 MB a day) and is copied to the laptop daily, see
[Logs off the host](#logs-off-the-host). The app does not log `/healthz`
requests (the container healthcheck asks every 30 seconds); nginx still logs
the ones that come from outside.

What to grep for in the web logs:

| Line | Meaning |
|---|---|
| `[error]` | A crash: a LiveView, a game (`GameController crashed`) or a failed email. Should be rare. |
| `human seat(s) N not connected 60s after the start` | A no-show (see above). |
| `Game X starting from the public queue: …` / `Game X (public) ended: …` | One of each per game; the end line says how it ended and names seats that never connected. A private game says `private queue <lobby>` / `(private <lobby>)`. |
| `Queue: <id> joined / left / dropped: its page closed without leaving` | Queue movements. `<id>` is the first 8 characters of `site_events.player_id`. |
| `Private lobby <lobby>: created / reopened / <id> joined / left / dropped`, `Expiring private lobby <lobby> (N seated)`, `… link opened but the lobby is gone` | Private lobby movements. `<lobby>` is the first 8 characters of the lobby id, the same tag as `game_logs.lobby` and `site_events.data.lobby`. |
| `Google sign-in ok` / `refused` / `failed`, `Password sign-in ok` / `refused: <message>` | Every sign-in attempt. |
| `Account created` / `Account created with Google` / `Google account linked` / `Email confirmed` / `Email changed` / `Password changed` / `Password reset`, each `: user <id>` | Changes to an account, by user id only. |
| `Admin page <path>: user <id>` | Every `/admin` page view. |
| `Daily health: …` | The summary above, once a day. |

## Auditing and alerts

Everything here is installed by `deploy/contabo/host/apply.sh` from
`deploy/contabo/host/files/` (laid out like the host's filesystem). It is
safe to run again and changes nothing on an up-to-date host; `check-drift.sh`
compares the files and checks that the pieces are running.

| What | Where on the host | Notes |
|---|---|---|
| Audit rules | `/etc/audit/rules.d/50-fortyfives.rules` | Every command run in a login session, and changes to accounts, SSH keys and config, PAM, units, cron, `/usr/local`, `/home/fortyfives`, the rest of `/etc`, plus logs touched from a login session and kernel modules. Ten 50 MB files in `/var/log/audit`. |
| Audit records in journald | `/etc/audit/plugins.d/syslog.conf` (`active = yes`) | Tag `audisp-syslog`, so the audit trail leaves the host with the journal. |
| Journal size | `/etc/systemd/journald.conf.d/50-fortyfives.conf` | 4 GB, persistent. Holds sshd, the firewall, auditd and the containers. |
| SSH | `/etc/ssh/sshd_config.d/00-hardening.conf` | Keys only. `ufw` allows 22, 80 and 443; `fail2ban` watches sshd; security updates install themselves (`unattended-upgrades`). |
| Alerts | `/usr/local/sbin/fortyfives-alert` | Writes to journald (tag `fortyfives-alert`) and emails `ALERT_TO` from `/etc/fortyfives/alert.env` through SES with the site's send-only credentials. `apply.sh` fills `ALERT_TO` with the admin accounts' addresses (`ADMIN_USER_IDS`) the first time; edit the file to change it. |
| Login alert | `/usr/local/sbin/fortyfives-login-alert`, last line of `/etc/pam.d/sshd` | One alert the first time anyone logs in from an address not in `/var/lib/fortyfives/ssh-known-sources`. It is sent while the session opens. |
| Daily check | `fortyfives-host-check.timer` (08:30 UTC) | Containers up and healthy, a database backup under 26 hours old, 14 days left on the certificate, disk under 85%, auditd/fail2ban/ufw on, audit rules loaded, no failed units, no password logins, only root has uid 0, `authorized_keys` unchanged, only 22/80/443 listening, no packaged file modified, no reboot pending for over a week. Alerts when the list of problems changes, weekly while it stays, and once when it clears. |
| Reboot for updates | `fortyfives-quiet-reboot.timer` (07:15 UTC) | Only when `/var/run/reboot-required` exists. Waits up to 45 minutes for running games to end, skips while a deploy is draining, otherwise tries the next day. See [Reboots](#reboots). |
| Uptime | `.github/workflows/uptime.yml` | Every 30 minutes from GitHub, straight to the server: `/healthz`, `/healthz/auth`, certificate expiry. GitHub emails a failed run to whoever last edited the schedule. |

```sh
ssh twic-vps fortyfives-host-check --print                  # the daily check, now
ssh twic-vps 'echo test | fortyfives-alert "test alert"'    # send an alert
ssh twic-vps 'ausearch --input-logs -k exec -ts today -i'   # commands run in login sessions
ssh twic-vps 'ausearch --input-logs -k ssh-keys -i'         # changes to /root/.ssh
ssh twic-vps 'aureport --input-logs -x --summary -ts this-week'
```

Audit keys: `exec`, `identity`, `ssh-keys`, `sshd`, `pam`, `persistence`,
`site-config`, `etc`, `log-tamper`, `modules`. `ausearch` needs
`--input-logs` when it is not run from a terminal.

After deliberately changing root's `authorized_keys`, run `apply.sh` again
so the daily check takes the new file as the one to compare against.

### Reboots

Unattended upgrades install security updates but never reboot. When a kernel
or libc update needs one, `fortyfives-quiet-reboot` reboots the host at
07:15 UTC, the quietest time of day, as soon as no game is running in either
web slot. Everything comes back by itself: Docker starts at boot, every
container is `restart: unless-stopped`, `live.conf` still names the live slot,
and the host's other services (`twic-api`, `bld-api`, `cloudflared`) are
enabled. The site is down for a minute or two. The daily check at 08:30 UTC
reports the result, and still alerts if a reboot has been pending for a week.

```sh
ssh twic-vps fortyfives-quiet-reboot --dry-run                  # what it would do now
ssh twic-vps 'journalctl -t fortyfives-quiet-reboot --since -7d'
ssh twic-vps systemctl disable --now fortyfives-quiet-reboot.timer  # turn it off
deploy/contabo/quiet-hours.sh 60                                # redo the study below
```

The time comes from `quiet-hours.sh`: games per UTC hour over the 60 days to
2026-11-23 (2,309 games). The host's clock is Europe/Berlin, so the timer
names UTC explicitly.

| UTC | Games | | UTC | Games | | UTC | Games |
|---|---|---|---|---|---|---|---|
| 00 | 152 | | 08 | 13 | | 16 | 119 |
| 01 | 111 | | 09 | 15 | | 17 | 159 |
| 02 | 120 | | 10 | 19 | | 18 | 107 |
| 03 | 97 | | 11 | 55 | | 19 | 110 |
| 04 | 58 | | 12 | 112 | | 20 | 150 |
| 05 | 30 | | 13 | 137 | | 21 | 119 |
| 06 | 15 | | 14 | 145 | | 22 | 153 |
| **07** | **6** | | 15 | 152 | | 23 | 155 |

07:00–07:30 UTC had 2 games in 60 days, and no game between 07:00 and 10:00
had more than one human. Unattended upgrades run around 05:40 UTC and the
Tuesday `twic-weekly` job 06:00–06:10 UTC, so 07:15 avoids both.

### Logs off the host

Someone with root on the host can delete every log on it.
`scripts/pull-prod-logs.sh` copies the journal to the machine it runs on:
everything since the last run, as
`~/Backups/fortyfives.net/logs/journal-<UTC time>.jsonl.gz` (one JSON
object per line, every journald field kept, 400 days kept). Log:
`~/Backups/fortyfives.net/pull-logs.log`. On Andrew's laptop anacron runs it
daily (next to the weekly database pull, see
[Off-host backups](#off-host-backups)):

- `~/.config/anacron/anacrontab`: `1  15  fortyfives-logs  /home/anbernal/Projects/fortyfives.net/scripts/pull-prod-logs.sh`

So at most the last day of logs (longer while the laptop is off) exists only
on the host.

```sh
cd ~/Backups/fortyfives.net/logs
zgrep -h 'Accepted' journal-*.jsonl.gz | jq -r '[.__REALTIME_TIMESTAMP, .MESSAGE] | @tsv'
zgrep -h '"audisp-syslog"' journal-*.jsonl.gz | jq -r .MESSAGE | grep EXECVE
zgrep -hE '"fortyfives-web(-blue|-green)?-1"' journal-*.jsonl.gz | jq -r .MESSAGE | grep '\[error\]'
```

## If the host is broken into

The host was compromised once before it was reinstalled on 2026-07-19;
nothing from that install survives, so how it happened is not known. What
exists now is meant to make the next time answerable.

1. Do not clean up first. Pull the logs while they exist:
   `scripts/pull-prod-logs.sh`, then copy `/var/log/audit/` and
   `/var/log/auth.log*` as well.
2. In the Contabo panel, take a snapshot of the disk, then shut the host
   down or cut its network if it is doing harm.
3. Find the way in from the copies on the laptop (the host's own copies may
   have been edited): accepted SSH logins and their addresses, `exec`
   records around that time, `ssh-keys`, `identity`, `persistence` and
   `site-config` changes, and nginx/app lines just before the first one.
4. Assume every secret on the host is known. Rotate the SSH key, everything
   in `.env` (`SECRET_KEY_BASE` signs everyone out; AWS, Google OAuth,
   Turnstile and Cloudflare tokens in their consoles), the Docker Hub token,
   and the twic and bld services' secrets.
5. Reinstall rather than repair: [Rebuilding the host](#rebuilding-the-host)
   with the database from the laptop's restic repository, then `apply.sh`.

## Updating nginx, certbot and postgres

These images are pinned by tag and digest, so they only change when the
compose file does. To pick up security fixes:

1. Find the new tag's digest, e.g.
   `skopeo inspect --raw docker://docker.io/library/nginx:1.30.6-alpine3.24 | sha256sum`
   (nginx: the newest stable `1.<even>.x-alpine` tag).
2. Copy `docker-compose.yml` into `backups/maint-<date>/`, then replace only
   the `image:` lines. Keep `restart: unless-stopped` on certbot.
3. `docker compose pull nginx certbot`, then
   `docker compose run --rm --no-deps -T nginx nginx -t` (tests the live
   config with the new image), then `docker compose up -d --no-deps nginx certbot`.
4. Check `/healthz`, `docker compose exec -T certbot certbot renew --dry-run`,
   and copy `docker-compose.yml` back here.

## Rebuilding the host

1. Install Docker with the Compose plugin. Create `/home/fortyfives` with
   `docker-compose.yml`, `nginx/conf.d/site.conf`, `nginx/slot/live.conf`,
   `scripts/backup-sqlite.sh` from this repo and an empty `certbot/www/`.
   The slot that `live.conf` names live must have scale 1 in the compose
   file, the other scale 0.
2. Write `.env` (mode 600) with the keys in `env.keys`. The values are in
   the old host's `.env`, or from the services themselves: a new
   `SECRET_KEY_BASE` (`mix phx.gen.secret`) signs everyone out; AWS SES, the
   Google OAuth client and the Turnstile secret come from their consoles.
3. Create the volumes: `docker volume create fortyfives_app_data`, and the
   same for `fortyfives_sqlite_backups` and `fortyfives_db_data`.
4. Restore the database: copy the latest `fortyfives-*.db` backup into
   `fortyfives_app_data` as `fortyfives.db`, owned by the image's `app` user
   (`docker run --rm --entrypoint id IMAGE app`; uid 100, gid 101 today).
5. Certificates: copy `/etc/letsencrypt` from the old host, or get a new one
   before nginx can start (it needs the files):
   `docker run --rm -p 80:80 -v /etc/letsencrypt:/etc/letsencrypt certbot/certbot certonly --standalone -d fortyfives.net -d www.fortyfives.net`.
   Renewals then use the webroot.
6. `docker compose up -d`, point Cloudflare's DNS at the new IP, and check
   `curl https://fortyfives.net/healthz` (expect `ok`) and `/healthz/auth`.
7. `deploy/contabo/host/apply.sh <ssh-host>` for auditing, alerts, the
   firewall and SSH hardening (see [Auditing and alerts](#auditing-and-alerts)),
   then `deploy/contabo/check-drift.sh`. Update `ORIGIN` in
   `.github/workflows/uptime.yml` when the IP changes.

## Off-host backups

The host keeps 14 days of daily backups in `fortyfives_sqlite_backups`; each
is a full copy of the database (about 175 MB in October 2026, nearly all of
it session replays, which the app stores gzipped and keeps 60 days).

`scripts/pull-prod-backups.sh` copies the newest one into a restic
repository at `~/Backups/fortyfives.net/restic` on the machine it runs on,
after `PRAGMA integrity_check`. restic stores each piece of data once, so a
weekly snapshot only adds what changed rather than another full copy. It
keeps one snapshot per week for a year and one per month for five years, so
replays outlive production's 60 days. The repository has no password (the
laptop disk is encrypted). Log: `~/Backups/fortyfives.net/pull.log`.

Restore the newest snapshot:

```sh
restic -r ~/Backups/fortyfives.net/restic --insecure-no-password snapshots
restic -r ~/Backups/fortyfives.net/restic --insecure-no-password restore latest --target /tmp/restore
```

On Andrew's laptop it runs weekly through a per-user anacron, which catches
up after the laptop was off:

- crontab: `@hourly /usr/bin/anacron -s -t $HOME/.config/anacron/anacrontab -S $HOME/.local/state/anacron`
- `~/.config/anacron/anacrontab`: `7  10  fortyfives-backups  /home/anbernal/Projects/fortyfives.net/scripts/pull-prod-backups.sh`
- `~/.config/anacron/anacrontab` also has the daily log pull, see
  [Logs off the host](#logs-off-the-host).

Both need passphrase-less SSH to `twic-vps` (no agent under cron).
