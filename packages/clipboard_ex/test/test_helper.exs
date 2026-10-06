# Tests tagged :system_clipboard read and overwrite the real clipboard of the
# current desktop session. Opt in with `mix test --include system_clipboard`.
ExUnit.start(exclude: [:system_clipboard])
