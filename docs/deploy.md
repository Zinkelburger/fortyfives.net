# Deploying fortyfives.net

The site runs as a Phoenix release in Docker behind nginx, with Cloudflare in
front. Everything below happens on the host in a checkout of this repository
(or a directory containing `docker-compose-nginx.yml`, `nginx.conf` and `.env`).

## Files

| File | Purpose |
| --- | --- |
| `docker-compose-nginx.yml` | Production stack: `web`, `db`, `db_backup`, `nginx`, `certbot` |
| `docker-compose.yml` | App + database only, Phoenix bound to `127.0.0.1:4000` (local testing of a release image) |
| `nginx.conf` | TLS termination and reverse proxy; Cloudflare real-IP list |
| `.env.example` | Template for `.env`; copy it and replace every `CHANGE_ME` |
| `Dockerfile.prod` | Release image built and pushed by the "Build and Push" workflow on `v*` tags |

## One-time host bootstrap

1. **Environment.** `cp .env.example .env`, fill in every value. All third-party
   credentials (`TURNSTILE_SECRET`, `AWS_*`, `GOOGLE_*`) are required and must
   be non-empty; the release refuses to boot without them. `CF_API_TOKEN` is a
   Cloudflare API token scoped to the `fortyfives.net` zone with
   `Zone:DNS:Edit` and `Zone:Zone:Read`; certbot uses it for DNS-01 challenges.

2. **Database volume.** The data volume is declared `external` so that
   `docker compose down -v` can never delete it. Create it once:

   ```sh
   docker volume create fortyfives_db_data
   ```

   If you are migrating an existing host whose data lives in the old
   compose-managed volume (`docker volume ls | grep db_data`, typically
   `<dirname>_db_data`), copy it across with the stack stopped:

   ```sh
   docker compose -f docker-compose-nginx.yml down
   docker run --rm -v <old_volume>:/from:ro -v fortyfives_db_data:/to alpine \
     sh -c 'cd /from && cp -a . /to'
   ```

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

1. Tag and push: `git tag v2.0.1.10 && git push origin v2.0.1.10`. The
   "Build and Push Tagged Docker Image" workflow builds `Dockerfile.prod`,
   pushes `thwar/fortyfives.net:<tag>` and `:latest`, and prints the image
   digest in the workflow's job summary.
2. On the host, set `APP_IMAGE=docker.io/thwar/fortyfives.net@sha256:<digest>`
   in `.env`. Digests are immutable; tags are not.
3. `docker compose -f docker-compose-nginx.yml pull web`
4. `docker compose -f docker-compose-nginx.yml up -d`

`web`'s entrypoint waits for Postgres, runs `bin/migrate`
(`Website45sV3.Release.migrate`) and then `bin/server`. `nginx` only starts
once `web` reports healthy on `GET /healthz`.

## Day 2

- **Logs:** `docker compose -f docker-compose-nginx.yml logs -f web` (json-file
  driver, 3 x 10 MB per container).
- **Health:** `docker compose -f docker-compose-nginx.yml ps` shows the
  healthcheck state of every service.
- **Backups:** `db_backup` runs `pg_dump -Fc` once a day into the
  `fortyfives_db_backups` volume and deletes dumps older than 14 days. Copy
  them off-host, e.g.
  `docker run --rm -v fortyfives_db_backups:/b:ro alpine tar cz -C /b . > backups.tgz`.
  Restore with
  `docker compose -f docker-compose-nginx.yml exec -T db sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean' < file.dump` (single quotes so the variables expand inside the container, not on the host)
  (with the dump copied into the container or piped from the backup volume).
- **Cloudflare IP ranges:** the `set_real_ip_from` list in `nginx.conf` must
  match https://www.cloudflare.com/ips/; the comment above the list shows a
  one-liner that regenerates it. Reload with
  `docker compose -f docker-compose-nginx.yml exec nginx nginx -s reload`.
- **Rollback:** point `APP_IMAGE` at the previous digest and `up -d` again.
  Migrations are forward-only; use `bin/website_45s_v3 eval
  'Website45sV3.Release.rollback(Website45sV3.Repo, <version>)'` if one has
  to be undone.
