defmodule Tackle.Lib.CommitterTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Committer
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree.Change

  defmodule ResultCommitter do
    @behaviour Tackle.Lib.Committer

    @impl true
    def commit(change, context) do
      send(self(), {:committed, change, context})

      case Process.get(:commit_result, :ok) do
        fun when is_function(fun, 0) -> fun.()
        result -> result
      end
    end
  end

  setup do
    Process.delete(:commit_result)
    :ok
  end

  test "commits through the state's committer with its session and context" do
    state = State.new(committer: ResultCommitter, context: %{user: "u"}, session_id: "s1")
    change = %Change{to_id: nil, revision: 1}

    assert :ok = Committer.commit(state, change)
    assert_received {:committed, ^change, %{session_id: "s1", context: %{user: "u"}}}
  end

  test "a state without a committer keeps changes in memory" do
    assert :ok = Committer.commit(State.new(), %Change{revision: 1})
  end

  test "every committer failure is a durable commit failure" do
    state = State.new(committer: ResultCommitter)

    for {result, reason} <- [
          {{:error, :disk_full}, :disk_full},
          {:done, {:unexpected_commit_result, :done}},
          {fn -> raise "boom" end, "boom"},
          {fn -> throw(:oops) end, {:throw, :oops}},
          {fn -> exit(:gone) end, {:exit, :gone}}
        ] do
      Process.put(:commit_result, result)

      assert {:error, {:durable_commit_failed, ^reason}} =
               Committer.commit(state, %Change{revision: 1})
    end
  end

  test "State.new/1 rejects a committer that cannot commit" do
    assert_raise ArgumentError, ~r/invalid :committer/, fn ->
      State.new(committer: Enum)
    end

    assert_raise ArgumentError, ~r/invalid :committer/, fn ->
      State.new(committer: NoSuchCommitter)
    end
  end
end
