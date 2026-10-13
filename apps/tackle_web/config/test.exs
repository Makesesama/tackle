import Config

# The harness auth store resolves its file once at application boot, and
# dependency config is not loaded for this Mix project. Pin it, and the
# `TACKLE_HOME` that provider resolution reads config.json from, to a
# throwaway home so the suite never reads the developer's real credentials,
# accounts, or configured providers.
tackle_test_home =
  Path.join(
    System.tmp_dir!(),
    "tackle-web-test-#{System.unique_integer([:positive, :monotonic])}"
  )

System.put_env("TACKLE_HOME", tackle_test_home)
config :tackle, auth_file: Path.join(tackle_test_home, "auth.json")

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tackle_web, Tackle.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "asM2Vz1odX43Ka5cPDtoQK3q71Nm63IZmVpy7BR0vrlLCk15I+v+VT1p21oJDxfQ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
