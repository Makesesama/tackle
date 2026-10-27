defmodule Tackle.ConfigTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Retry
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Plugins.Catalog

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "test"

    @impl true
    def models, do: ["small", "family/nested"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  defmodule Tool do
    use Tackle.Lib.Tool

    tool_name("test_tool")
    description("A test tool.")

    input do
      field(:value, :string, required: true)
    end

    def run(%{"value" => value}, _context), do: {:ok, %{value: value}}
  end

  defmodule DuplicateTool do
    use Tackle.Lib.Tool

    tool_name("test_tool")
    description("A duplicate test tool.")

    input do
      field(:value, :string, required: true)
    end

    def run(%{"value" => value}, _context), do: {:ok, %{value: value}}
  end

  defmodule LoadSkillImpostor do
    use Tackle.Lib.Tool

    tool_name("load_skill")
    description("A different tool with the load_skill name.")

    input do
      field(:name, :string, required: true)
    end

    def run(%{"name" => name}, _context), do: {:ok, name}
  end

  defmodule IncompleteTool do
    def name, do: "incomplete"
  end

  defmodule BadSchemaTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "bad_schema"

    @impl true
    def description, do: "A tool with an invalid schema."

    @impl true
    def parameters_schema, do: [value: [type: :nonsense]]

    @impl true
    def execute(_input, _context), do: {:ok, nil}
  end

  defmodule CatalogHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def after_turn(_state, _context), do: :ok
  end

  defmodule EarlierHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def before_prompt(_state, _context), do: :ok
  end

  describe "load/1 with built-in skills" do
    setup do
      home = Path.join(System.tmp_dir!(), "tackle-skills-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(home) end)

      opts = [
        available_adapters: [Adapter],
        env: %{"TACKLE_HOME" => home},
        overrides: [model: "test/small", tools: [Tool]]
      ]

      %{opts: opts}
    end

    test "offers an available built-in skill and grants load_skill", %{opts: opts} do
      skill = builtin_skill!("guide", requires_tools: ["test_tool"])

      assert {:ok, config} = Config.load(Keyword.put(opts, :builtin_skills, [skill]))

      assert config.tools == [Tool, Tackle.Tools.LoadSkill]
      assert config.context.skills == [skill]
      assert config.system_prompt =~ "<name>guide</name>"
      assert config.system_prompt =~ "- load_skill:"
    end

    test "withholds a built-in skill whose required tools are missing", %{opts: opts} do
      skill = builtin_skill!("guide", requires_tools: ["run_workflow"])

      assert {:ok, config} = Config.load(Keyword.put(opts, :builtin_skills, [skill]))

      assert config.tools == [Tool]
      refute Map.has_key?(config.context, :skills)
      refute config.system_prompt =~ "<available_skills>"
    end

    test "does not grant load_skill for a built-in skill that disables model invocation", %{
      opts: opts
    } do
      markdown = "---\nname: manual\ndescription: d\ndisable-model-invocation: true\n---\nSteps."
      {:ok, skill} = Tackle.Skills.builtin(markdown)

      assert {:ok, config} = Config.load(Keyword.put(opts, :builtin_skills, [skill]))
      refute Tackle.Tools.LoadSkill in config.tools
      refute Map.has_key?(config.context, :skills)
    end

    test "a file skill replaces the built-in skill of the same name", %{opts: opts} do
      cwd = Path.join(System.tmp_dir!(), "tackle-skill-cwd-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(cwd) end)
      File.mkdir_p!(Path.join(cwd, ".git"))
      skill_dir = Path.join([cwd, ".agents", "skills", "guide"])
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        "---\nname: guide\ndescription: Mine.\n---\nMine."
      )

      opts =
        opts |> Keyword.put(:cwd, cwd) |> Keyword.put(:builtin_skills, [builtin_skill!("guide")])

      assert {:ok, config} = Config.load(opts)
      assert Tackle.Tools.LoadSkill in config.tools
      assert [%{source: :file, dir: ^skill_dir}] = config.context.skills
      assert config.system_prompt =~ "<directory>#{skill_dir}</directory>"
    end

    test "reports a different tool already named load_skill", %{opts: opts} do
      opts =
        opts
        |> Keyword.put(:overrides, model: "test/small", tools: [Tool, LoadSkillImpostor])
        |> Keyword.put(:builtin_skills, [builtin_skill!("guide")])

      assert {:error, {:tool_name_conflict, "load_skill"}} = Config.load(opts)
    end

    test "rejects invalid and duplicate built-in skills", %{opts: opts} do
      skill = builtin_skill!("guide")

      assert {:error, {:invalid_option, :builtin_skills, [:nope]}} =
               Config.load(Keyword.put(opts, :builtin_skills, [:nope]))

      hand_built = %{skill | content: nil}

      assert {:error, {:invalid_option, :builtin_skills, [^hand_built]}} =
               Config.load(Keyword.put(opts, :builtin_skills, [hand_built]))

      assert {:error, {:duplicate_builtin_skills, ["guide"]}} =
               Config.load(Keyword.put(opts, :builtin_skills, [skill, skill]))
    end
  end

  test "loads adapters and ordered hooks from a trusted catalog without granting its tools" do
    assert {:ok, catalog} =
             Catalog.new(
               adapters: [%{module: Adapter, source: :host}],
               tools: [%{module: Tool, source: :host}],
               hooks: [
                 %{module: EarlierHook, source: :host},
                 %{module: CatalogHook, source: :host}
               ]
             )

    home = Path.join(System.tmp_dir!(), "tackle-catalog-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)

    assert {:ok, config} =
             Config.load(
               catalog: catalog,
               env: %{"TACKLE_HOME" => home},
               overrides: [model: "test/small"]
             )

    assert [%Provider{id: "test", adapter: Adapter, settings: %{}}] = config.providers
    assert config.hooks == [EarlierHook, CatalogHook]
    refute Tool in config.tools

    assert {:error, :conflicting_adapter_sources} =
             Config.load(catalog: catalog, available_adapters: [Adapter])

    assert {:error, :conflicting_hook_sources} =
             Config.load(catalog: catalog, overrides: [hooks: [CatalogHook]])
  end

  describe "load/1 options" do
    setup do
      home = Path.join(System.tmp_dir!(), "tackle-loader-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(home) end)
      opts = [available_adapters: [Adapter], env: %{"TACKLE_HOME" => home}]
      %{opts: opts, home: home}
    end

    test "a malformed option list is a loader error", %{opts: opts} do
      assert {:error, {:invalid_loader_options, :none}} = Config.load(:none)
      assert {:error, {:invalid_loader_options, [1]}} = Config.load([1])

      assert {:error, {:duplicate_loader_option, :env}} =
               Config.load([{:env, %{}} | opts])

      assert {:error, {:unknown_loader_options, [:surprise, :root_tools]}} =
               Config.load([surprise: true, root_tools: []] ++ opts)
    end

    test "invalid option values are three-tuples naming the option", %{opts: opts, home: home} do
      load = &Config.load(Keyword.merge(opts, &1))
      missing = Path.join(home, "missing")

      assert {:error, {:invalid_option, :cwd, ^missing}} = load.(cwd: missing)
      assert {:error, {:invalid_option, :cwd, 42}} = load.(cwd: 42)
      assert {:error, {:invalid_option, :env, [{"HOME", "/"}]}} = load.(env: [{"HOME", "/"}])
      assert {:error, {:invalid_option, :overrides, :none}} = load.(overrides: :none)
      assert {:error, {:invalid_option, :overrides, [1]}} = load.(overrides: [1])
      assert {:error, {:invalid_option, :catalog, :none}} = load.(catalog: :none)
      assert {:error, {:invalid_option, :accounts, []}} = load.(accounts: [])

      assert {:error, {:reserved_override, :providers}} =
               load.(overrides: [providers: [Adapter]])
    end
  end

  test "resolves an explicit adapter and canonical model reference" do
    assert {:ok, config} =
             Config.new(
               providers: [Adapter],
               model: "test/family/nested",
               tools: [Tool],
               context: %{workspace: "/tmp/project"},
               llm_stream: true
             )

    assert %Selection{
             adapter: Adapter,
             provider_id: "test",
             model: "family/nested",
             ref: "test/family/nested"
           } = config.llm

    assert config.model_ref == "test/family/nested"
    assert config.tools == [Tool]
    assert config.context == %{workspace: "/tmp/project"}
    assert config.system_prompt =~ "You are an expert coding assistant operating inside Tackle"
    assert config.system_prompt =~ "- test_tool: A test tool."
    assert config.llm_stream

    state = Config.to_agent_state(config)
    assert state.llm == config.llm
    assert State.model(state) == "family/nested"

    assert Config.to_agent_state(config, session_id: "session").session_id == "session"

    # A stale option is an error, not silently dropped.
    assert_raise ArgumentError, ~r/accepts only :session_id/, fn ->
      Config.to_agent_state(config, credential_store: :store)
    end

    assert_raise ArgumentError, fn -> Config.to_agent_state(config, [:session_id]) end
  end

  test "session titles are opt-in through new and resolve a dedicated model" do
    assert {:ok, config} = Config.new(providers: [Adapter], model: "test/small")
    assert config.session_titles == nil

    assert {:ok, config} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               session_titles: [model: "test/family/nested"]
             )

    assert %Tackle.Config.SessionTitles{model_ref: "test/family/nested"} =
             config.session_titles

    assert config.session_titles.selection.model == "family/nested"

    assert {:ok, config} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               session_titles: [enabled: false, model: "test/small"]
             )

    assert config.session_titles == nil
  end

  test "session titles reject unknown options and unknown models" do
    assert {:error, {:invalid_option, :session_titles, [:unknown]}} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               session_titles: [unknown: true]
             )

    assert {:error, {:unknown_model, "test/missing"}} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               session_titles: [model: "test/missing"]
             )

    assert {:error, {:invalid_option, :session_titles, "yes"}} =
             Config.new(providers: [Adapter], model: "test/small", session_titles: "yes")

    assert {:error, {:invalid_option, :session_titles, ["test/small"]}} =
             Config.new(providers: [Adapter], model: "test/small", session_titles: ["test/small"])
  end

  test "updates model and thinking without changing other session options" do
    assert {:ok, config} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               tools: [Tool],
               llm_opts: [request_tag: "keep"]
             )

    assert {:ok, updated} =
             Config.update(config, model: "test/family/nested", thinking: "high")

    assert updated.model_ref == "test/family/nested"
    assert updated.llm.model == "family/nested"
    assert updated.tools == [Tool]

    assert updated.llm_opts == [request_tag: "keep", reasoning_effort: "high"]

    assert {:ok, disabled} = Config.update(updated, thinking: "off")
    assert disabled.llm_opts == [request_tag: "keep"]

    assert {:error, {:invalid_thinking_level, "extreme"}} =
             Config.update(config, thinking: "extreme")
  end

  test "updates the step limit, context, and adapter options with new/1's checks" do
    assert {:ok, config} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               context: %{own: true},
               llm_opts: [request_tag: "keep"]
             )

    assert {:ok, updated} =
             Config.update(config,
               max_iterations: 3,
               context: %{stage: :detector},
               llm_opts: [prompt_cache_key: "key", reasoning_effort: "low"],
               thinking: "high"
             )

    assert updated.max_iterations == 3
    assert updated.context == %{own: true, stage: :detector}
    # A thinking level wins over a reasoning effort in the adapter options.
    assert updated.llm_opts == [
             request_tag: "keep",
             prompt_cache_key: "key",
             reasoning_effort: "high"
           ]

    assert {:error, {:invalid_option, :max_iterations, 0}} =
             Config.update(config, max_iterations: 0)

    assert {:error, {:invalid_option, :context, nil}} = Config.update(config, context: nil)

    assert {:error, {:invalid_option, :executor, {NotAModule, nil}}} =
             Config.update(config, context: %{executor: {NotAModule, nil}})

    assert {:error, {:invalid_option, :llm_opts, [1]}} = Config.update(config, llm_opts: [1])

    assert {:error, {:reserved_llm_option, :api_key}} =
             Config.update(config, llm_opts: [api_key: "must-not-enter-config"])

    assert {:error, {:unknown_update_options, [:tools]}} = Config.update(config, tools: [])
    assert {:error, {:invalid_update_options, :none}} = Config.update(config, :none)

    assert {:error, {:duplicate_update_option, :model}} =
             Config.update(config, model: "test/small", model: "test/small")

    # Credentials a session put into its own options do not block updates.
    session_config = %{config | llm_opts: [credential_store: :store]}

    assert {:ok, %{llm_opts: [credential_store: :store, reasoning_effort: "low"]}} =
             Config.update(session_config, thinking: "low")
  end

  test "uses the built-in developer tools by default and permits an explicit empty set" do
    assert {:ok, config} = Config.new(providers: [Adapter], model: "test/small")
    assert config.tools == Tackle.Tools.default()

    assert {:ok, config} = Config.new(providers: [Adapter], model: "test/small", tools: [])
    assert config.tools == []
  end

  test "configures provider retry policy and passes it to agent state" do
    assert {:ok, default} = Config.new(providers: [Adapter], model: "test/small")
    assert default.retry == Retry.new!()
    assert Config.to_agent_state(default).retry == default.retry

    assert {:ok, configured} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               retry: [max_retries: 1, base_delay_ms: 10, max_delay_ms: 20]
             )

    assert configured.retry == Retry.new!(max_retries: 1, base_delay_ms: 10, max_delay_ms: 20)

    assert {:ok, disabled} =
             Config.new(providers: [Adapter], model: "test/small", retry: false)

    refute Config.to_agent_state(disabled).retry.enabled?

    assert {:error, {:invalid_retry_config, {:max_retries, -1}}} =
             Config.new(providers: [Adapter], model: "test/small", retry: [max_retries: -1])
  end

  test "uses unlimited iterations by default and accepts an explicit limit" do
    assert {:ok, unlimited} = Config.new(providers: [Adapter], model: "test/small")
    assert unlimited.max_iterations == :infinity
    assert Config.to_agent_state(unlimited).max_iterations == :infinity

    assert {:ok, bounded} =
             Config.new(providers: [Adapter], model: "test/small", max_iterations: 25)

    assert bounded.max_iterations == 25

    assert {:error, {:invalid_option, :max_iterations, 0}} =
             Config.new(providers: [Adapter], model: "test/small", max_iterations: 0)
  end

  test "pins tool execution to concurrent and rejects a tool policy option" do
    assert {:ok, config} = Config.new(providers: [Adapter], model: "test/small")
    state = Config.to_agent_state(config)
    assert %Policy{execution_mode: :concurrent} = state.tool_policy

    assert {:error, {:unknown_options, [:tool_policy]}} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               tool_policy: Policy.default()
             )
  end

  test "returns explicit validation errors" do
    assert {:error, {:missing_option, :providers}} = Config.new(model: "test/small")
    assert {:error, {:invalid_options, :none}} = Config.new(:none)
    assert {:error, {:invalid_options, [1]}} = Config.new([1])

    assert {:error, {:unknown_model, "test/missing"}} =
             Config.new(providers: [Adapter], model: "test/missing")

    assert {:error, {:unknown_options, [:surprise]}} =
             Config.new(providers: [Adapter], model: "test/small", surprise: true)

    assert {:error, {:duplicate_option, :model}} =
             Config.new(providers: [Adapter], model: "test/small", model: "test/small")

    assert {:error, {:duplicate_tool_name, "test_tool"}} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               tools: [Tool, DuplicateTool]
             )

    assert {:error, {:reserved_llm_option, :credential_store}} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               llm_opts: [credential_store: {:not, :allowed}]
             )

    assert {:error, {:reserved_llm_option, :access_token}} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               llm_opts: [access_token: "must-not-enter-config"]
             )

    assert {:error, {:reserved_llm_option, "api_key"}} =
             Config.new(
               providers: [Adapter],
               model: "test/small",
               llm_opts: [provider: %{"api_key" => "must-not-enter-config"}]
             )
  end

  test "rejects tools Tackle.Lib.Tool.Registry would refuse, with result tuples" do
    new = &Config.new(providers: [Adapter], model: "test/small", tools: &1)

    assert {:error,
            {:invalid_tool, IncompleteTool,
             {:missing_callbacks, [description: 0, parameters_schema: 0, execute: 2]}}} =
             new.([IncompleteTool])

    assert {:error, {:invalid_tool, "not a module", :not_a_module}} = new.(["not a module"])

    assert {:error, {:invalid_tool, BadSchemaTool, {:invalid_schema, :parameters, message}}} =
             new.([BadSchemaTool])

    assert message =~ "unknown type :nonsense"
    assert {:error, {:invalid_option, :tools, :none}} = new.(:none)
  end

  test "accepts only hook modules as hooks" do
    new = &Config.new(providers: [Adapter], model: "test/small", hooks: &1)

    assert {:ok, %{hooks: [CatalogHook]}} = new.([CatalogHook])
    assert {:error, {:invalid_hook, Tool, :no_hook_callbacks}} = new.([CatalogHook, Tool])
    assert {:error, {:invalid_hook, NotLoaded, :no_hook_callbacks}} = new.([NotLoaded])
    assert {:error, {:invalid_hook, nil, :no_hook_callbacks}} = new.([nil])
    assert {:error, {:invalid_option, :hooks, :none}} = new.(:none)
  end

  defp builtin_skill!(name, opts \\ []) do
    markdown = "---\nname: #{name}\ndescription: A guide.\n---\nSteps."
    {:ok, skill} = Tackle.Skills.builtin(markdown, opts)
    skill
  end
end
