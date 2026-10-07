defmodule Tackle.Exec.ClientEnvTest do
  # Changes the host VM's environment, so it cannot run concurrently.
  use ExUnit.Case, async: false

  import Tackle.Exec.TestSupport

  alias Tackle.Exec.Client

  setup do
    System.put_env("TACKLE_EXEC_TEST_SECRET", "leaked")
    on_exit(fn -> System.delete_env("TACKLE_EXEC_TEST_SECRET") end)
  end

  test "the launcher does not inherit host environment variables by default" do
    client = start_supervised!({Client, launcher: server_launcher()})

    assert {:ok, 0, "unset\n"} =
             run(client, ["sh", "-c", "echo ${TACKLE_EXEC_TEST_SECRET:-unset}"], cwd: "/")
  end

  test "variables named in :keep_env are passed to the launcher" do
    client =
      start_supervised!(
        {Client, launcher: server_launcher(), keep_env: ["PATH", "TACKLE_EXEC_TEST_SECRET"]}
      )

    assert {:ok, 0, "leaked\n"} =
             run(client, ["sh", "-c", "echo ${TACKLE_EXEC_TEST_SECRET:-unset}"], cwd: "/")
  end
end
