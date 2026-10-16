import Config

# The local cluster from `scripts/db.sh start`, or TACKLE_WEB_PGHOST. The
# MIX_TEST_PARTITION suffix keeps partitioned test runs apart.
config :tackle_web, Tackle.Web.Repo,
  username: "postgres",
  database: "tackle_web_test#{System.get_env("MIX_TEST_PARTITION")}",
  socket_dir: System.get_env("TACKLE_WEB_PGHOST", Path.expand("../.postgres", __DIR__)),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :tackle_web, Tackle.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "bPpe+RyJOGxKAeQ+20yOiyATeO6X353r3LT2vquHiQfQqqYxnaQ4B5sNlQGsIQho",
  server: false

config :tackle_web, Tackle.Web.Vault, key: "TEkLj/WCtz0rTpH6DDgn2+udfkiVk+Sk3ywbtSsJzzs="

config :tackle_web, Oban, testing: :manual

config :ash, disable_async?: true

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
