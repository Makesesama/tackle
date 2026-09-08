import Config

if config_env() == :test do
  test_home =
    Path.join(
      System.tmp_dir!(),
      "tackle-test-#{System.unique_integer([:positive, :monotonic])}"
    )

  config :tackle, auth_file: Path.join(test_home, "auth.json")
end
