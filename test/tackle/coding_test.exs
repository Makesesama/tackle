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

    assert spec.root_spec.config.system_prompt =~ "<name>explorer</name>"
    assert explorer.config.system_prompt =~ "Do not edit"
    refute explorer.config.system_prompt =~ "- edit:"
    refute explorer.config.system_prompt =~ "- elixir_eval:"
    refute explorer.config.system_prompt =~ "## Delegation"
    assert spec.root_spec.config.system_prompt =~ "- subagent:"
    assert {:error, {:unknown_profile, "other"}} = ScopeSpec.resolve_profile(spec, "other")
  end

  test "loads project Markdown profiles with trusted tools and advertised descriptions", %{
    opts: opts,
    cwd: cwd
  } do
    path = Path.join([cwd, ".tackle", "agents", "reviewer.md"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    ---
    name: reviewer
    description: Review <changes> & report defects
    tools: read
    model: test/child
    thinking: high
    timeoutMs: 1000
    maxIterations: 7
    advertise: true
    ---

    Review the requested work. Do not modify files.
    """)

    assert {:ok, spec} = Coding.scope_spec(opts)
    assert {:ok, reviewer} = ScopeSpec.resolve_profile(spec, "reviewer")
    assert reviewer.config.tools == [Read]
    assert reviewer.config.model_ref == "test/child"
    assert reviewer.model_source == :configured
    assert reviewer.timeout == 1_000
    assert reviewer.config.max_iterations == 7
    assert reviewer.config.system_prompt =~ "Review the requested work"
    assert reviewer.config.system_prompt =~ "Project guidance: preserve tests."
    assert spec.root_spec.config.system_prompt =~ "<name>reviewer</name>"

    assert spec.root_spec.config.system_prompt =~
             "<description>Review &lt;changes&gt; &amp; report defects</description>"
  end

  test "project profiles override user profiles and omitted models inherit the parent", %{
    opts: opts,
    cwd: cwd
  } do
    home = opts[:env]["TACKLE_HOME"]
    write_agent(Path.join([home, "agents", "shared.md"]), "shared", "User profile", "User prompt")

    write_agent(
      Path.join([cwd, ".tackle", "agents", "shared.md"]),
      "shared",
      "Project profile",
      "Project prompt"
    )

    assert {:ok, spec} = Coding.scope_spec(opts)
    shared = spec.profiles["shared"]
    assert shared.model_source == :parent
    assert shared.config.system_prompt =~ "Project prompt"
    refute shared.config.system_prompt =~ "User prompt"
    assert spec.root_spec.config.system_prompt =~ "Project profile"
    refute spec.root_spec.config.system_prompt =~ "User profile"
  end

  test "invalid profile files and unavailable tools fail startup", %{opts: opts, cwd: cwd} do
    path = Path.join([cwd, ".tackle", "agents", "bad.md"])
    write_agent(path, "bad", "Bad profile", "Prompt", "tools: invented\n")

    assert {:error, {:invalid_agent_profile, ^path, {:unknown_tool_names, ["invented"]}}} =
             Coding.scope_spec(opts)

    File.write!(path, "---\nname: bad\ndescription: Bad\nunknown: value\n---\nPrompt\n")

    assert {:error, {:invalid_agent_definitions, [%{path: ^path, message: message}]}} =
             Coding.scope_spec(opts)

    assert message =~ "unknown frontmatter fields"
  end

  test "project profiles can explicitly allow bounded nested delegation", %{opts: opts, cwd: cwd} do
    path = Path.join([cwd, ".tackle", "agents", "lead.md"])

    write_agent(
      path,
      "lead",
      "Delegating lead",
      "Delegate only when needed.",
      "tools: read\nallowDelegation: true\n"
    )

    assert {:ok, spec} = Coding.scope_spec(opts)
    lead = spec.profiles["lead"]
    assert lead.allow_delegation
    assert lead.config.tools == [Read, Subagent]
    assert spec.limits.max_spawn_depth == 2
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

  defp write_agent(path, name, description, prompt, extra \\ "") do
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    ---
    name: #{name}
    description: #{description}
    #{extra}---

    #{prompt}
    """)
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
