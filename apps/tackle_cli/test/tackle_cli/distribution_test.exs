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

  test "bundles Codex and DeepSeek as the default adapters" do
    assert Distribution.default_adapters() == [
             Tackle.Plugins.Codex,
             Tackle.Plugins.DeepSeek
           ]
  end

  test "registers both bundled adapters with the harness" do
    Application.delete_env(:tackle, :adapters)

    assert :ok = Distribution.configure()

    assert Application.fetch_env!(:tackle, :adapters) == [
             Tackle.Plugins.Codex,
             Tackle.Plugins.DeepSeek
           ]
  end
end
