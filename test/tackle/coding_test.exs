defmodule Tackle.CodingTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime, only: [tmp_home: 0, eventually: 1]

  alias Tackle.Coding
  alias Tackle.Runtime
  alias Tackle.Runtime.{Handle, Outcome, ScopeSpec}
  alias Tackle.Tools.{Bash, Read, Subagent}

  setup do
    home = tmp_home()
    cwd = Path.join(home, "project")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "AGENTS.md"), "Project guidance: preserve tests.")
    File.write!(Path.join(home, "APPEND_SYSTEM.md"), "Global guidance: cite sources.")

    opts = [
      available_adapters: [Tackle.Test.Adapter],
      cwd: cwd,
      env: %{"TACKLE_HOME" => home},
      overrides: [model: "test/echo", llm_opts: [test_pid: self()], retry: false]
    ]

    %{opts: opts, cwd: cwd}
  end

  test "composes a default explorer without changing generic defaults", %{opts: opts, cwd: cwd} do
    assert {:ok, spec} = Coding.scope_spec(opts)
    assert spec.root_spec.allow_delegation
    assert Subagent in spec.root_spec.config.tools
    refute Subagent in Tackle.Tools.default()
    assert {:ok, explorer} = ScopeSpec.resolve_profile(spec, "explorer")
    assert explorer.config.tools == [Read, Bash]
    refute explorer.allow_delegation
    assert explorer.model_source == :parent
    assert explorer.config.max_iterations == 20
    refute explorer.config.llm_stream
    assert explorer.config.model_ref == spec.root_spec.config.model_ref
    assert explorer.config.context.cwd == cwd
    assert explorer.timeout == 300_000
    assert spec.limits.max_agents_per_fleet == 3
    assert spec.limits.max_concurrent_turns == 3
    assert spec.limits.max_children_per_agent == 2
    assert spec.limits.max_spawn_depth == 1

    for config <- [spec.root_spec.config, explorer.config] do
      assert config.system_prompt =~ "Project guidance: preserve tests."
      assert config.system_prompt =~ "Global guidance: cite sources."
    end

    assert spec.root_spec.config.system_prompt =~ "profile \"explorer\""
    assert explorer.config.system_prompt =~ "Do not edit"
    refute explorer.config.system_prompt =~ "- edit:"
    refute explorer.config.system_prompt =~ "- elixir_eval:"
    refute explorer.config.system_prompt =~ "## Delegation"
    assert {:error, {:unknown_profile, "other"}} = ScopeSpec.resolve_profile(spec, "other")
  end

  test "preserves explicit prompts and narrower tools/iteration limits", %{opts: opts} do
    opts = update_overrides(opts, tools: [Read], max_iterations: 3, system_prompt: "Custom base")
    assert {:ok, spec} = Coding.scope_spec(opts)
    assert spec.root_spec.config.tools == [Read, Subagent]
    assert spec.profiles["explorer"].config.tools == [Read]
    assert spec.profiles["explorer"].config.max_iterations == 3
    assert spec.profiles["explorer"].config.system_prompt =~ "Custom base"
  end

  test "configuration failures are explicit", %{opts: opts} do
    assert {:error, _reason} = Coding.scope_spec(update_overrides(opts, model: "unknown/nope"))

    assert {:error, _reason} =
             Coding.scope_spec(Keyword.put(opts, :cwd, "/nonexistent-tackle-cwd"))
  end

  test "explorer gets a fresh conversation and is cleaned up after its answer", %{opts: opts} do
    scope = start_coding_scope(opts)
    assert {:ok, %{session_id: session_id}} = Tackle.subscribe(scope.root_agent_ref)
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "private parent context")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
    assert_receive {:adapter_called, _pid, "echo", _opts}

    assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, "explorer", "inspect files")
    assert %Outcome{status: :ok, agent_state: child} = Runtime.await(run, 5_000)
    assert Tackle.Lib.last_answer(child) == "answer"
    assert child.context.runtime.allow_delegation == false
    assert Enum.any?(child.messages, &(&1.content == "inspect files"))
    refute Enum.any?(child.messages, &(&1.content == "private parent context"))
    assert :ok = eventually(fn -> Runtime.session_pid(run.agent_ref) == {:error, :not_found} end)
  end

  test "explorer failures and timeouts reach the calling tool", %{opts: opts} do
    scope = start_coding_scope(update_overrides(opts, llm_opts: [mode: :error]))
    {:ok, snapshot} = Tackle.snapshot(scope.root_agent_ref)
    context = %{runtime: Handle.from_context(snapshot.agent_state.context)}

    assert {:error, message} =
             Subagent.run(%{"profile" => "explorer", "prompt" => "inspect"}, context)

    assert message =~ "subagent failed"

    scope = start_coding_scope(update_overrides(opts, llm_opts: [mode: :block]))
    {:ok, snapshot} = Tackle.snapshot(scope.root_agent_ref)
    context = snapshot.agent_state.context

    assert {:error, "subagent timed out"} =
             Subagent.run(
               %{"profile" => "explorer", "prompt" => "inspect", "timeout_ms" => 30},
               context
             )
  end

  test "limits reject excess children and children cannot delegate", %{opts: opts} do
    scope = start_coding_scope(update_overrides(opts, llm_opts: [mode: :block]))
    assert {:ok, first} = Runtime.request_agent(scope.root_agent_ref, "explorer", "first")
    assert {:ok, second} = Runtime.request_agent(scope.root_agent_ref, "explorer", "second")

    assert {:error, {:rejected, :max_children_per_agent}} =
             Runtime.request_agent(scope.root_agent_ref, "explorer", "third")

    assert {:error, {:rejected, :delegation_not_allowed}} =
             Runtime.request_agent(first.agent_ref, "explorer", "nested")

    assert :ok = Tackle.stop_scope(scope.scope_ref)
    assert Runtime.session_pid(first.agent_ref) == {:error, :not_found}
    assert Runtime.session_pid(second.agent_ref) == {:error, :not_found}
  end

  test "cancelling a parent turn cleans up its explorer", %{opts: opts} do
    call = %{
      "id" => "explore-1",
      "name" => "subagent",
      "arguments" => %{"profile" => "explorer", "prompt" => "inspect"}
    }

    opts =
      update_overrides(opts,
        llm_opts: [test_pid: self(), mode: :tool_then_answer, tool_call: call]
      )

    {:ok, spec} = Coding.scope_spec(opts)
    explorer = spec.profiles["explorer"]

    explorer = %{
      explorer
      | config: %{explorer.config | llm_opts: [test_pid: self(), mode: :block]}
    }

    {:ok, scope} = Tackle.start_scope(%{spec | profiles: %{"explorer" => explorer}})
    on_exit(fn -> Tackle.Test.Runtime.stop_scope(scope.scope_ref) end)

    {:ok, %{session_id: session_id}} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "delegate")
    assert_receive {:adapter_called, _root_task, "echo", _opts}, 5_000
    assert_receive {:adapter_called, child_task, "echo", _opts}, 5_000
    monitor = Process.monitor(child_task)
    assert :ok = Tackle.cancel(scope.root_agent_ref)
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:cancelled, _state}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^child_task, _reason}, 5_000

    assert :ok =
             eventually(fn ->
               {:ok, snapshot} = Runtime.scope_snapshot(scope.scope_ref)
               snapshot.agent_count == 1
             end)
  end

  test "resumed explorer follows the recorded root selection, not startup defaults", %{opts: opts} do
    home = tmp_home()
    session = Tackle.Session.Spec.new!(storage: [home: home])
    {:ok, spec} = Coding.scope_spec(opts, session)
    {:ok, scope} = Tackle.start_scope(spec)
    on_exit(fn -> Tackle.Test.Runtime.stop_scope(scope.scope_ref) end)
    {:ok, %{session_id: session_id}} = Tackle.subscribe(scope.root_agent_ref)

    {:ok, _snapshot} =
      Tackle.reconfigure(scope.root_agent_ref, model: "test/child", thinking: "high")

    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "record selection")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
    assert :ok = Tackle.stop_scope(scope.scope_ref)

    session = Tackle.Session.Spec.new!(session_id: session_id, storage: [home: home])
    {:ok, spec} = Coding.scope_spec(opts, session)
    assert spec.profiles["explorer"].config.model_ref == "test/echo"
    {:ok, resumed} = Tackle.start_scope(spec)
    on_exit(fn -> Tackle.Test.Runtime.stop_scope(resumed.scope_ref) end)
    {:ok, run} = Runtime.request_agent(resumed.root_agent_ref, "explorer", "inspect")
    assert %Outcome{status: :ok, agent_state: child} = Runtime.await(run, 5_000)
    assert child.llm.ref == "test/child"
    assert Tackle.Thinking.from_llm_opts(child.llm_opts) == "high"
    refute Enum.any?(child.messages, &(&1.content == "record selection"))
  end

  defp update_overrides(opts, overrides) do
    Keyword.update!(opts, :overrides, &Keyword.merge(&1, overrides))
  end

  defp start_coding_scope(opts) do
    {:ok, spec} = Coding.scope_spec(opts)
    {:ok, scope} = Tackle.start_scope(spec)
    on_exit(fn -> Tackle.Test.Runtime.stop_scope(scope.scope_ref) end)
    scope
  end
end
