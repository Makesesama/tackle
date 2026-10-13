defmodule Tackle.Config.FileTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
  alias Tackle.Config.Narration

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
    assert config.llm_opts == [reasoning_effort: "high", reasoning_summary: "auto"]
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

  test "environment overrides the file", %{home: home, env: env} do
    write_config(home, ~s({"model":"test/file","thinking":"low"}))

    env =
      env
      |> Map.put("TACKLE_MODEL", "test/environment")
      |> Map.put("TACKLE_THINKING", "xhigh")

    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert config.model_ref == "test/environment"
    assert config.llm_opts == [reasoning_effort: "xhigh", reasoning_summary: "auto"]
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
    assert config.llm_opts == [reasoning_effort: "medium", reasoning_summary: "auto"]
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

  test "passes adapter-keyed provider options through as an LLM option", %{
    home: home,
    env: env
  } do
    route = %{"only" => ["mistral/zdr"], "allow_fallbacks" => false}
    options = %{"test" => %{"provider_routing" => %{"file" => route}}}

    write_config(
      home,
      JSON.encode!(%{"model" => "test/file", "thinking" => "low", "provider_options" => options})
    )

    assert {:ok, config} = Config.load(available_adapters: [Adapter], env: env)
    assert config.llm_opts[:provider_options] == options
    assert config.llm_opts[:reasoning_effort] == "low"

    # Switching models or thinking keeps the adapter settings.
    assert {:ok, switched} = Config.reconfigure(config, model: "test/override", thinking: "off")
    assert switched.llm_opts[:provider_options] == options
  end

  test "rejects malformed or secret-bearing provider options", %{home: home, env: env} do
    for options <- [[1], "openrouter", %{"test" => "route"}] do
      write_config(home, JSON.encode!(%{"model" => "test/file", "provider_options" => options}))

      assert {:error, {:invalid_config_field, _path, "provider_options"}} =
               Config.load(available_adapters: [Adapter], env: env)
    end

    write_config(
      home,
      JSON.encode!(%{
        "model" => "test/file",
        "provider_options" => %{"test" => %{"api_key" => "secret"}}
      })
    )

    assert {:error, {:reserved_llm_option, "api_key"}} =
             Config.load(available_adapters: [Adapter], env: env)
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
        "provider_options" => %{"judge" => %{"base_url" => "http://judge.local"}}
      })
    )

    assert {:ok, config} = load.()
    assert %Tackle.Lib.Decision.Selection{ref: "judge/small"} = config.decision_model

    # Only adapters implementing the decision contract are granted.
    assert config.context.decisions == %{
             adapters: [JudgeAdapter],
             options: [provider_options: %{"judge" => %{"base_url" => "http://judge.local"}}],
             default_model: "judge/small"
           }

    # Without a default the adapters are still granted; scripts name a model.
    write_config(home, ~s({"decision_model": null}))
    assert {:ok, config} = load.()
    assert config.decision_model == nil

    assert config.context.decisions == %{
             adapters: [JudgeAdapter],
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
    assert {:error, {:unknown_adapter, "other"}} = load.()
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
