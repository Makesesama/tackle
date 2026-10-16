import Config

# The local cluster from `scripts/db.sh start`: Unix socket only, trust
# authentication, under this directory. TACKLE_WEB_PGHOST points elsewhere.
config :tackle_web, Tackle.Web.Repo,
  username: "postgres",
  database: "tackle_web_dev",
  socket_dir: System.get_env("TACKLE_WEB_PGHOST", Path.expand("../.postgres", __DIR__)),
  show_sensitive_data_on_connection_error: true,
  stacktrace: true,
  pool_size: 10

config :tackle_web, Tackle.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "ACGlsjaMaEmPiXEmHwo6RnlEmx73QvcTo0llVxAF8u5K87TKRRkLeN3rZi33p3Bz"

# Development only; production reads TACKLE_WEB_CLOAK_KEY (config/runtime.exs).
config :tackle_web, Tackle.Web.Vault, key: "X1eRkrgX2iWqi9iK89cTjfYuFSX4Ywv+AwjL9iWHcPM="

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
