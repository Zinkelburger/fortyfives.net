# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :website_45s_v3,
  ecto_repos: [Website45sV3.Repo],
  security_rate_limits: [
    login: [window_ms: 15 * 60 * 1000, max_ip: 30, max_account: 8],
    queue: [window_ms: 60 * 60 * 1000, max_ip: 40, max_create_ip: 10],
    registration: [window_ms: 60 * 60 * 1000, max_ip: 5],
    email: [window_ms: 60 * 60 * 1000, max_ip: 20, max_address: 5]
  ]

# Configures the endpoint
config :website_45s_v3, Website45sV3Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "fortyfives.net"],
  render_errors: [
    formats: [html: Website45sV3Web.ErrorHTML, json: Website45sV3Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Website45sV3.PubSub,
  live_view: [signing_salt: "ZuJ162sV"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :website_45s_v3, Website45sV3.Mailer, adapter: Bamboo.LocalAdapter

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.9",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.17",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}
  ]

# Cloudflare Turnstile. The site key is public; the secret comes from the
# TURNSTILE_SECRET environment variable (see config/runtime.exs). Dev and
# test override the site key below.
config :website_45s_v3, :turnstile_site_key, "0x4AAAAAAEHE4t36ytfkThN8"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
