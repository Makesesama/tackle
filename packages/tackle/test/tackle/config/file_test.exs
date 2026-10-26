defmodule Tackle.Config.FileTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
  alias Tackle.Config.File, as: ConfigFile
  alias Tackle.Config.Narration
  alias Tackle.Elixir.CompileGate.Settings, as: CompileGateSettings
  alias Tackle.Lib.LLM.Provider

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "test"

    @impl true
    def models, do: ["default", "file", "environment", "override"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  defmodule JudgeAdapter do
    @behaviour Tackle.Lib.LLM
    @behaviour Tackle.Lib.Decision

    @impl Tackle.Lib.LLM
    def adapter_id, do: "judge"

    @impl Tackle.Lib.LLM
    def models, do: []

    @impl Tackle.Lib.LLM
    def generate(_schema, _opts), do: {:error, :not_used}

    @impl Tackle.Lib.Decision
    def decision_models, do: ["small"]

    @impl Tackle.Lib.Decision
    def decide(_request, _opts), do: {:error, :not_used}
  end

  # One adapter backing several providers, each with its own model list.
  defmodule InstanceAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "inst"

    @impl true
    def default_providers, do: [{"inst", %{"models" => ["base"], "region" => "eu"}}]

    @impl true
    def models(settings), do: Map.get(settings, "models", [])

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  setup do
    home = Path.join(System.tmp_dir!(), "tackle-config-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    %{home: home, env: %{"TACKLE_HOME" => home}}
  end

  test "missing config file uses validator defaults and explicit overrides", %{env: env} do
    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/default"]
             )

    assert config.model_ref == "test/default"
    assert config.max_iterations == :infinity
  end

  test "loads model and thinking from config.json", %{home: home, env: env} do
    write_config(home, ~s({"model":"test/file","thinking":"high"}))

    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert config.model_ref == "test/file"
    assert config.llm_opts == [reasoning_effort: "high"]
  end

  test "loads the effective system prompt for the configured cwd", %{home: home, env: env} do
    cwd = Path.join(home, "workspace/nested")
    File.mkdir_p!(cwd)
    File.write!(Path.join(home, "APPEND_SYSTEM.md"), "Global addition.")
    File.write!(Path.join(home, "AGENTS.md"), "Global instructions.")
    File.write!(Path.join(Path.dirname(cwd), "AGENTS.md"), "Workspace instructions.")

    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               cwd: cwd,
               env: env,
               overrides: [model: "test/default"]
             )

    assert config.context.cwd == cwd
    assert config.system_prompt =~ "You are an expert coding assistant operating inside Tackle"
    assert config.system_prompt =~ "Global addition."
    assert config.system_prompt =~ "Global instructions."
    assert config.system_prompt =~ "Workspace instructions."
    assert config.system_prompt =~ "Current working directory: #{cwd}"

    assert Config.to_agent_state(config).system_prompt == config.system_prompt
  end

  test "uses an explicit context cwd for prompt discovery and tool context", %{
    home: home,
    env: env
  } do
    cwd = Path.join(home, "context-workspace")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "AGENTS.md"), "Context workspace instructions.")

    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/default", context: %{"cwd" => cwd}]
             )

    assert config.context.cwd == cwd
    assert config.system_prompt =~ "Context workspace instructions."
    assert config.system_prompt =~ "Current working directory: #{cwd}"
  end

  test "an explicit system prompt replaces the built-in base but keeps global additions", %{
    home: home,
    env: env
  } do
    cwd = Path.join(home, "workspace")
    File.mkdir_p!(cwd)
    File.write!(Path.join(home, "APPEND_SYSTEM.md"), "Global addition.")

    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               cwd: cwd,
               env: env,
               overrides: [model: "test/default", system_prompt: "Explicit base."]
             )

    assert config.system_prompt =~ "Explicit base."
    assert config.system_prompt =~ "Global addition."
    refute config.system_prompt =~ "expert coding assistant"
  end

  test "includes project skills in the system prompt", %{home: home, env: env} do
    cwd = Path.join(home, "workspace")
    File.mkdir_p!(Path.join(cwd, ".git"))

    skill_dir = Path.join([cwd, ".agents", "skills", "demo"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: demo\ndescription: Demonstrates skills.\n---\nbody\n"
    )

    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               cwd: cwd,
               env: env,
               overrides: [model: "test/default"]
             )

    assert config.system_prompt =~ "<available_skills>"
    assert config.system_prompt =~ "<name>demo</name>"
    assert config.system_prompt =~ "<description>Demonstrates skills.</description>"
  end

  test "instructions: false leaves instruction files and skills out", %{home: home, env: env} do
    cwd = Path.join(home, "lean-workspace")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.write!(Path.join(home, "APPEND_SYSTEM.md"), "Global addition.")
    File.write!(Path.join(cwd, "AGENTS.md"), "Workspace instructions.")
    skill_dir = Path.join([cwd, ".agents", "skills", "demo"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: demo\ndescription: Demonstrates skills.\n---\nbody\n"
    )

    load = fn instructions ->
      Config.load(
        available_adapters: [Adapter],
        cwd: cwd,
        env: env,
        instructions: instructions,
        overrides: [model: "test/default", system_prompt: "Assignment."]
      )
    end

    assert {:ok, full} = load.(true)
    assert full.system_prompt =~ "Workspace instructions."
    assert Tackle.Tools.LoadSkill in full.tools

    assert {:ok, lean} = load.(false)
    assert lean.system_prompt == "Assignment.\n\nCurrent working directory: #{cwd}\n"
    refute Tackle.Tools.LoadSkill in lean.tools
    refute Map.has_key?(lean.context, :skills)

    assert {:error, {:invalid_option, :instructions, "no"}} = load.("no")
  end

  test "environment overrides the file", %{home: home, env: env} do
    write_config(home, ~s({"model":"test/file","thinking":"low"}))

    env =
      env
      |> Map.put("TACKLE_MODEL", "test/environment")
      |> Map.put("TACKLE_THINKING", "xhigh")

    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert config.model_ref == "test/environment"
    assert config.llm_opts == [reasoning_effort: "xhigh"]
  end

  test "explicit overrides win over environment variables", %{home: home, env: env} do
    write_config(home, ~s({"model":"test/file"}))
    env = Map.put(env, "TACKLE_MODEL", "test/environment")

    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/override", thinking: "medium"]
             )

    assert config.model_ref == "test/override"
    assert config.llm_opts == [reasoning_effort: "medium"]
  end

  test "invalid thinking configuration returns an explicit error", %{home: home, env: env} do
    path = write_config(home, ~s({"model":"test/file","thinking":"extreme"}))

    assert {:error, {:invalid_config_field, ^path, "thinking"}} =
             Config.load(available_adapters: [Adapter], env: env)

    write_config(home, ~s({"model":"test/file"}))

    assert {:error, {:invalid_environment, "TACKLE_THINKING"}} =
             Config.load(
               available_adapters: [Adapter],
               env: Map.put(env, "TACKLE_THINKING", "extreme")
             )
  end

  test "validates the CLI sidebar preference alongside harness fields", %{home: home, env: env} do
    path = write_config(home, ~s({"model":"test/file","show_subagent_sidebar":false}))
    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert config.model_ref == "test/file"

    File.write!(path, ~s({"model":"test/file","show_subagent_sidebar":"false"}))

    assert {:error, {:invalid_config_field, ^path, "show_subagent_sidebar"}} =
             Config.load(available_adapters: [Adapter], env: env)
  end

  test "validates the CLI jail environment alongside harness fields", %{home: home, env: env} do
    path = write_config(home, ~s({"model":"test/file","jail":{"env":["GH_TOKEN","_X1"]}}))
    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert config.model_ref == "test/file"
    assert ConfigFile.jail_env(path) == {:ok, ["GH_TOKEN", "_X1"]}

    for invalid <- [
          ~s({"jail":["GH_TOKEN"]}),
          ~s({"jail":{"env":"GH_TOKEN"}}),
          ~s({"jail":{"env":null}}),
          ~s({"jail":{"env":["GH-TOKEN"]}}),
          ~s({"jail":{"env":["1X"]}}),
          ~s({"jail":{"env":[""]}}),
          ~s({"jail":{"env":["A=B"]}}),
          ~s({"jail":{"env":[1]}}),
          ~s({"jail":{"env":[],"mounts":[]}})
        ] do
      File.write!(path, invalid)

      assert {:error, {:invalid_config_field, ^path, "jail"}} =
               Config.load(available_adapters: [Adapter], env: env)

      assert {:error, {:invalid_config_field, ^path, "jail"}} = ConfigFile.jail_env(path)
    end
  end

  test "jail_env is empty without the setting or the file", %{home: home} do
    path = Path.join(home, "config.json")
    assert ConfigFile.jail_env(path) == {:ok, []}
    File.mkdir_p!(home)

    for empty <- [~s({}), ~s({"jail":null}), ~s({"jail":{}}), ~s({"jail":{"env":[]}})] do
      File.write!(path, empty)
      assert ConfigFile.jail_env(path) == {:ok, []}
    end
  end

  test "config.json providers merge over adapter defaults and accounts", %{
    home: home,
    env: env
  } do
    write_config(
      home,
      JSON.encode!(%{
        "model" => "inst-gpu/big",
        "providers" => %{
          "inst" => %{"adapter" => "inst", "models" => ["base", "tuned"]},
          "inst-gpu" => %{"adapter" => "inst", "models" => ["big"], "base_url" => "http://gpu"}
        }
      })
    )

    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter, InstanceAdapter],
               accounts: %{
                 "inst-gpu" => %{"adapter" => "inst"},
                 "inst-work" => %{"adapter" => "inst", "base" => "inst"}
               },
               env: env
             )

    assert [
             %Provider{id: "test", adapter: Adapter},
             %Provider{id: "inst", adapter: InstanceAdapter} = inst,
             %Provider{id: "inst-gpu", adapter: InstanceAdapter} = gpu,
             %Provider{id: "inst-work", adapter: InstanceAdapter} = work
           ] = config.providers

    # Config settings merge over the default provider's settings.
    assert inst.settings == %{"models" => ["base", "tuned"], "region" => "eu"}
    assert gpu.settings == %{"models" => ["big"], "base_url" => "http://gpu"}
    # An account inherits its base provider's merged settings.
    assert work.settings == inst.settings

    # The selection carries its provider's settings to the adapter.
    assert config.llm.provider_id == "inst-gpu"
    assert config.llm.provider_settings == gpu.settings
    refute Keyword.has_key?(config.llm_opts, :provider_options)

    assert {:ok, switched} = Config.reconfigure(config, model: "inst/tuned")
    assert switched.llm.provider_settings == inst.settings
  end

  test "malformed providers in config.json return errors", %{home: home, env: env} do
    load = fn -> Config.load(available_adapters: [Adapter, InstanceAdapter], env: env) end

    for providers <- [[1], "inst", true] do
      path = write_config(home, JSON.encode!(%{"providers" => providers}))
      assert {:error, {:invalid_config_field, ^path, "providers"}} = load.()
    end

    for {id, entry} <- [
          {"Bad Id", %{"adapter" => "inst"}},
          {"inst-x", %{"models" => ["a"]}},
          {"inst-x", %{"adapter" => 42}},
          {"inst-x", "inst"}
        ] do
      path = write_config(home, JSON.encode!(%{"providers" => %{id => entry}}))
      assert {:error, {:invalid_config_provider, ^path, ^id}} = load.()
    end

    # Providers of adapters this host lacks are skipped.
    write_config(home, JSON.encode!(%{"providers" => %{"gpu" => %{"adapter" => "nope"}}}))
    assert {:ok, config} = load.()
    refute Enum.any?(config.providers, &(&1.id == "gpu"))

    write_config(home, JSON.encode!(%{"providers" => %{"test" => %{"adapter" => "inst"}}}))
    assert {:error, {:provider_adapter_conflict, "test"}} = load.()

    path = write_config(home, JSON.encode!(%{"provider_options" => %{}}))
    assert {:error, {:unknown_config_fields, ^path, ["provider_options"]}} = load.()
  end

  test "unknown fields and malformed JSON return errors", %{home: home, env: env} do
    path = write_config(home, ~s({"model":"test/file","adapter":"Elixir.System"}))

    assert {:error, {:unknown_config_fields, ^path, ["adapter"]}} =
             Config.load(available_adapters: [Adapter], env: env)

    File.write!(path, ~s({"model":))

    assert {:error, {:malformed_config_file, ^path}} =
             Config.load(available_adapters: [Adapter], env: env)
  end

  test "session titles are enabled by default and configurable through config.json", %{
    home: home,
    env: env
  } do
    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/default"]
             )

    assert %Tackle.Config.SessionTitles{model_ref: nil, selection: nil} = config.session_titles

    write_config(
      home,
      JSON.encode!(%{"session_titles" => %{"model" => "test/file"}})
    )

    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert %Tackle.Config.SessionTitles{model_ref: "test/file"} = config.session_titles
    assert config.session_titles.selection.model == "file"

    write_config(home, ~s({"session_titles": false}))

    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert config.session_titles == nil
  end

  test "session titles accept true and null as the default enabled form", %{home: home, env: env} do
    write_config(home, ~s({"session_titles": true}))

    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/default"]
             )

    assert %Tackle.Config.SessionTitles{model_ref: nil} = config.session_titles

    write_config(home, ~s({"session_titles": null}))

    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/default"]
             )

    assert %Tackle.Config.SessionTitles{model_ref: nil} = config.session_titles
  end

  test "invalid session-titles configuration returns errors", %{home: home, env: env} do
    path = write_config(home, ~s({"session_titles": "yes"}))

    assert {:error, {:invalid_config_field, ^path, "session_titles"}} =
             Config.load(available_adapters: [Adapter], env: env)

    write_config(home, JSON.encode!(%{"session_titles" => %{"unknown" => true}}))

    assert {:error, {:invalid_config_field, ^path, "session_titles"}} =
             Config.load(available_adapters: [Adapter], env: env)

    write_config(home, JSON.encode!(%{"session_titles" => %{"model" => "test/missing"}}))

    assert {:error, {:unknown_model, "test/missing"}} =
             Config.load(available_adapters: [Adapter], env: env)
  end

  test "the compile gate is off by default and turned on through config.json", %{
    home: home,
    env: env
  } do
    load = fn ->
      Config.load(available_adapters: [Adapter], env: env, overrides: [model: "test/default"])
    end

    log_path = Path.join([home, "logs", "compile_gate.jsonl"])

    assert {:ok, config} = load.()
    assert config.compile_gate == nil
    refute Tackle.Elixir.CompileGate in Config.to_agent_state(config).hooks

    write_config(home, ~s({"compile_gate": null}))
    assert {:ok, %{compile_gate: nil}} = load.()

    for on <- [~s({"compile_gate": true}), ~s({"compile_gate": {}})] do
      write_config(home, on)
      assert {:ok, config} = load.()

      assert %CompileGateSettings{
               enabled: true,
               max_rounds: 2,
               warnings: true,
               log_path: ^log_path
             } = config.compile_gate

      state = Config.to_agent_state(config)
      assert List.last(state.hooks) == Tackle.Elixir.CompileGate
      assert state.context.compile_gate == config.compile_gate
    end

    write_config(
      home,
      JSON.encode!(%{
        "compile_gate" => %{"max_rounds" => 0, "timeout_seconds" => 30, "warnings" => false}
      })
    )

    assert {:ok, config} = load.()

    assert %CompileGateSettings{
             max_rounds: 0,
             timeout_ms: 30_000,
             warnings: false,
             log_path: ^log_path
           } =
             config.compile_gate

    for off <- [~s({"compile_gate": false}), ~s({"compile_gate": {"enabled": false}})] do
      write_config(home, off)
      assert {:ok, config} = load.()
      assert config.compile_gate == nil
      state = Config.to_agent_state(config)
      refute Tackle.Elixir.CompileGate in state.hooks
      refute Map.has_key?(state.context, :compile_gate)
    end
  end

  test "Config.new/1 leaves the compile gate off unless asked" do
    assert {:ok, config} = Config.new(providers: [Adapter], model: "test/default")
    assert config.compile_gate == nil
    refute Tackle.Elixir.CompileGate in Config.to_agent_state(config).hooks

    assert {:ok, config} =
             Config.new(
               providers: [Adapter],
               model: "test/default",
               compile_gate: [max_rounds: 1],
               hooks: [Tackle.Elixir.CompileGate],
               context: %{compile_gate: :host_settings}
             )

    state = Config.to_agent_state(config)
    assert state.hooks == [Tackle.Elixir.CompileGate]
    assert state.context.compile_gate == :host_settings
  end

  test "invalid compile gate configuration returns errors", %{home: home, env: env} do
    path = write_config(home, ~s({"compile_gate": "yes"}))

    assert {:error, {:invalid_config_field, ^path, "compile_gate"}} =
             Config.load(available_adapters: [Adapter], env: env)

    write_config(home, JSON.encode!(%{"compile_gate" => %{"log_path" => "/tmp/x"}}))

    assert {:error, {:invalid_config_field, ^path, "compile_gate"}} =
             Config.load(available_adapters: [Adapter], env: env)

    write_config(home, JSON.encode!(%{"compile_gate" => %{"max_rounds" => -1}}))

    assert {:error, {:invalid_option, :compile_gate, {:max_rounds, -1}}} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/default"]
             )
  end

  test "the watchdog is off by default and configurable through config.json", %{
    home: home,
    env: env
  } do
    adapters = [Adapter, JudgeAdapter]
    overrides = [model: "test/default"]

    assert {:ok, config} =
             Config.load(available_adapters: adapters, env: env, overrides: overrides)

    assert config.watchdog == nil

    write_config(
      home,
      JSON.encode!(%{
        "watchdog" => %{"model" => "judge/small", "after_seconds" => 30, "threshold" => 0.9}
      })
    )

    assert {:ok, config} =
             Config.load(available_adapters: adapters, env: env, overrides: overrides)

    assert %Tackle.Config.Watchdog{model_ref: "judge/small", after_seconds: 30, threshold: 0.9} =
             config.watchdog

    assert config.watchdog.selection.adapter == JudgeAdapter

    write_config(
      home,
      JSON.encode!(%{"watchdog" => %{"model" => "judge/small", "enabled" => false}})
    )

    assert {:ok, config} =
             Config.load(available_adapters: adapters, env: env, overrides: overrides)

    assert config.watchdog == nil

    write_config(home, ~s({"watchdog": false}))

    assert {:ok, config} =
             Config.load(available_adapters: adapters, env: env, overrides: overrides)

    assert config.watchdog == nil
  end

  test "invalid watchdog configuration returns errors", %{home: home, env: env} do
    adapters = [Adapter, JudgeAdapter]

    load = fn ->
      Config.load(available_adapters: adapters, env: env, overrides: [model: "test/default"])
    end

    path = write_config(home, ~s({"watchdog": true}))
    assert {:error, {:invalid_config_field, ^path, "watchdog"}} = load.()

    write_config(home, JSON.encode!(%{"watchdog" => %{"model" => "judge/small", "unknown" => 1}}))
    assert {:error, {:invalid_config_field, ^path, "watchdog"}} = load.()

    write_config(home, JSON.encode!(%{"watchdog" => %{}}))
    assert {:error, {:invalid_option, :watchdog, model: nil}} = load.()

    write_config(
      home,
      JSON.encode!(%{"watchdog" => %{"model" => "judge/small", "threshold" => 1.5}})
    )

    assert {:error, {:invalid_option, :watchdog, threshold: 1.5}} = load.()

    write_config(
      home,
      JSON.encode!(%{"watchdog" => %{"model" => "judge/small", "after_seconds" => 0}})
    )

    assert {:error, {:invalid_option, :watchdog, after_seconds: 0}} = load.()

    write_config(home, JSON.encode!(%{"watchdog" => %{"model" => "judge/missing"}}))
    assert {:error, {:unknown_decision_model, "judge/missing"}} = load.()

    write_config(home, JSON.encode!(%{"watchdog" => %{"model" => "test/default"}}))
    assert {:error, {:unsupported_decision_adapter, "test"}} = load.()
  end

  test "decision adapters are granted to tools with the config.json default model", %{
    home: home,
    env: env
  } do
    adapters = [Adapter, JudgeAdapter]

    load = fn ->
      Config.load(available_adapters: adapters, env: env, overrides: [model: "test/default"])
    end

    write_config(
      home,
      JSON.encode!(%{
        "decision_model" => "judge/small",
        "providers" => %{"judge" => %{"adapter" => "judge", "base_url" => "http://judge.local"}}
      })
    )

    assert {:ok, config} = load.()

    assert %Tackle.Lib.Decision.Selection{
             ref: "judge/small",
             provider_settings: %{"base_url" => "http://judge.local"}
           } = config.decision_model

    # Only providers implementing the decision contract are granted.
    assert config.context.decisions == %{
             providers: [
               %Provider{
                 id: "judge",
                 adapter: JudgeAdapter,
                 settings: %{"base_url" => "http://judge.local"}
               }
             ],
             options: [],
             default_model: "judge/small"
           }

    # Without a default the adapters are still granted; scripts name a model.
    write_config(home, ~s({"decision_model": null}))
    assert {:ok, config} = load.()
    assert config.decision_model == nil

    assert config.context.decisions == %{
             providers: [%Provider{id: "judge", adapter: JudgeAdapter, settings: %{}}],
             options: [],
             default_model: nil
           }

    # Sessions without decision adapters get no grant.
    assert {:ok, config} =
             Config.load(
               available_adapters: [Adapter],
               env: env,
               overrides: [model: "test/default"]
             )

    refute Map.has_key?(config.context, :decisions)

    # A host grant in the context is kept as given.
    assert {:ok, config} =
             Config.load(
               available_adapters: adapters,
               env: env,
               overrides: [model: "test/default", context: %{decisions: :host}]
             )

    assert config.context.decisions == :host

    # ...so a host can withhold decision models from tools explicitly.
    assert {:ok, config} =
             Config.load(
               available_adapters: adapters,
               env: env,
               overrides: [model: "test/default", context: %{decisions: nil}]
             )

    assert config.context.decisions == nil
  end

  test "invalid decision model configuration returns errors", %{home: home, env: env} do
    load = fn ->
      Config.load(
        available_adapters: [Adapter, JudgeAdapter],
        env: env,
        overrides: [model: "test/default"]
      )
    end

    path = write_config(home, ~s({"decision_model": 42}))
    assert {:error, {:invalid_config_field, ^path, "decision_model"}} = load.()

    write_config(home, ~s({"decision_model": "judge/missing"}))
    assert {:error, {:unknown_decision_model, "judge/missing"}} = load.()

    write_config(home, ~s({"decision_model": "test/default"}))
    assert {:error, {:unsupported_decision_adapter, "test"}} = load.()
  end

  test "review settings are configurable through config.json", %{home: home, env: env} do
    load = fn ->
      Config.load(available_adapters: [Adapter], env: env, overrides: [model: "test/default"])
    end

    assert {:ok, config} = load.()
    assert config.review == nil
    refute Map.has_key?(config.context, :review_settings)

    write_config(home, ~s({"review": {"thinking": {"detector": "low", "scorer": "off"}}}))
    assert {:ok, config} = load.()
    review = %Tackle.Review.Settings{thinking: %{detector: "low", scorer: "off"}}
    assert config.review == review
    assert config.context.review_settings == review

    write_config(home, ~s({
      "review": {
        "profile": "quiet",
        "models": {"verifier": "test/file"},
        "thinking": {"verifier": "low"},
        "max_steps": {"detector": 12, "verifier": 6},
        "default_rules": ["injection", "unhandled-error"]
      }
    }))

    assert {:ok, config} = load.()

    assert config.review == %Tackle.Review.Settings{
             profile: :quiet,
             models: %{verifier: "test/file"},
             thinking: %{verifier: "low"},
             max_steps: %{detector: 12, verifier: 6},
             default_rules: ["injection", "unhandled-error"]
           }

    write_config(home, ~s({"review": {"profile": null, "default_rules": null}}))
    assert {:ok, %{review: %Tackle.Review.Settings{profile: nil, default_rules: nil}}} = load.()

    write_config(home, ~s({"review": {}}))
    assert {:ok, %{review: %Tackle.Review.Settings{thinking: thinking}}} = load.()
    assert thinking == %{}

    write_config(home, ~s({"review": null}))
    assert {:ok, %{review: nil}} = load.()
  end

  test "invalid review configuration returns errors", %{home: home, env: env} do
    load = fn ->
      Config.load(available_adapters: [Adapter], env: env, overrides: [model: "test/default"])
    end

    for review <- [
          ~s("low"),
          ~s({"samples": 3}),
          ~s({"thinking": "low"}),
          ~s({"thinking": {"planner": "low"}}),
          ~s({"thinking": {"detector": "huge"}}),
          ~s({"thinking": {"detector": null}}),
          ~s({"models": {"verifier": ""}}),
          ~s({"profile": "loud"}),
          ~s({"max_steps": {"detector": 0}}),
          ~s({"max_steps": {"detector": "6"}}),
          ~s({"default_rules": "injection"}),
          ~s({"default_rules": [1]})
        ] do
      path = write_config(home, ~s({"review": #{review}}))
      assert {:error, {:invalid_config_field, ^path, "review"}} = load.(), review
    end

    # Values the file format allows but the settings reject.
    write_config(home, ~s({"review": {"max_steps": {"scorer": 3}}}))
    assert {:error, {:invalid_option, :review, _}} = load.()

    write_config(home, ~s({"review": {"default_rules": ["no-jason"]}}))
    assert {:error, {:unknown_default_rules, ["no-jason"]}} = load.()

    write_config(home, ~s({"review": {"models": {"verifier": "test/missing"}}}))
    assert {:error, _unknown_model} = load.()
  end

  test "narration is off by default and configurable through config.json", %{
    home: home,
    env: env
  } do
    overrides = [model: "test/default"]

    assert {:ok, config} =
             Config.load(available_adapters: [Adapter], env: env, overrides: overrides)

    assert config.narration == nil

    write_config(
      home,
      JSON.encode!(%{
        "narration" => %{
          "model" => "test/file",
          "interval_seconds" => 3,
          "first_after_seconds" => 2.5
        }
      })
    )

    assert {:ok, config} =
             Config.load(available_adapters: [Adapter], env: env, overrides: overrides)

    assert %Narration{
             model_ref: "test/file",
             interval_seconds: 3,
             first_after_seconds: 2.5
           } = config.narration

    assert config.narration.selection.adapter == Adapter
    assert config.narration.selection.model == "file"
    assert Narration.interval_ms(config.narration) == 3_000
    assert Narration.first_after_ms(config.narration) == 2_500

    write_config(home, JSON.encode!(%{"narration" => %{"model" => "test/file"}}))

    assert {:ok, config} =
             Config.load(available_adapters: [Adapter], env: env, overrides: overrides)

    assert %Narration{interval_seconds: 5, first_after_seconds: 5} =
             config.narration

    write_config(
      home,
      JSON.encode!(%{"narration" => %{"model" => "test/file", "enabled" => false}})
    )

    assert {:ok, config} =
             Config.load(available_adapters: [Adapter], env: env, overrides: overrides)

    assert config.narration == nil

    for disabled <- [~s({"narration": false}), ~s({"narration": null})] do
      write_config(home, disabled)

      assert {:ok, config} =
               Config.load(available_adapters: [Adapter], env: env, overrides: overrides)

      assert config.narration == nil
    end
  end

  test "invalid narration configuration returns errors", %{home: home, env: env} do
    load = fn ->
      Config.load(available_adapters: [Adapter], env: env, overrides: [model: "test/default"])
    end

    path = write_config(home, ~s({"narration": true}))
    assert {:error, {:invalid_config_field, ^path, "narration"}} = load.()

    write_config(home, JSON.encode!(%{"narration" => %{"model" => "test/file", "unknown" => 1}}))
    assert {:error, {:invalid_config_field, ^path, "narration"}} = load.()

    # The model is required: narration never falls back to the session model.
    write_config(home, JSON.encode!(%{"narration" => %{}}))
    assert {:error, {:invalid_option, :narration, model: nil}} = load.()

    write_config(home, JSON.encode!(%{"narration" => %{"model" => ""}}))
    assert {:error, {:invalid_option, :narration, model: ""}} = load.()

    write_config(
      home,
      JSON.encode!(%{"narration" => %{"model" => "test/file", "interval_seconds" => 0}})
    )

    assert {:error, {:invalid_option, :narration, interval_seconds: 0}} = load.()

    write_config(
      home,
      JSON.encode!(%{"narration" => %{"model" => "test/file", "first_after_seconds" => "5"}})
    )

    assert {:error, {:invalid_option, :narration, first_after_seconds: "5"}} = load.()

    write_config(
      home,
      JSON.encode!(%{"narration" => %{"model" => "test/file", "enabled" => "yes"}})
    )

    assert {:error, {:invalid_option, :narration, enabled: "yes"}} = load.()

    write_config(home, JSON.encode!(%{"narration" => %{"model" => "test/missing"}}))
    assert {:error, {:unknown_model, "test/missing"}} = load.()

    write_config(home, JSON.encode!(%{"narration" => %{"model" => "other/model"}}))
    assert {:error, {:unknown_provider, "other"}} = load.()
  end

  test "module-looking strings are data and are never converted to atoms", %{home: home, env: env} do
    module_name = "Elixir.UnloadedTackleAdapter#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
    path = write_config(home, JSON.encode!(%{"adapter" => module_name}))

    assert {:error, {:unknown_config_fields, ^path, ["adapter"]}} =
             Config.load(available_adapters: [Adapter], env: env)

    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
  end

  test "TACKLE_HOME path resolution does not consult the real home", %{home: home, env: env} do
    assert {:ok, ^home} = Tackle.Paths.home(env: env, user_home: nil)
    assert {:ok, path} = Tackle.Paths.config_file(env: env, user_home: nil)
    assert path == Path.join(home, "config.json")
  end

  test "default home is a .tackle directory under the user home" do
    user_home = Path.join(System.tmp_dir!(), "tackle-user-home")
    assert {:ok, path} = Tackle.Paths.home(env: %{}, user_home: user_home)
    assert path == Path.join(user_home, ".tackle")
  end

  test "missing user home is explicit" do
    assert {:error, :user_home_unavailable} = Tackle.Paths.home(env: %{}, user_home: nil)
  end

  defp write_config(home, contents) do
    File.mkdir_p!(home)
    path = Path.join(home, "config.json")
    File.write!(path, contents)
    path
  end
end
