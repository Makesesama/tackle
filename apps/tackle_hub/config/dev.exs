import Config

# The connection is set in config/config.exs (localhost:5432 by default).
config :tackle_hub, Tackle.Hub.Repo,
  database: "tackle_hub_dev",
  show_sensitive_data_on_connection_error: true,
  stacktrace: true,
  pool_size: 10

config :tackle_hub, Tackle.HubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "ACGlsjaMaEmPiXEmHwo6RnlEmx73QvcTo0llVxAF8u5K87TKRRkLeN3rZi33p3Bz"

# Development only; production reads TACKLE_HUB_CLOAK_KEY (config/runtime.exs).
config :tackle_hub, Tackle.Hub.Vault, key: "X1eRkrgX2iWqi9iK89cTjfYuFSX4Ywv+AwjL9iWHcPM="

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
