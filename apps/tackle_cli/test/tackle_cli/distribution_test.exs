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
