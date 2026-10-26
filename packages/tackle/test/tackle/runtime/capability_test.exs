defmodule Tackle.Runtime.CapabilityTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Runtime
  alias Tackle.Runtime.Limits
  alias Tackle.Tools.Subagent

  test "the subagent tool is never part of the default tool set" do
    refute Subagent in Tackle.Tools.default()
  end

  test "declaring trusted profiles does not inject the subagent tool" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

    assert {:ok, snapshot} = Tackle.snapshot(scope.root_agent_ref)
    refute Subagent in State.tools(snapshot.agent_state)
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
               %{runtime: authorized.root_agent_ref}
             )

    unauthorized =
      start_scope(
        root: [allow_delegation: false, tools: [Tackle.Tools.Subagent]],
        profiles: %{"worker" => agent_spec("worker")}
      )

    assert {:error, message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work"},
               %{runtime: unauthorized.root_agent_ref}
             )

    assert message =~ "not permitted"

    profileless = start_scope(root: [allow_delegation: true, tools: [Tackle.Tools.Subagent]])

    assert {:error, message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work"},
               %{runtime: profileless.root_agent_ref}
             )

    assert message =~ "unknown subagent profile"
  end

  test "a child agent's tools see the grant the coordinator gave it" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{
          "worker" => agent_spec("worker", mode: :block),
          "lead" => agent_spec("lead", mode: :block, allow_delegation: true)
        }
      )

    {:ok, worker} = Runtime.request_agent(scope.root_agent_ref, "worker", "wait")
    {:ok, lead} = Runtime.request_agent(scope.root_agent_ref, "lead", "wait")

    # A profile without delegation stays without it under a delegating parent.
    assert {:error, :delegation_not_allowed} = Runtime.delegation_limits(worker.agent_ref)

    assert {:error, message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work"},
               %{runtime: worker.agent_ref}
             )

    assert message =~ "not permitted"

    # A delegating profile under a delegating parent gets the scope's limits.
    assert {:ok, %Limits{} = limits} = Runtime.delegation_limits(lead.agent_ref)
    assert {:ok, %{limits: ^limits}} = Runtime.scope_snapshot(scope.scope_ref)

    Runtime.cancel(worker)
    Runtime.cancel(lead)
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
