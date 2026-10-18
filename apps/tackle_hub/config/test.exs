import Config

# The connection is set in config/config.exs (localhost:5432 by default).
# The MIX_TEST_PARTITION suffix keeps partitioned test runs apart.
config :tackle_hub, Tackle.Hub.Repo,
  database: "tackle_hub_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :tackle_hub, Tackle.HubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "bPpe+RyJOGxKAeQ+20yOiyATeO6X353r3LT2vquHiQfQqqYxnaQ4B5sNlQGsIQho",
  server: false

config :tackle_hub, Tackle.Hub.Vault, key: "TEkLj/WCtz0rTpH6DDgn2+udfkiVk+Sk3ywbtSsJzzs="

config :tackle_hub, Oban, testing: :manual

# The setup token is read from Tackle.Hub.Setup.token/0, not the log.
config :tackle_hub, announce_setup: false

# Forge API calls go to Req.Test stubs; nothing reaches GitHub.
config :tackle_hub, Tackle.Hub.Forge.GitHub,
  api_url: "https://api.github.test",
  web_url: "https://github.test",
  req_options: [plug: {Req.Test, Tackle.Hub.Forge.GitHub}]

config :ash, disable_async?: true

# A write whose notification would be lost, so live pages miss it
# (Tackle.Hub.Updates), fails the test instead of logging a warning.
config :ash, missed_notifications: :raise

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
