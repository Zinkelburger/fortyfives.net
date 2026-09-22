import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :website_45s_v3, Website45sV3.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "website_45s_v3_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :website_45s_v3, Website45sV3Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "fDW+HKtRqa7XRlMZ40SZHdbm+B/fNLeCQtqSbtuCeez9horLpJE9Bl9hCxG82aYV",
  server: false

# In test we don't send emails.
config :website_45s_v3, Website45sV3.Mailer, adapter: Bamboo.TestAdapter

# Shrink the game's cosmetic delays so tests can drive a full game quickly.
# Idle/discard timeouts stay long so tests control every move themselves.
config :website_45s_v3, :game_timings,
  bot_move_delay: 10,
  trick_transition: 10,
  scoring_display: 10

# Disable Turnstile entirely in tests (no widget, no verification)
config :website_45s_v3, :turnstile_site_key, nil

# Keep the token sweeper from running inside a test run; its first sweep
# would happen outside the Ecto sandbox.
config :website_45s_v3, Website45sV3.Accounts.TokenSweeper, initial_delay_ms: :timer.hours(1)
config :website_45s_v3, Website45sV3.Analytics.Pruner, initial_delay_ms: :timer.hours(1)

# Tests that need an admin set the list themselves.
config :website_45s_v3, :admin_user_ids, []

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# The suite adds far more bots from loopback than one visitor could; the
# per-network bot budget has its own tests in rate_limiter_test.exs.
config :website_45s_v3, :security_rate_limits, bots: [max_ip: 100_000]
