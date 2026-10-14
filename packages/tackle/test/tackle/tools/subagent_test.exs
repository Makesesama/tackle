defmodule Tackle.Tools.SubagentTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Event
  alias Tackle.Runtime.Limits
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

    agent_ref = scope.root_agent_ref
    test_pid = self()

    context = %{
      runtime: agent_ref,
      event_callback: fn event -> send(test_pid, {:event, event}) end
    }

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

  test "an optional model argument selects the child's model for one run" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", content: "worker answer")}
      )

    test_pid = self()

    context = %{
      runtime: scope.root_agent_ref,
      event_callback: fn event -> send(test_pid, {:event, event}) end
    }

    args = %{"profile" => "worker", "prompt" => "do work"}

    assert {:ok, "worker answer"} = Subagent.run(Map.put(args, "model", "test/child"), context)
    assert_receive {:adapter_called, _pid, "child", _opts}, 2_000
    assert_receive {:event, %{type: :subagent_started, data: %{model: "test/child"}}}

    assert {:ok, "worker answer"} = Subagent.run(Map.put(args, "model", ""), context)
    assert_receive {:adapter_called, _pid, "echo", _opts}, 2_000

    assert {:error, "model must be a provider/model string"} =
             Subagent.run(Map.put(args, "model", 42), context)

    assert {:error, message} = Subagent.run(Map.put(args, "model", "missing/model"), context)
    assert message =~ "could not start subagent with model missing/model"
    refute_received {:adapter_called, _pid, _model, _opts}
  end

  test "rejects delegation when recursion is not granted" do
    scope =
      start_scope(
        root: [allow_delegation: false],
        profiles: %{"worker" => agent_spec("worker")}
      )

    context = %{runtime: scope.root_agent_ref}

    assert {:error, message} =
             Subagent.run(%{"profile" => "worker", "prompt" => "do work"}, context)

    assert message =~ "not permitted"
  end

  test "rejects unknown profiles by name" do
    scope = start_scope(root: [allow_delegation: true])
    context = %{runtime: scope.root_agent_ref}

    assert {:error, message} =
             Subagent.run(%{"profile" => "ghost", "prompt" => "do work"}, context)

    assert message =~ "unknown subagent profile"
  end

  test "bounds a requested timeout by the scope's run timeout" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        limits: Limits.new!(max_agents_per_fleet: 16, run_timeout: 50),
        profiles: %{"worker" => agent_spec("worker", mode: :block)}
      )

    args = %{"profile" => "worker", "prompt" => "wait", "timeout_ms" => 60_000}
    task = Task.async(fn -> Subagent.run(args, %{runtime: scope.root_agent_ref}) end)

    assert {:error, "subagent timed out"} = Task.await(task, 5_000)
  end

  test "rejects a missing runtime reference" do
    assert {:error, message} =
             Subagent.run(%{"profile" => "worker", "prompt" => "go"}, %{})

    assert message =~ "no runtime reference"
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

    agent_ref = scope.root_agent_ref

    assert {:error, message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "go"},
               %{runtime: agent_ref}
             )

    assert message =~ "subagent failed"
  end
end
