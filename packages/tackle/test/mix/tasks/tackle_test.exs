defmodule Mix.Tasks.TackleTest do
  # Replaces PATH for the whole VM while it runs.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Tackle, as: TackleTask

  @cli_project Path.expand("../../../../../apps/tackle_cli", __DIR__)

  setup do
    directory =
      Path.join(System.tmp_dir!(), "tackle-mix-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    record = Path.join(directory, "invocation")
    mix = Path.join(directory, "mix")
    File.write!(mix, ~s(#!/bin/sh\nprintf '%s\\n' "$PWD" "$@" > "$TACKLE_TEST_MIX_RECORD"\n))
    File.chmod!(mix, 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", directory <> ":" <> path)
    System.put_env("TACKLE_TEST_MIX_RECORD", record)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      System.put_env("PATH", path)
      System.delete_env("TACKLE_TEST_MIX_RECORD")
      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(directory)
    end)

    %{record: record}
  end

  # The harness project ran its own DeepSeek login for these arguments,
  # prompting for the key with echo and bypassing the adapter's login.
  test "passes every command, logins included, to the CLI project", %{record: record} do
    for args <- [["auth", "login", "deepseek"], ["auth", "status"]] do
      assert :ok = TackleTask.run(args)
      assert File.read!(record) == Enum.join([@cli_project, "tackle" | args], "\n") <> "\n"
    end

    refute_received {:mix_shell, :prompt, _prompt}
  end
end
