defmodule Tackle.Runtime.CapabilityTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Message
  alias Tackle.Tools.Subagent

  test "the subagent tool is never part of the default tool set" do
    refute Subagent in Tackle.Tools.default()
  end

  test "declaring trusted profiles does not inject the subagent tool" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

    assert {:ok, snapshot} = Tackle.snapshot(scope.root_agent_ref)
    refute Subagent in snapshot.agent_state.tools
  end

  test "delegation requires the grant and a matching trusted profile" do
    authorized =
      start_scope(
        root: [allow_delegation: true, tools: [Tackle.Tools.Subagent]],
        profiles: %{"worker" => agent_spec("worker", content: "worker answer")}
      )

    assert {:ok, "worker answer"} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work"},
               %{runtime: handle(authorized)}
             )

    unauthorized =
      start_scope(
        root: [allow_delegation: false, tools: [Tackle.Tools.Subagent]],
        profiles: %{"worker" => agent_spec("worker")}
      )

    assert {:error, message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work"},
               %{runtime: handle(unauthorized, allow_delegation: false)}
             )

    assert message =~ "not permitted"

    profileless = start_scope(root: [allow_delegation: true, tools: [Tackle.Tools.Subagent]])

    assert {:error, message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work"},
               %{runtime: handle(profileless)}
             )

    assert message =~ "unknown subagent profile"
  end

  test "the loop reports the subagent tool as unknown when the agent config omits it" do
    tool_call = %{
      "id" => "call_1",
      "name" => "subagent",
      "arguments" => %{"profile" => "worker", "prompt" => "do the work"}
    }

    scope =
      start_scope(
        root: [
          allow_delegation: true,
          tools: [],
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "recovered"]
        ],
        profiles: %{"worker" => agent_spec("worker", content: "worker answer")}
      )

    assert {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "delegate the work")

    assert_receive {:tackle_turn_finished, session_id, ^turn_id, {:ok, state}}, 5_000
    assert session_id == snapshot.session_id

    assert Enum.any?(state.messages, fn
             %Message{role: :tool, content: content} -> content =~ "Unknown tool: subagent"
             _message -> false
           end)
  end
end
