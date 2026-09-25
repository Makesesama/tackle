defmodule Tackle.CodingTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime, only: [tmp_home: 0, eventually: 1]

  alias Tackle.Coding
  alias Tackle.Plugins.Catalog
  alias Tackle.Runtime
  alias Tackle.Runtime.{Handle, Outcome, ScopeSpec}
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Tools.{Bash, Read, Subagent, SubagentStatus, SubagentWait}

  defmodule CatalogTool do
    use Tackle.Lib.Tool

    tool_name("catalog_test_tool")
    description("A tool from a host catalog.")

    input do
      field(:value, :string, required: true)
    end

    def run(%{"value" => value}, _context), do: {:ok, value}
  end

  defmodule ConflictingTool do
    use Tackle.Lib.Tool

    tool_name("read")
    description("Conflicts with built-in read.")

    input do
      field(:value, :string, required: true)
    end

    def run(%{"value" => value}, _context), do: {:ok, value}
  end

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

  test "root-only tools do not automatically reach subagents", %{opts: opts} do
    opts = Keyword.put(opts, :root_tools, [Tackle.Tools.Write])
    assert {:ok, spec} = Coding.scope_spec(opts)
    assert Tackle.Tools.Write in spec.root_spec.config.tools
    refute Tackle.Tools.Write in spec.profiles["scout"].config.tools
    refute Tackle.Tools.Write in spec.profiles["reviewer"].config.tools

    assert {:error, :invalid_root_tools} =
             Coding.scope_spec(Keyword.put(opts, :root_tools, ["Module.Name"]))
  end

  test "catalog grants only selected root tools and profile names resolve from trusted tools", %{
    opts: opts,
    cwd: cwd
  } do
    profile = Path.join([cwd, ".tackle", "agents", "custom.md"])

    write_agent(
      profile,
      "custom",
      "Custom",
      "Use the approved tools.",
      "tools: catalog_test_tool\n"
    )

    assert {:ok, catalog} =
             Catalog.new(
               adapters: [%{module: Tackle.Test.Adapter, source: :host}],
               tools: [%{module: CatalogTool, source: {:project, "example"}}],
               hooks: []
             )

    catalog_opts = opts |> Keyword.delete(:available_adapters) |> Keyword.put(:catalog, catalog)

    assert {:ok, spec} =
             Coding.scope_spec(
               Keyword.put(catalog_opts, :catalog_root_tools, ["catalog_test_tool"])
             )

    assert CatalogTool in spec.root_spec.config.tools
    assert spec.profiles["custom"].config.tools == [CatalogTool]
    refute CatalogTool in spec.profiles["scout"].config.tools

    assert {:error, {:unknown_tool, "absent"}} =
             Coding.scope_spec(Keyword.put(catalog_opts, :catalog_root_tools, ["absent"]))

    assert {:error, {:catalog_required_for_root_tools, ["catalog_test_tool"]}} =
             Coding.scope_spec(Keyword.put(opts, :catalog_root_tools, ["catalog_test_tool"]))
  end

  test "catalog tools do not become root grants simply by being available", %{opts: opts} do
    {:ok, catalog} =
      Catalog.new(
        adapters: [%{module: Tackle.Test.Adapter, source: :host}],
        tools: [%{module: CatalogTool, source: :host}],
        hooks: []
      )

    assert {:ok, spec} =
             Coding.scope_spec(
               opts
               |> Keyword.delete(:available_adapters)
               |> Keyword.put(:catalog, catalog)
             )

    # Catalog availability is distinct from the root's selected tools.
    refute CatalogTool in spec.root_spec.config.tools
    refute CatalogTool in spec.profiles["scout"].config.tools
  end

  test "catalog tool names cannot silently replace built-in tools", %{opts: opts} do
    {:ok, catalog} =
      Catalog.new(
        adapters: [%{module: Tackle.Test.Adapter, source: :host}],
        tools: [%{module: ConflictingTool, source: :project}],
        hooks: []
      )

    assert {:error, {:catalog_tool_conflict, :project, "read"}} =
             Coding.scope_spec(
               opts
               |> Keyword.delete(:available_adapters)
               |> Keyword.put(:catalog, catalog)
             )
  end

  test "composes a default scout without changing generic defaults", %{opts: opts, cwd: cwd} do
    assert {:ok, spec} = Coding.scope_spec(opts)
    assert spec.root_spec.allow_delegation
    assert Subagent in spec.root_spec.config.tools
    assert SubagentStatus in spec.root_spec.config.tools
    assert SubagentWait in spec.root_spec.config.tools
    refute Subagent in Tackle.Tools.default()
    refute SubagentWait in Tackle.Tools.default()
    assert Map.keys(spec.profiles) |> Enum.sort() == ["reviewer", "scout", "worker"]
    assert {:ok, scout} = ScopeSpec.resolve_profile(spec, "scout")
    assert scout.config.tools == [Read, Bash]
    refute scout.allow_delegation
    assert scout.model_source == :parent
    assert scout.config.max_iterations == :infinity
    refute scout.config.llm_stream
    assert scout.config.model_ref == spec.root_spec.config.model_ref
    assert scout.config.context.cwd == cwd
    assert scout.timeout == 300_000
    assert spec.limits.max_agents_per_fleet == 3
    assert spec.limits.max_concurrent_turns == 3
    assert spec.limits.max_children_per_agent == 2
    assert spec.limits.max_spawn_depth == 1

    for config <- [spec.root_spec.config, scout.config] do
      assert config.system_prompt =~ "Project guidance: preserve tests."
      assert config.system_prompt =~ "Global guidance: cite sources."
    end

    assert spec.root_spec.config.system_prompt =~ "<name>scout</name>"
    assert spec.root_spec.config.system_prompt =~ "<name>reviewer</name>"
    assert spec.root_spec.config.system_prompt =~ "<name>worker</name>"
    assert spec.root_spec.config.system_prompt =~ "Prefer foreground mode"
    assert spec.root_spec.config.system_prompt =~ "same assignment yourself"
    assert spec.root_spec.config.system_prompt =~ "call `subagent_wait`"
    assert spec.root_spec.config.system_prompt =~ "keep a single writer"
    assert spec.profiles["reviewer"].config.tools == [Read, Bash]
    assert spec.profiles["worker"].config.tools == Tackle.Tools.default()
    assert scout.config.system_prompt =~ "Do not edit"
    refute scout.config.system_prompt =~ "- edit:"
    refute scout.config.system_prompt =~ "- elixir_eval:"
    refute scout.config.system_prompt =~ "## Delegation"
    assert spec.root_spec.config.system_prompt =~ "- subagent:"
    assert spec.root_spec.config.system_prompt =~ "- subagent_wait:"
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
    refute SubagentWait in lead.config.tools
    assert spec.limits.max_spawn_depth == 2
  end

  test "preserves explicit prompts and narrower tools/iteration limits", %{opts: opts} do
    opts = update_overrides(opts, tools: [Read], max_iterations: 3, system_prompt: "Custom base")
    assert {:ok, spec} = Coding.scope_spec(opts)
    assert spec.root_spec.config.tools == [Read, Subagent, SubagentStatus, SubagentWait]
    assert spec.profiles["scout"].config.tools == [Read, Bash]
    assert spec.profiles["scout"].config.max_iterations == 3
    assert spec.profiles["scout"].config.system_prompt =~ "Scout assignment"
    assert spec.profiles["scout"].config.system_prompt =~ "Custom base"
  end

  test "configuration failures are explicit", %{opts: opts} do
    assert {:error, _reason} = Coding.scope_spec(update_overrides(opts, model: "unknown/nope"))

    assert {:error, _reason} =
             Coding.scope_spec(Keyword.put(opts, :cwd, "/nonexistent-tackle-cwd"))
  end

  test "scout gets a fresh conversation and is cleaned up after its answer", %{opts: opts} do
    scope = start_coding_scope(opts)
    assert {:ok, %{session_id: session_id}} = Tackle.subscribe(scope.root_agent_ref)
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "private parent context")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
    assert_receive {:adapter_called, _pid, "echo", _opts}

    assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, "scout", "inspect files")
    assert %Outcome{status: :ok, agent_state: child} = Runtime.await(run, 5_000)
    assert Tackle.Lib.last_answer(child) == "answer"
    assert child.context.runtime.allow_delegation == false
    assert Enum.any?(child.messages, &(&1.content == "inspect files"))
    refute Enum.any?(child.messages, &(&1.content == "private parent context"))
    assert :ok = eventually(fn -> Runtime.session_pid(run.agent_ref) == {:error, :not_found} end)
  end

  test "scout failures and timeouts reach the calling tool", %{opts: opts} do
    scope = start_coding_scope(update_overrides(opts, llm_opts: [mode: :error]))
    {:ok, snapshot} = Tackle.snapshot(scope.root_agent_ref)
    context = %{runtime: Handle.from_context(snapshot.agent_state.context)}

    assert {:error, message} =
             Subagent.run(%{"profile" => "scout", "prompt" => "inspect"}, context)

    assert message =~ "subagent failed"

    scope = start_coding_scope(update_overrides(opts, llm_opts: [mode: :block]))
    {:ok, snapshot} = Tackle.snapshot(scope.root_agent_ref)
    context = snapshot.agent_state.context

    assert {:error, "subagent timed out"} =
             Subagent.run(
               %{"profile" => "scout", "prompt" => "inspect", "timeout_ms" => 30},
               context
             )
  end

  test "limits reject excess children and children cannot delegate", %{opts: opts} do
    scope = start_coding_scope(update_overrides(opts, llm_opts: [mode: :block]))
    assert {:ok, first} = Runtime.request_agent(scope.root_agent_ref, "scout", "first")
    assert {:ok, second} = Runtime.request_agent(scope.root_agent_ref, "scout", "second")

    assert {:error, {:rejected, :max_children_per_agent}} =
             Runtime.request_agent(scope.root_agent_ref, "scout", "third")

    assert {:error, {:rejected, :delegation_not_allowed}} =
             Runtime.request_agent(first.agent_ref, "scout", "nested")

    assert :ok = Tackle.stop_scope(scope.scope_ref)
    assert Runtime.session_pid(first.agent_ref) == {:error, :not_found}
    assert Runtime.session_pid(second.agent_ref) == {:error, :not_found}
  end

  test "cancelling a parent turn cleans up its scout", %{opts: opts} do
    call = %{
      "id" => "explore-1",
      "name" => "subagent",
      "arguments" => %{"profile" => "scout", "prompt" => "inspect"}
    }

    opts =
      update_overrides(opts,
        llm_opts: [test_pid: self(), mode: :tool_then_answer, tool_call: call]
      )

    {:ok, spec} = Coding.scope_spec(opts)
    scout = spec.profiles["scout"]

    scout = %{
      scout
      | config: %{scout.config | llm_opts: [test_pid: self(), mode: :block]}
    }

    {:ok, scope} = Tackle.start_scope(%{spec | profiles: %{"scout" => scout}})
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

  test "resumed scout follows the recorded root selection, not startup defaults", %{opts: opts} do
    home = tmp_home()
    session = SessionSpec.new!(storage: [home: home])
    {:ok, spec} = Coding.scope_spec(opts, session)
    {:ok, scope} = Tackle.start_scope(spec)
    on_exit(fn -> Tackle.Test.Runtime.stop_scope(scope.scope_ref) end)
    {:ok, %{session_id: session_id}} = Tackle.subscribe(scope.root_agent_ref)

    {:ok, _snapshot} =
      Tackle.reconfigure(scope.root_agent_ref, model: "test/child", thinking: "high")

    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "record selection")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
    assert :ok = Tackle.stop_scope(scope.scope_ref)

    session = SessionSpec.new!(session_id: session_id, storage: [home: home])
    {:ok, spec} = Coding.scope_spec(opts, session)
    assert spec.profiles["scout"].config.model_ref == "test/echo"
    {:ok, resumed} = Tackle.start_scope(spec)
    on_exit(fn -> Tackle.Test.Runtime.stop_scope(resumed.scope_ref) end)
    {:ok, run} = Runtime.request_agent(resumed.root_agent_ref, "scout", "inspect")
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
