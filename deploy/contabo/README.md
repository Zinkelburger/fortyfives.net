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
| `docker-compose.yml` | `deploy/contabo/docker-compose.yml` | The only compose file in use. The image digest is written in by hand (both `web` and `db_backup`). |
| `nginx/conf.d/site.conf` | `deploy/contabo/nginx/conf.d/site.conf` | Single-file bind mount: edit in place (`cat new > site.conf`), not `sed -i` or `mv`, then `nginx -t` and `nginx -s reload`. |
| `scripts/backup-sqlite.sh` | `scripts/backup-sqlite.sh` | Daily SQLite online backup, 14 days kept. |
| `.env` | `deploy/contabo/env.keys` (key names only) | Secrets stay on the host. |
| `/etc/letsencrypt/renewal/fortyfives.net.conf` | `deploy/contabo/letsencrypt/renewal/fortyfives.net.conf` | Written by certbot; the drift check compares only `[renewalparams]` and below. Keys and certificates stay on the host. |
| `backups/release-vX/` | — | Per-release record: `docker-compose.before.yml`, `env.before`, `previous-image`, `new-image`, `started`, `activated` (UTC). |
| `docker-compose.sqlite.yml` | — | Leftover from the SQLite cutover; not used. |

- Docker volumes (all `external`): `fortyfives_app_data` (the SQLite
  database, `/data/fortyfives.db` in `web`), `fortyfives_sqlite_backups`
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

1. Tag `vX` on a commit that is not `[skip ci]`; the "Build and Push" workflow
   prints the image digest (`docker.io/thwar/fortyfives.net:vX@sha256:...`).
2. Wait for no running games:
   `docker exec fortyfives-web-1 bin/website_45s_v3 rpc "IO.write(DynamicSupervisor.count_children(Website45sV3.Game.GameSupervisor).active)"`
   should print `0`.
3. Record the release in `backups/release-vX/` (see above) and take a backup:
   `docker exec fortyfives-db_backup-1 sh -c 'sqlite3 "$DATABASE_PATH" ".timeout 30000" ".backup /backups/fortyfives-pre-vX.db" && sqlite3 /backups/fortyfives-pre-vX.db "PRAGMA integrity_check"'`
   should print `ok`.
4. Replace the old digest with the new one in `docker-compose.yml` (two
   places), then `docker compose pull web && docker compose up -d web db_backup`.
5. Check `curl https://fortyfives.net/healthz` (expect `ok`) and
   `/healthz/auth`. nginx finds the new `web` container within 10 seconds.
6. Copy the new `docker-compose.yml` here, and add `docs/releases/vX.md`.

Rollback: put the previous digest (`backups/release-vX/previous-image`) back
in `docker-compose.yml` and run `docker compose up -d web db_backup`.

## Checking that players are fine

The database and the logs together answer "did anyone run into trouble?".

Summary of the last N days (games, no-show seats, queue departures,
sign-ups and sign-ins); the app also logs the last day's as "Daily health"
once a day:

```sh
ssh twic-vps 'docker exec fortyfives-web-1 bin/website_45s_v3 rpc "IO.puts(Website45sV3.Analytics.Health.text(days: 7))"'
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
ssh twic-vps 'journalctl -t fortyfives-web-1 --utc --since "2026-11-10 06:00" --until "2026-11-10 07:00" --no-pager'
ssh twic-vps 'journalctl -t fortyfives-web-1 --utc --since -2d --no-pager | grep "Private lobby"'
```

Tags: `fortyfives-web-1`, `fortyfives-nginx-1`, `fortyfives-certbot-1`,
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
zgrep -h '"fortyfives-web-1"' journal-*.jsonl.gz | jq -r .MESSAGE | grep '\[error\]'
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
   `docker-compose.yml`, `nginx/conf.d/site.conf`, `scripts/backup-sqlite.sh`
   from this repo and an empty `certbot/www/`.
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
6. `docker compose up -d`, point Cloudflare's DNS at the new IP, and run the
   checks in step 5 of the release steps above.
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
