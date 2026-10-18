defmodule Tackle.Elixir.CompileGateLoopTest do
  # The gate inside the agent loop: a scripted model writes a broken module
  # with the real `write` tool, the gate reports the compile error from the
  # project node, and the turn continues until the model's repair compiles.
  use ExUnit.Case, async: true

  alias Tackle.Elixir.CompileGate
  alias Tackle.Elixir.CompileGate.Settings
  alias Tackle.Elixir.Test.Projects
  alias Tackle.Lib.Loop

  @moduletag timeout: 120_000

  defmodule ScriptedAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "scripted"

    @impl true
    def models, do: ["model"]

    @impl true
    def generate(_schema, _opts) do
      calls = Process.get(:llm_calls, 0)
      Process.put(:llm_calls, calls + 1)
      {:ok, %{data: answer(calls), usage: nil, model: "model"}}
    end

    defp answer(0), do: write("defmodule A do\n  def a, do: missing()\nend\n")
    defp answer(1), do: %{"content" => "Done."}
    defp answer(2), do: write("defmodule A do\n  def a, do: :a\nend\n")
    defp answer(_calls), do: %{"content" => "Fixed."}

    defp write(content) do
      %{
        "tool_calls" => [
          %{
            "id" => "w#{System.unique_integer([:positive])}",
            "name" => "write",
            "arguments" => %{"path" => "lib/a.ex", "content" => content}
          }
        ]
      }
    end
  end

  test "a compile error continues the turn until it is repaired" do
    root = Projects.new(%{"lib/a.ex" => "defmodule A do\n  def a, do: :a\nend\n"})
    {:ok, llm} = Tackle.Lib.LLM.select([ScriptedAdapter], "scripted/model")
    {:ok, settings} = Settings.new(nil)

    state =
      Tackle.Lib.new(
        llm: llm,
        tools: [Tackle.Tools.Write],
        hooks: [CompileGate],
        context: %{cwd: root, compile_gate: settings}
      )

    assert {:ok, state} = Loop.run(state, "Change module A")

    assert [:user, :assistant, :tool, :assistant, :user, :assistant, :tool, :assistant] =
             Enum.map(state.messages, & &1.role)

    gate_message = Enum.at(state.messages, 4).content
    assert gate_message =~ "Compile check"
    assert gate_message =~ "undefined function missing/0"
    assert gate_message =~ "└─ lib/a.ex:2:"
    assert List.last(state.messages).content == "Fixed."
    assert File.read!(Path.join(root, "lib/a.ex")) =~ "def a, do: :a"
    refute Map.has_key?(state.context, :compile_gate_turn)
  end
end
