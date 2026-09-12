defmodule Tackle.CLI.StandaloneTest do
  use ExUnit.Case, async: false

  alias Tackle.CLI.Standalone

  test "does not run the CLI outside a Burrito binary" do
    Process.flag(:trap_exit, true)
    previous = System.get_env("__BURRITO")
    System.delete_env("__BURRITO")

    on_exit(fn ->
      if previous, do: System.put_env("__BURRITO", previous), else: System.delete_env("__BURRITO")
    end)

    assert {:ok, pid} = Standalone.start_link(:ignored)
    assert_receive {:EXIT, ^pid, :normal}, 100
  end
end
