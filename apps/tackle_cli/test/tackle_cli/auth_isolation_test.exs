defmodule Tackle.CLI.AuthIsolationTest do
  @moduledoc false

  # The auth store is a singleton that resolves its file once at application
  # boot, so per-test TACKLE_HOME overrides cannot redirect it. This guards the
  # test-config pin that keeps the suite away from the developer's real
  # credentials; without it every Tackle.Auth.put leaked into ~/.tackle/auth.json.
  use ExUnit.Case, async: true

  test "the booted auth store is pinned to a throwaway test home" do
    state = :sys.get_state(Tackle.Auth.Store)

    assert state.path == Application.get_env(:tackle, :auth_file)
    assert String.starts_with?(state.path, System.tmp_dir!())
  end
end
