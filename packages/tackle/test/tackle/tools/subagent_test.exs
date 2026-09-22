defmodule Tackle.Tools.SubagentTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Event
  alias Tackle.Tools.Subagent

  test "the subagent tool is opt-in, not part of the default tool set" do
    refute Subagent in Tackle.Tools.default()
  end

  test "delegates to an allowlisted profile and returns its answer" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", content: "worker answer")}
      )

    handle = handle(scope)
    test_pid = self()
    context = %{runtime: handle, event_callback: fn event -> send(test_pid, {:event, event}) end}

    assert {:ok, "worker answer"} =
             Subagent.run(%{"profile" => "worker", "prompt" => "do work"}, context)

    assert_receive {:event,
                    %{
                      type: :subagent_started,
                      data: %{profile: "worker", model: "test/echo", status: :running}
                    }}

    assert_receive {:event,
                    %Event{
                      type: :subagent_progress,
                      data: %{
                        run_id: run_id,
                        profile: "worker",
                        model: "test/echo",
                        event: %Event{type: :message_end, data: %{role: :user}}
                      }
                    }},
                   2_000

    assert is_binary(run_id)
    assert_receive {:event, %{type: :subagent_finished}}, 2_000
  end

  test "rejects delegation when recursion is not granted" do
    scope =
      start_scope(
        root: [allow_delegation: false],
        profiles: %{"worker" => agent_spec("worker")}
      )

    context = %{runtime: handle(scope, allow_delegation: false)}

    assert {:error, message} =
             Subagent.run(%{"profile" => "worker", "prompt" => "do work"}, context)

    assert message =~ "not permitted"
  end

  test "rejects unknown profiles by name" do
    scope = start_scope(root: [allow_delegation: true])
    context = %{runtime: handle(scope)}

    assert {:error, message} =
             Subagent.run(%{"profile" => "ghost", "prompt" => "do work"}, context)

    assert message =~ "unknown subagent profile"
  end

  test "rejects a missing runtime handle" do
    assert {:error, message} =
             Subagent.run(%{"profile" => "worker", "prompt" => "go"}, %{})

    assert message =~ "no runtime handle"
  end

  test "an agent can call the subagent tool through the loop" do
    tool_call = %{
      "id" => "call_1",
      "name" => "subagent",
      "arguments" => %{"profile" => "worker", "prompt" => "do the work"}
    }

    scope =
      start_scope(
        root: [
          allow_delegation: true,
          tools: [Tackle.Tools.Subagent],
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "final answer"]
        ],
        profiles: %{"worker" => agent_spec("worker", content: "worker answer")}
      )

    {:ok, session} = Tackle.Runtime.session_pid(scope.root_agent_ref)
    {:ok, %{session_id: session_id}} = Tackle.Session.subscribe(session)

    assert {:ok, turn_id} = Tackle.Runtime.submit(scope.root_agent_ref, "delegate the work")

    assert_receive {:tackle_event, ^session_id, ^turn_id,
                    %{
                      type: :subagent_started,
                      data: %{
                        tool_call_id: "call_1",
                        profile: "worker",
                        model: "test/echo",
                        status: :running
                      }
                    }},
                   5_000

    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000
    assert Tackle.Lib.last_answer(state) == "final answer"

    tools_used =
      Enum.map(state.messages, & &1.tool_calls) |> List.flatten() |> Enum.reject(&is_nil/1)

    assert Enum.any?(tools_used, &(&1.name == "subagent"))
  end

  test "a delegated failure remains visible in the parent tool transcript" do
    tool_call = %{
      "id" => "call_failure",
      "name" => "subagent",
      "arguments" => %{"profile" => "worker", "prompt" => "do the work"}
    }

    scope =
      start_scope(
        root: [
          allow_delegation: true,
          tools: [Tackle.Tools.Subagent],
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "recovered"]
        ],
        profiles: %{"worker" => agent_spec("worker", mode: :error)}
      )

    {:ok, session} = Tackle.Runtime.session_pid(scope.root_agent_ref)
    {:ok, %{session_id: session_id}} = Tackle.Session.subscribe(session)
    assert {:ok, turn_id} = Tackle.Runtime.submit(scope.root_agent_ref, "delegate the work")

    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000

    tool_result =
      Enum.find(state.messages, &(&1.role == :tool and &1.tool_call_id == "call_failure"))

    assert tool_result.content =~ "Error: subagent failed:"
    assert tool_result.content =~ "adapter_error"
    refute tool_result.content == "Error: The tool failed while completing the request."
  end

  test "a delegated run failure is reported to the calling agent as a tool error" do
    tool_call = %{
      "id" => "call_1",
      "name" => "subagent",
      "arguments" => %{"profile" => "worker", "prompt" => "do the work"}
    }

    scope =
      start_scope(
        root: [
          allow_delegation: true,
          tools: [Tackle.Tools.Subagent],
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "recovered"]
        ],
        profiles: %{"worker" => agent_spec("worker", mode: :error)}
      )

    handle = handle(scope)

    assert {:error, message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "go"},
               %{runtime: handle}
             )

    assert message =~ "subagent failed"
  end
end
