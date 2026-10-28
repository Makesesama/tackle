defmodule Tackle.CLI.DistributionTest do
  use ExUnit.Case, async: false

  alias Tackle.CLI.Distribution
  alias Tackle.Plugins.Catalog

  defmodule PluginTool do
    def name, do: "plugin_probe"
    def description, do: "A plugin project's tool."
    def parameters_schema, do: []
    def execute(_args, _context), do: {:ok, "probed"}
  end

  test "the CLI's real catalog includes its bundled adapters and default coding tools" do
    assert {:ok, catalog} = Distribution.catalog()
    assert Catalog.adapter_modules(catalog) == Distribution.default_adapters()

    assert {:ok, [%{module: Tackle.Tools.Read, source: :tackle}]} =
             Catalog.resolve_tools(catalog, ["read"])
  end

  test "the catalog bundles the workflow, review, and rule check tools next to the subagent tools" do
    assert {:ok, catalog} = Distribution.catalog()

    assert {:ok, [%{module: Tackle.Workflow.Tool, source: :tackle}]} =
             Catalog.resolve_tools(catalog, ["run_workflow"])

    assert {:ok, [%{module: Tackle.Tools.Review, source: :tackle}]} =
             Catalog.resolve_tools(catalog, ["review_changes"])

    assert {:ok, [%{module: Tackle.Tools.ReviewRules, source: :tackle}]} =
             Catalog.resolve_tools(catalog, ["check_review_rules"])

    assert Distribution.root_tool_names() == [
             "run_workflow",
             "review_changes",
             "check_review_rules"
           ]
  end

  test "the CLI's coding scope grants run_workflow and review_changes to a delegating root agent" do
    home = Path.join(System.tmp_dir!(), "tackle-cli-dist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    assert {:ok, catalog} = Distribution.catalog()
    assert {:ok, builtin_skills} = Distribution.builtin_skills()

    assert {:ok, spec} =
             Tackle.Coding.scope_spec(
               [
                 catalog: catalog,
                 builtin_skills: builtin_skills,
                 catalog_root_tools: Distribution.root_tool_names(),
                 overrides: [model: "ollama-cloud/gpt-oss:20b"],
                 cwd: home,
                 env: %{"TACKLE_HOME" => home}
               ],
               nil
             )

    assert Tackle.Workflow.Tool in spec.root_spec.config.tools
    assert Tackle.Tools.Review in spec.root_spec.config.tools
    assert Tackle.Tools.ReviewRules in spec.root_spec.config.tools
    assert Tackle.Tools.Subagent in spec.root_spec.config.tools

    # The review stages it delegates to are among the scope's profiles.
    assert Map.has_key?(spec.profiles, "review-detector")
    assert Map.has_key?(spec.profiles, "review-verifier")
    assert spec.root_spec.allow_delegation

    # The workflow guide is offered with the tool, through load_skill.
    assert Tackle.Tools.LoadSkill in spec.root_spec.config.tools
    assert spec.root_spec.config.system_prompt =~ "<name>tackle-workflows</name>"

    assert {:ok, guide} =
             Tackle.Tools.LoadSkill.run(
               %{"name" => "tackle-workflows"},
               spec.root_spec.config.context
             )

    assert guide =~ "tackle.parallel(items, fn, opts?)"

    # So is the review rule guide, with the rule check.
    assert spec.root_spec.config.system_prompt =~ "<name>tackle-review-rules</name>"

    assert {:ok, rule_guide} =
             Tackle.Tools.LoadSkill.run(
               %{"name" => "tackle-review-rules"},
               spec.root_spec.config.context
             )

    assert rule_guide =~ "check_review_rules"

    # Profiles do not inherit the workflow tool unless they list it explicitly,
    # and so are not offered its guide either.
    for {_name, profile} <- spec.profiles do
      refute Tackle.Workflow.Tool in profile.config.tools
      refute Tackle.Tools.Review in profile.config.tools
      refute Tackle.Tools.ReviewRules in profile.config.tools
      refute Tackle.Tools.LoadSkill in profile.config.tools
      refute profile.config.system_prompt =~ "tackle-workflows"
      refute profile.config.system_prompt =~ "tackle-review-rules"
    end
  end

  test "every command takes plugin contributions from the one catalog" do
    previous = Application.get_env(:tackle_cli, :plugins)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tackle_cli, :plugins, previous),
        else: Application.delete_env(:tackle_cli, :plugins)
    end)

    source = {:project, "/plugins/probe"}

    Application.put_env(:tackle_cli, :plugins, %Catalog{
      adapters: [],
      tools: [%{module: PluginTool, source: source}],
      hooks: []
    })

    assert {:ok, catalog} = Distribution.catalog()

    assert {:ok, [%{module: PluginTool, source: ^source}]} =
             Catalog.resolve_tools(catalog, ["plugin_probe"])

    assert Distribution.plugin_tools() == [PluginTool]

    assert Distribution.root_tool_names() == [
             "run_workflow",
             "review_changes",
             "check_review_rules",
             "plugin_probe"
           ]
  end

  test "the bundled guides are valid built-in skills gated on their tools" do
    assert {:ok, [workflows, review_rules]} = Distribution.builtin_skills()
    assert workflows.name == "tackle-workflows"
    assert workflows.source == :builtin
    assert workflows.requires_tools == ["run_workflow"]
    assert review_rules.name == "tackle-review-rules"
    assert review_rules.source == :builtin
    assert review_rules.requires_tools == ["check_review_rules"]
  end

  test "bundles Codex, DeepSeek, Anthropic, OpenRouter, and Ollama as default adapters" do
    assert Distribution.default_adapters() == [
             Tackle.Plugins.Codex,
             Tackle.Plugins.DeepSeek,
             Tackle.Plugins.Anthropic,
             Tackle.Plugins.OpenRouter,
             Tackle.Plugins.Ollama
           ]
  end

  test "exposes selectable Ollama Cloud models and auth flows through the CLI catalog" do
    assert {:ok, models} = Distribution.available_models()
    assert "ollama-cloud/gpt-oss:120b" in models
    assert "ollama-cloud/gpt-oss:20b" in models

    assert {:ok, adapters} = Distribution.adapters()

    assert {:ok, selection} =
             Tackle.Lib.LLM.select(adapters, "ollama-cloud/gpt-oss:120b")

    assert selection.adapter == Tackle.Plugins.Ollama
    assert selection.provider_id == "ollama-cloud"
    assert selection.model == "gpt-oss:120b"

    assert {:ok, providers} = Tackle.Auth.Flows.list(adapters)
    provider = Enum.find(providers, &(&1.id == "ollama-cloud"))
    assert provider.module == Tackle.Plugins.Ollama
    assert provider.adapter == "ollama"
    assert provider.source == :default
    assert provider.capabilities.login
    refute provider.capabilities.usage

    assert {:error, {:unsupported_provider_flow, "ollama-cloud", :usage}} =
             Tackle.Auth.Flows.usage(adapters, "ollama-cloud")

    # The local server needs no key, so it reports no credential status.
    assert {:ok, :not_required} = Tackle.Auth.Flows.status(adapters, "ollama")
  end

  test "exposes the default local Ollama decision model and configured chat models" do
    previous = Application.get_env(:tackle_ollama, Tackle.Plugins.Ollama)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tackle_ollama, Tackle.Plugins.Ollama, previous),
        else: Application.delete_env(:tackle_ollama, Tackle.Plugins.Ollama)
    end)

    # By default the distribution offers the tev1 decision model (watchdog)
    # and one small chat model (narration).
    assert {:ok, models} = Distribution.available_models()
    assert Enum.filter(models, &String.starts_with?(&1, "ollama/")) == ["ollama/gemma4:12b"]
    assert {:ok, catalog} = Distribution.catalog()
    adapters = Catalog.adapter_modules(catalog)

    assert {:ok, %{adapter: Tackle.Plugins.Ollama, provider_id: "ollama"} = decision} =
             Tackle.Lib.Decision.select(adapters, "ollama/tev1:4b")

    assert decision.local

    assert {:ok, %{adapter: Tackle.Plugins.Ollama, provider_id: "ollama"}} =
             Tackle.Lib.LLM.select(adapters, "ollama/gemma4:12b")

    Application.put_env(:tackle_ollama, Tackle.Plugins.Ollama,
      providers: %{"ollama" => %{"models" => ["qwen3:8b"], "decision_models" => ["tev1:4b"]}}
    )

    assert {:ok, models} = Distribution.available_models()
    assert "ollama/qwen3:8b" in models

    assert {:ok, %{adapter: Tackle.Plugins.Ollama}} =
             Tackle.Lib.LLM.select(adapters, "ollama/qwen3:8b")
  end

  test "offers models of recorded accounts and config.json providers" do
    home = Path.join(System.tmp_dir!(), "tackle-cli-dist-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("TACKLE_HOME")
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{
        "providers" => %{
          "ollama-gpu-box" => %{
            "adapter" => "ollama",
            "base_url" => "http://gpu:11434/v1",
            "local" => true,
            "models" => ["gpt-oss:20b"]
          }
        }
      })
    )

    System.put_env("TACKLE_HOME", home)
    :ok = Tackle.Auth.put_account("codex-work", %{"adapter" => "openai-codex"})

    :ok =
      Tackle.Auth.put_account("cloud2", %{"adapter" => "ollama", "base" => "ollama-cloud"})

    on_exit(fn ->
      Tackle.Auth.delete_account("codex-work")
      Tackle.Auth.delete_account("cloud2")
      if previous_home, do: System.put_env("TACKLE_HOME", previous_home)
      File.rm_rf!(home)
    end)

    assert {:ok, models} = Distribution.available_models()
    assert "ollama-gpu-box/gpt-oss:20b" in models
    assert Enum.any?(models, &String.starts_with?(&1, "codex-work/"))
    assert Enum.any?(models, &String.starts_with?(&1, "openai-codex/"))

    assert {:ok, providers} = Distribution.available_providers()

    assert %{
             "codex-work" => "openai-codex",
             "openai-codex" => "openai-codex",
             "ollama" => "ollama",
             "ollama-gpu-box" => "ollama",
             "cloud2" => "ollama"
           } = Distribution.provider_adapters(providers)

    # An account created from ollama-cloud inherits its settings, except the
    # environment variable that holds ollama-cloud's own key.
    cloud = Enum.find(providers, &(&1.id == "ollama-cloud"))
    cloud2 = Enum.find(providers, &(&1.id == "cloud2"))
    assert cloud2.settings == Map.delete(cloud.settings, "api_key_env")
    assert cloud2.settings["api_key"] == "required"
    assert ("cloud2/" <> hd(cloud.settings["models"])) in models
  end
end
