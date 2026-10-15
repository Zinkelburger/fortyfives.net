# Deploying fortyfives.net

The site runs as a Phoenix release in Docker behind nginx, with Cloudflare in
front. Everything below happens on the host in a checkout of this repository
(or a directory containing `docker-compose-nginx.yml`, `nginx.conf` and `.env`).

## Files

| File | Purpose |
| --- | --- |
| `docker-compose-nginx.yml` | Production stack: `web`, `db_backup`, `nginx`, `certbot` |
| `docker-compose.yml` | App + SQLite backup, Phoenix bound to `127.0.0.1:4000` (local testing of a release image) |
| `nginx.conf` | TLS termination and reverse proxy; Cloudflare real-IP list |
| `.env.example` | Template for `.env`; copy it and replace every `CHANGE_ME` |
| `Dockerfile.prod` | Release image built and pushed by the "Build and Push" workflow on `v*` tags |

## One-time host bootstrap

1. **Environment.** `cp .env.example .env`, fill in every value. The
   third-party credentials `AWS_*` and `GOOGLE_*` are required and must be
   non-empty; the release refuses to boot without them. `TURNSTILE_SECRET` is
   required only with `TURNSTILE_ENABLED=true` (see [Turnstile](#turnstile)).
   `CF_API_TOKEN` is a Cloudflare API token scoped to the `fortyfives.net` zone with
   `Zone:DNS:Edit` and `Zone:Zone:Read`; certbot uses it for DNS-01 challenges.

2. **Database volume.** The data volume is declared `external` so that
   `docker compose down -v` can never delete it. Create it once:

   ```sh
   docker volume create fortyfives_app_data
   ```

   `web` mounts this at `/data`, with `DATABASE_PATH=/data/fortyfives.db`.
   A fresh volume inherits the image's `app` ownership; when installing a
   converted database, set its ownership to match `id app` in that image.
   Only one app instance should use this SQLite file. For an existing
   PostgreSQL deployment, follow [the cutover plan](sqlite-migration.md).
   Never point the new image at the old PostgreSQL database.

3. **First TLS certificate.** nginx will not start without
   `/etc/letsencrypt/live/fortyfives.net/`. Obtain it with the certbot
   sidecar (DNS-01, so nothing needs to be listening on port 80 yet):

   ```sh
   sudo mkdir -p /etc/letsencrypt
   docker compose -f docker-compose-nginx.yml run --rm certbot \
     certbot certonly --dns-cloudflare \
       --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
       -d fortyfives.net -d www.fortyfives.net \
       -m you@example.com --agree-tos --no-eff-email
   ```

   The sidecar's entrypoint writes `/etc/letsencrypt/cloudflare.ini` from
   `CF_API_TOKEN` before running the command. Once the stack is up the same
   container runs `certbot renew` every 12 hours and nginx reloads daily to
   pick up the new files.

   If this host previously obtained its certificate with the webroot
   (HTTP-01) method, confirm the renewal config was switched over:

   ```sh
   docker compose -f docker-compose-nginx.yml run --rm certbot \
     certbot renew --dry-run --dns-cloudflare \
       --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini
   ```

4. **Cloudflare.** Set SSL/TLS mode to *Full (strict)* so Cloudflare
   validates the Let's Encrypt certificate on the origin.

## Releasing

1. Tag and push: `git tag v2.0.1.16 && git push origin v2.0.1.16`. The
   "Build and Push Tagged Docker Image" workflow builds `Dockerfile.prod`,
   pushes `thwar/fortyfives.net:<tag>` and `:latest`, and prints the image
   digest in the workflow's job summary.
2. On the host, set `APP_IMAGE=docker.io/thwar/fortyfives.net@sha256:<digest>`
   in `.env`. Digests are immutable; tags are not.
3. `docker compose -f docker-compose-nginx.yml pull web`
4. `docker compose -f docker-compose-nginx.yml up -d`

`web`'s entrypoint runs `bin/migrate`
(`Website45sV3.Release.migrate`) and then `bin/server`. `nginx` only starts
once `web` reports healthy on `GET /healthz`.

## Live sign-in check

The "Live sign-in check" workflow (`.github/workflows/live-check.yml`) runs
`python/live_check.py` against production every 30 minutes and on demand
(Actions → Live sign-in check → Run workflow). Run it after every deploy and
after changing any credential. It checks:

- `GET /healthz/auth`: Google accepts `GOOGLE_CLIENT_ID` and
  `GOOGLE_CLIENT_SECRET`; with Turnstile on, Cloudflare accepts
  `TURNSTILE_SECRET` and the latest real verification did not fail on it.
- `/auth/google` leads to Google's sign-in page, not its error page.
- With Turnstile on, its widget loads on the sign-in, registration and
  password-reset forms (a wrong site key or domain shows up as
  `error <code>`); with it off, the forms show no widget.

It does not sign in: it creates no accounts, Google blocks automated
sign-in, and Turnstile shows a script-driven browser an interactive
challenge. The full sign-up and password sign-in flow runs in the e2e
workflow (`python/auth_e2e.py`) instead. With Turnstile on, a secret that Cloudflare accepts but that belongs to a different
widget only shows up once visitors submit forms; `/healthz/auth` reports
`turnstile_verifications` as failing once tokens from three different IPs
have been rejected for the secret, until a token verifies again. A failed
check is cached for 30 seconds, a passing one for 5 minutes.

To run it locally: `python python/live_check.py --url https://fortyfives.net`.

Cloudflare challenges GitHub's runners ("Just a moment..."), so the workflow
sends the repository secret `LIVE_CHECK_TOKEN` as an `X-Live-Check` header,
and a Cloudflare custom rule (Security → WAF → Custom rules) lets it through:
expression `(http.host eq "fortyfives.net" and any(http.request.headers["x-live-check"][*] eq "<token>"))`,
action *Skip* with all remaining custom rules, rate limiting rules, managed
rules, Super Bot Fight Mode, Browser Integrity Check and Security Level
selected. Plain Bot Fight Mode on the Free plan cannot be skipped by a rule;
if it is on, turn it off (Security → Bots) or the check cannot pass.

### Turnstile

Cloudflare Turnstile on the sign-in, sign-up, password-reset and
confirmation-resend forms is off by default; the per-IP and per-account
rate limits in `config/config.exs` apply either way. To turn it on during a
bot wave, set `TURNSTILE_ENABLED=true` in `.env` (with `TURNSTILE_SECRET`,
and `TURNSTILE_SITE_KEY` when not the one in `config/config.exs`), run
`docker compose -f docker-compose-nginx.yml up -d web`, then run the live
check. The site key and secret must belong to the same widget.
`TURNSTILE_ENABLED` accepts `true`/`1`/`yes`/`on` and `false`/`0`/`no`/`off`
(any case, or empty for off); any other value stops the release from
booting. An empty `TURNSTILE_SITE_KEY` keeps the one in `config/config.exs`.

## Day 2

- **Logs:** `docker compose -f docker-compose-nginx.yml logs -f web` (json-file
  driver, 3 x 10 MB per container).
- **Health:** `docker compose -f docker-compose-nginx.yml ps` shows the
  healthcheck state of every service.
- **Backups:** `db_backup` runs SQLite's online backup once daily, verifies
  integrity, and keeps 14 days in `fortyfives_sqlite_backups`. The service mounts
  `scripts/backup-sqlite.sh`, so deploy that file alongside compose. Inspect
  `docker compose -f docker-compose-nginx.yml logs db_backup` for verification.
  Copy backups off-host too. To restore, stop `web` and `db_backup`, preserve the
  current database and its WAL/SHM files, install the selected backup as
  `/data/fortyfives.db` with `app` ownership, remove the old WAL/SHM from the
  active path, then restart. Rehearse on a separate volume first.
- **Cloudflare IP ranges:** the `set_real_ip_from` list in `nginx.conf` must
  match https://www.cloudflare.com/ips/; the comment above the list shows a
  one-liner that regenerates it. Reload with
  `docker compose -f docker-compose-nginx.yml exec nginx nginx -s reload`.
- **Rollback:** for releases already using SQLite, restore the previous image
  digest and recreate `web`. A PostgreSQL-era image cannot read SQLite; see the
  [migration rollback procedure](sqlite-migration.md) before reverting across
  the database switch.
