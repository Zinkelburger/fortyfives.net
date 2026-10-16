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
| `backups/release-vX/` | — | Per-release record: `docker-compose.before.yml`, `env.before`, `previous-image`, `new-image`, `started`, `activated` (UTC). |
| `docker-compose.sqlite.yml` | — | Leftover from the SQLite cutover; not used. |

- Docker volumes (all `external`): `fortyfives_app_data` (the SQLite
  database, `/data/fortyfives.db` in `web`), `fortyfives_sqlite_backups`
  (`/backups` in `db_backup`), `fortyfives_db_data` (old PostgreSQL data,
  only for the `postgres-rollback` profile).
- TLS: Let's Encrypt certificates in `/etc/letsencrypt` on the host, renewed
  by `certbot` over HTTP (webroot `./certbot/www`, served by nginx at
  `/.well-known/acme-challenge/`). nginx reloads every 24h to pick them up.
- Cloudflare proxies the site, but the server also answers direct requests.
  nginx trusts `CF-Connecting-IP` only from Cloudflare's ranges (listed in
  `site.conf`) and overwrites `CF-Connecting-IP`, `X-Forwarded-For` and
  `X-Real-IP` with the result, which Phoenix uses as the client IP
  (`Turnstile.client_ip/1`) for rate limits. If Cloudflare adds ranges
  (https://www.cloudflare.com/ips), visitors on them share their edge's IP
  until the list is updated.

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

Database backups are kept on the host itself, so a lost host takes them
with it unless they were copied elsewhere.
