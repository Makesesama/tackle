import Config

config :tackle_lib, cancellation_store: Tackle.Runtime.CancellationStore
config :tackle_runtime, default_backend: Tackle.Runtime.RootBackend

if config_env() == :test do
  test_home =
    Path.join(
      System.tmp_dir!(),
      "tackle-test-#{System.unique_integer([:positive, :monotonic])}"
    )

  # Durable sessions must never touch a developer's real TACKLE_HOME during
  # tests. Setting the environment variable here runs before the application
  # (and its session catalog) starts.
  System.put_env("TACKLE_HOME", test_home)

  config :tackle, auth_file: Path.join(test_home, "auth.json")
end
