defmodule Tackle.CLI.DistributionTest do
  use ExUnit.Case, async: false

  alias Tackle.CLI.Distribution

  setup do
    previous_adapters = Application.get_env(:tackle, :adapters)

    on_exit(fn ->
      if is_nil(previous_adapters) do
        Application.delete_env(:tackle, :adapters)
      else
        Application.put_env(:tackle, :adapters, previous_adapters)
      end
    end)

    :ok
  end

  test "the CLI's real catalog includes its bundled adapters and default coding tools" do
    assert {:ok, catalog} = Distribution.catalog()
    assert Tackle.Plugins.Catalog.adapter_modules(catalog) == Distribution.default_adapters()

    assert {:ok, [%{module: Tackle.Tools.Read, source: :tackle}]} =
             Tackle.Plugins.Catalog.resolve_tools(catalog, ["read"])
  end

  test "the catalog bundles the workflow and review tools next to the subagent tools" do
    assert {:ok, catalog} = Distribution.catalog()

    assert {:ok, [%{module: Tackle.Workflow.Tool, source: :tackle}]} =
             Tackle.Plugins.Catalog.resolve_tools(catalog, ["run_workflow"])

    assert {:ok, [%{module: Tackle.Tools.Review, source: :tackle}]} =
             Tackle.Plugins.Catalog.resolve_tools(catalog, ["review_changes"])

    assert Distribution.root_tool_names() == ["run_workflow", "review_changes"]
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

    # Profiles do not inherit the workflow tool unless they list it explicitly,
    # and so are not offered its guide either.
    for {_name, profile} <- spec.profiles do
      refute Tackle.Workflow.Tool in profile.config.tools
      refute Tackle.Tools.Review in profile.config.tools
      refute Tackle.Tools.LoadSkill in profile.config.tools
      refute profile.config.system_prompt =~ "tackle-workflows"
    end
  end

  test "the bundled workflow guide is a valid built-in skill gated on run_workflow" do
    assert {:ok, [skill]} = Distribution.builtin_skills()
    assert skill.name == "tackle-workflows"
    assert skill.source == :builtin
    assert skill.requires_tools == ["run_workflow"]
  end

  test "bundles Codex, DeepSeek, Anthropic, OpenRouter, and Ollama Cloud as default adapters" do
    assert Distribution.default_adapters() == [
             Tackle.Plugins.Codex,
             Tackle.Plugins.DeepSeek,
             Tackle.Plugins.Anthropic,
             Tackle.Plugins.OpenRouter,
             Tackle.Plugins.Ollama
           ]
  end

  test "exposes selectable Ollama Cloud models and auth flows through the CLI catalog" do
    Application.delete_env(:tackle, :adapters)

    assert {:ok, models} = Distribution.available_models()
    assert "ollama-cloud/gpt-oss:120b" in models
    assert "ollama-cloud/gpt-oss:20b" in models

    assert {:ok, catalog} = Distribution.catalog()
    adapters = Tackle.Plugins.Catalog.adapter_modules(catalog)

    assert {:ok, selection} =
             Tackle.Lib.LLM.select(adapters, "ollama-cloud/gpt-oss:120b")

    assert selection.adapter == Tackle.Plugins.Ollama
    assert selection.model == "gpt-oss:120b"

    assert {:ok, Tackle.Plugins.Ollama} =
             Tackle.Auth.Provider.resolve("ollama-cloud", adapters: adapters)

    assert {:ok, providers} = Tackle.Auth.Provider.list(adapters: adapters)
    provider = Enum.find(providers, &(&1.id == "ollama-cloud"))
    assert provider.capabilities.login
    refute provider.capabilities.usage

    assert {:error, {:unsupported_provider_flow, "ollama-cloud", :usage}} =
             Tackle.Auth.Provider.usage("ollama-cloud", adapters: adapters)
  end

  test "registers the bundled adapters with the harness" do
    Application.delete_env(:tackle, :adapters)

    assert :ok = Distribution.configure()

    assert Application.fetch_env!(:tackle, :adapters) == [
             Tackle.Plugins.Codex,
             Tackle.Plugins.DeepSeek,
             Tackle.Plugins.Anthropic,
             Tackle.Plugins.OpenRouter,
             Tackle.Plugins.Ollama
           ]
  end
end
