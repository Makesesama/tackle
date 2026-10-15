import Config

# The auth store resolves its file once at application boot, before any test
# can redirect TACKLE_HOME, and dependency config is not loaded for this Mix
# project (packages/tackle/config/config.exs only protects its own suite).
# Pin both to a throwaway home so this suite never reads or writes the
# developer's real credentials.
test_home =
  Path.join(
    System.tmp_dir!(),
    "tackle-cli-test-#{System.unique_integer([:positive, :monotonic])}"
  )

System.put_env("TACKLE_HOME", test_home)
config :tackle, auth_file: Path.join(test_home, "auth.json")

# Tests that open the TUI through `Run` should not start background
# journal compression passes.
config :tackle_cli, compress_idle_sessions: false

# Tests drive the TUI through `test_mode`, so there is no interactive terminal
# to hand off to crossterm's reader. Once a local-transport app has run in the
# suite the BEAM's `:user_drv_reader` exists but cannot ack the handoff, and
# every later TUI start would wait out the handoff's 1s ack timeout.
config :ex_ratatui, detach_local_input: false

# Highlighting would download tree-sitter parsers from the network; the
# suite exercises the parser and merge logic with a fake backend instead.
config :tackle_cli, highlight: false
