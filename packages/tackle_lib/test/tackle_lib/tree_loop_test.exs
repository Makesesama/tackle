defmodule Tackle.Lib.TreeLoopTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Loop
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree

  defmodule CapturingAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      send(Process.get(:test_pid), {:messages, Keyword.get(opts, :messages)})

      {:ok, %{data: %{"content" => "answer"}, usage: nil, model: "test/model"}}
    end
  end

  setup do
    previous = Application.get_env(:tackle_lib, :llm)
    Application.put_env(:tackle_lib, :llm, CapturingAdapter)
    Process.put(:test_pid, self())

    on_exit(fn ->
      if previous do
        Application.put_env(:tackle_lib, :llm, previous)
      else
        Application.delete_env(:tackle_lib, :llm)
      end
    end)
  end

  test "a branch switch sends only the active path to the provider" do
    state = State.new(tree: true, model: "test/model")
    assert {:ok, state} = Loop.run(state, "first question")

    assert_receive {:messages, first_call}
    assert Enum.map(first_call, & &1.content) == ["first question"]

    assert {:ok, state, _outcome} = Tackle.Lib.navigate(state, nil)
    assert {:ok, state} = Loop.run(state, "second question")

    assert_receive {:messages, second_call}
    assert Enum.map(second_call, & &1.content) == ["second question"]

    # Both branches survive; the first is untouched by the second.
    assert Tree.size(state.tree) == 4
    assert Enum.map(Tree.transcript(state.tree), & &1.content) == ["second question", "answer"]

    {:ok, tree} = Tree.move(state.tree, nil)
    assert Enum.map(Tree.children(tree, nil), & &1.id) |> length() == 2
  end
end
