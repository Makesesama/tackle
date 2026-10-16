import Config

# The connection is set in config/config.exs (localhost:5432 by default).
# The MIX_TEST_PARTITION suffix keeps partitioned test runs apart.
config :tackle_web, Tackle.Web.Repo,
  database: "tackle_web_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :tackle_web, Tackle.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "bPpe+RyJOGxKAeQ+20yOiyATeO6X353r3LT2vquHiQfQqqYxnaQ4B5sNlQGsIQho",
  server: false

config :tackle_web, Tackle.Web.Vault, key: "TEkLj/WCtz0rTpH6DDgn2+udfkiVk+Sk3ywbtSsJzzs="

config :tackle_web, Oban, testing: :manual

# Forge API calls go to Req.Test stubs; nothing reaches GitHub.
config :tackle_web, Tackle.Web.Forge.GitHub,
  api_url: "https://api.github.test",
  web_url: "https://github.test",
  req_options: [plug: {Req.Test, Tackle.Web.Forge.GitHub}]

config :ash, disable_async?: true

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
