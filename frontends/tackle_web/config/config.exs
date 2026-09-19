# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tackle_web,
  namespace: Tackle.Web,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :tackle_web, Tackle.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Tackle.Web.ErrorHTML, json: Tackle.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tackle.Web.PubSub,
  live_view: [signing_salt: "BYdTUWHK"]

# Configure esbuild (the version is required). Kept in sync with the nixpkgs
# esbuild that NixOS builds use, so the version check does not warn.
config :esbuild,
  version: "0.27.2",
  tackle_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required). Kept in sync with the nixpkgs
# tailwindcss_4 that NixOS builds use, so the version check does not warn.
config :tailwind,
  version: "4.3.3",
  tackle_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Elixir's standard-library JSON module (no Jason dependency).
config :phoenix, :json_library, JSON

# Tree-sitter theme used to highlight the diff. Any name returned by
# Lumis.available_themes/0 is accepted.
config :tackle_web, highlight_theme: "github_light"

# Model the review assistant runs when a conversation does not pick one, as a
# canonical "adapter/model" reference built from the provider plugins' ids.
# Requires credentials for that provider: `openai-codex/*` uses the ChatGPT
# session stored by `mix tackle auth`, `deepseek/*` an API key.
config :tackle_web, agent_model: "openai-codex/gpt-5.6-terra"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
