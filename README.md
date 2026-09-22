# Fortyfives.net
A website for the card game 45s. <https://fortyfives.net>

## Local development

Prerequisites:

- Elixir 1.19 and Erlang/OTP 27 — the exact versions are pinned in
  `.tool-versions` (`asdf install` or `mise install` picks them up).
- PostgreSQL 15 with the `citext` extension available (the migrations enable
  it). Development expects `postgres` / `postgres` on `localhost:5432`;
  override with the `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_HOST`,
  `DATABASE_PORT` and `DATABASE_NAME` environment variables (see
  `config/dev.exs`).

```sh
mix setup        # deps, database, migrations, JS/CSS toolchain
mix phx.server   # http://localhost:4000
mix test
```

Set `MIX_TEST_PARTITION=<name>` to give a test run its own database when
several people share one Postgres.

### Selenium bots

`python/` holds end-to-end bots that drive the real site in headless Chrome:
`wait_play.py` checks that the queue page loads and join/leave works, and
`tbot.py` joins the public queue and plays a whole game. Four `tbot.py`
instances together fill a table. They need Chrome and a matching
`chromedriver` (found on `PATH` or at `/usr/local/bin/chromedriver`).

```sh
python3 -m venv .venv && source .venv/bin/activate
pip install -r python/requirements.txt

mix phx.server                       # in another terminal
python python/wait_play.py           # smoke check
for n in 1 2 3 4; do
  TBOT_INSTANCE=$n python python/tbot.py &
done
wait
```

`APP_BASE_URL` (default `http://localhost:4000/play`) points the bots at
another server; failing bots write a screenshot and page source to
`artifacts/` (`TBOT_ARTIFACT_DIR`).

## Quality checks

CI runs these; run them locally before pushing:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix sobelow
mix test --cover
```

## Deploying

1. Copy `.env.example` to `.env` and replace every `CHANGE_ME` value.
2. Generate `SECRET_KEY_BASE` with `mix phx.gen.secret`.
3. Set `APP_IMAGE` to the immutable digest printed by the release build.
4. Start the TLS-terminating stack:

   `docker compose -f docker-compose-nginx.yml up -d`

Do not commit `.env`. The database is intentionally not published on a host
port. First-time setup (database volume, TLS certificate, backups, rollback)
is documented in [docs/deploy.md](docs/deploy.md).

For local app-only access, `docker-compose.yml` binds the Phoenix port to
`127.0.0.1`; place a TLS reverse proxy in front before exposing it publicly.

## Gameplay analytics

Two things are recorded, both first-party and both bounded:

- **Game event logs** – every deal, bid, discard, card, trick, score, idle
  timeout, disconnect and abandonment, with millisecond timing and whether a
  bot or a human acted. Kept by `GameController`, written gzipped to
  `game_logs.events` when the game ends (2–3 KB per game). The summary columns
  (`ended`, `winner`, `hands`, scores, `duration_ms`, `human_count`) are
  plain and queryable.
- **Session replays** – the game page records itself with
  [rrweb](https://github.com/rrweb-io/rrweb) (DOM, clicks, sampled mouse
  movement; all inputs masked) and ships batches over the LiveView socket;
  they are stored gzipped in `replays`/`replay_chunks`. Only `/game/:id` is
  recorded, and never an IP address or account: a replay is tied to the game
  and the anonymous seat id. `REPLAY_RECORDING=false` switches it off.

Retention (`config :website_45s_v3, Website45sV3.Analytics`): replays are
deleted after 60 days or once total storage passes 2 GB (oldest first); event
logs are dropped after a year, keeping the summary row. The
`Website45sV3.Analytics.Pruner` process applies this daily.

`/admin` (usernames listed in `ADMIN_USERNAMES`) lists games, shows each
game's timeline merged with the clicks from its replays (the text meant for
reading or for handing to a model), and plays replays back with rrweb-player.

Please see [structure.md](structure.md) to see the website's structure

# Resources Used
https://github.com/SportsDAO/playing-card/tree/master
He doesn't have a license on his cards

https://github.com/vcjhwebdev/blackjack
This is the red back of the cards. It also has no license.
