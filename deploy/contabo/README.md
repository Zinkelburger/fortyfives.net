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

What to grep for in `docker logs fortyfives-web-1 2>&1`:

| Line | Meaning |
|---|---|
| `[error]` | A crash: a LiveView, a game (`GameController crashed`) or a failed email. Should be rare. |
| `human seat(s) N not connected 60s after the start` | A no-show (see above). |
| `Game X starting from the public queue: …` / `Game X ended: …` | One of each per game; the end line says how it ended and names seats that never connected. |
| `Queue: <id> joined / left / dropped: its page closed without leaving` | Queue movements. `<id>` is the first 8 characters of `site_events.player_id`. |
| `Google sign-in ok` / `refused` / `failed`, `Password sign-in ok` / `refused: <message>` | Every sign-in attempt. |
| `Daily health: …` | The summary above, once a day. |

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

It needs passphrase-less SSH to `twic-vps` (no agent under cron).
