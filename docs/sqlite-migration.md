# SQLite migration and mobile release — 2026-10-02

## Scope and decisions

Ship the current mobile changes with SQLite, using a single Phoenix instance and
an external Docker volume mounted at `/data`. Keep the existing six migration
versions, adapting the initial user table to SQLite; build a fresh database and
copy data into it. Do not run these migrations against PostgreSQL.

- `ecto_sqlite3 ~> 0.25.0`, WAL, three connections, 8 MB cache per connection,
  5-second busy timeout, immediate write transactions, full synchronization.
- `username` and `email` use `NOCASE` collation for indexes and equality. This
  folds ASCII only. All 49 accounts in the rehearsal have ASCII usernames and
  email addresses. Future non-ASCII names require exact non-ASCII casing.
- Arrays/maps retain their Ecto types and are encoded as JSON; binary replay
  payloads and tokens stay binary. `replays.raw_bytes` remains an integer count.
- Database sandbox tests run sequentially. Non-database tests remain parallel.
- The replay upload transaction checks for a pruned parent under its write lock,
  since SQLite does not report foreign-key constraint names.
- Postgrex is available in development only for the one-off importer; the
  production release has no PostgreSQL driver or server requirement.

Adapter behavior: https://hexdocs.pm/ecto_sqlite3/Ecto.Adapters.SQLite3.html

## Rehearsal and validation

1. Save production compose/environment and a `pg_dump -Fc` in a private backup
   directory. Retain the old immutable image and database volume.
2. Restore a copy locally into a dedicated Postgres database, without touching
   the existing developer database.
3. Run `scripts/import_postgres.exs` with `mix run --no-start` and a fresh
   `DATABASE_PATH`. It verifies schema coverage, copies all seven application
   tables with their IDs, compares every decoded field, preserves sequence
   high-water marks, checks integrity/foreign keys, and checkpoints the WAL.
   It refuses to overwrite an existing destination. The application, mailers,
   and data-retention workers are never started during import.
4. Run ExUnit, JS tests, Credo, format/compile checks, mobile gameplay across ten
   viewports, public-page layout checks, and the production container locally.
5. Test the online SQLite backup and restore it into a separate release instance.

## Cutover

1. Build and test the release while the old site stays available.
2. Stop only `web`, allowing its shutdown hooks to finish. Take a final logical
   Postgres dump. Keep nginx/certbot and the Postgres volume unchanged.
3. Restore the final dump locally and repeat the verified import into a fresh
   SQLite file. Transfer only after checkpointing, with the importer stopped.
4. Create the external `fortyfives_app_data` Docker volume; install the database
   with ownership matching the release's `app` user.
5. Set `DATABASE_PATH=/data/fortyfives.db`, mount the volume on `web`, set the
   new immutable image, remove the database dependency, and start `web`.
6. Reload nginx to resolve the replacement container. Check `/healthz`, public
   pages, LiveView gameplay, mounted database, logs, and preserved data counts.
7. Start and verify the nightly backup service; stop the retained Postgres
   container after successful verification. Keep its volume for at least 14 days.

## Backup and rollback

`scripts/backup-sqlite.sh` runs SQLite's online backup, including committed WAL
writes, checks integrity before publishing the file, and keeps 14 days. A failure
exits the container and is visible in logs/restarts. Backups reside in a separate
volume. They protect against app mistakes but still share the VPS failure domain;
copy them off-host as well. Cutover dumps are also kept on the operator machine.

Before accepting writes, rollback is restoring the saved compose/environment,
starting Postgres, recreating the old web container, and reloading nginx. After
SQLite accepts writes, do not blindly switch back: that would lose new accounts,
tokens and analytics. Pause writes and reconcile those records first, or fix the
app while continuing to use SQLite. Never delete either data volume during rollback.
