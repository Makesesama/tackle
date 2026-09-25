defmodule Tackle.Plugins.CatalogTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.Catalog

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM
    def adapter_id, do: "catalog-test"
    def models, do: ["small"]
    def generate(_, _), do: {:error, :unused}
  end

  defmodule Tool do
    @behaviour Tackle.Lib.Tool
    def name, do: "search"
    def description, do: "Search"
    def parameters_schema, do: []
    def execute(_, _), do: {:ok, :unused}
  end

  defmodule Hook do
    @behaviour Tackle.Lib.Hook
    def after_turn(_, _), do: :ok
  end

  defmodule SecondHook do
    @behaviour Tackle.Lib.Hook
    def before_prompt(_, _), do: :ok
  end

  defmodule EmptyHook do
    @behaviour Tackle.Lib.Hook
  end

  defmodule InvalidAdapter do
    def adapter_id, do: "Bad id"
    def models, do: []
    def generate(_, _), do: {:error, :unused}
  end

  defmodule MissingGenerate do
    def adapter_id, do: "missing-generate"
    def models, do: ["small"]
  end

  defmodule DuplicateAdapter do
    @behaviour Tackle.Lib.LLM
    def adapter_id, do: "catalog-test"
    def models, do: ["small"]
    def generate(_, _), do: {:error, :unused}
  end

  defmodule DuplicateTool do
    @behaviour Tackle.Lib.Tool
    def name, do: "search"
    def description, do: "Another search"
    def parameters_schema, do: []
    def execute(_, _), do: {:ok, :unused}
  end

  defmodule MissingToolCallback do
    def name, do: "incomplete"
  end

  defmodule FailingTool do
    def name, do: raise("name failed")
    def description, do: "Failing tool"
    def parameters_schema, do: []
    def execute(_, _), do: {:ok, :unused}
  end

  defp entry(module, source), do: %{module: module, source: source}

  test "validates and retains ordered entries and source provenance" do
    sources = [:builtin, {:project, "plugins.exs"}]

    assert {:ok, catalog} =
             Catalog.new(
               adapters: [entry(Adapter, hd(sources))],
               tools: [entry(Tool, Enum.at(sources, 1))],
               hooks: [entry(Hook, :host), entry(SecondHook, :host)]
             )

    assert Catalog.adapters(catalog) == [entry(Adapter, :builtin)]
    assert Catalog.adapter_modules(catalog) == [Adapter]
    assert Catalog.tools(catalog) == [entry(Tool, Enum.at(sources, 1))]
    assert Catalog.hooks(catalog) == [entry(Hook, :host), entry(SecondHook, :host)]
    assert Catalog.hook_modules(catalog) == [Hook, SecondHook]
    assert {:ok, [%{module: Tool, source: source}]} = Catalog.resolve_tools(catalog, ["search"])
    assert source == Enum.at(sources, 1)

    assert {:error, {:unknown_tool, "not-granted"}} =
             Catalog.resolve_tools(catalog, ["not-granted"])
  end

  test "rejects duplicate adapter ids, tool names including builtin conflicts, and hooks" do
    assert {:error, {:invalid_plugin, :adapter, :second, {:duplicate, "catalog-test"}}} =
             Catalog.new(
               adapters: [entry(Adapter, :first), entry(DuplicateAdapter, :second)],
               tools: [],
               hooks: []
             )

    builtin = %{module: Tool, source: :builtin}
    custom = %{module: DuplicateTool, source: :project}

    assert {:error, {:invalid_plugin, :tool, :project, {:duplicate, "search"}}} =
             Catalog.new(adapters: [], tools: [builtin, custom], hooks: [])

    assert {:error, {:invalid_plugin, :hook, :again, {:duplicate, Hook}}} =
             Catalog.new(
               adapters: [],
               tools: [],
               hooks: [entry(Hook, :once), entry(Hook, :again)]
             )
  end

  test "rejects invalid adapter models, hook contracts, and malformed options" do
    assert {:error, {:invalid_plugin, :adapter, :bad, {:invalid_adapter_id, "Bad id"}}} =
             Catalog.new(adapters: [entry(InvalidAdapter, :bad)], tools: [], hooks: [])

    assert {:error, {:invalid_plugin, :hook, :empty, :no_hook_callbacks}} =
             Catalog.new(adapters: [], tools: [], hooks: [entry(EmptyHook, :empty)])

    assert {:error, {:invalid_plugin, :adapter, :missing, {:missing_callback, {:generate, 2}}}} =
             Catalog.new(adapters: [entry(MissingGenerate, :missing)], tools: [], hooks: [])

    assert {:error, {:invalid_plugin, :tool, :missing, {:missing_callback, {:description, 0}}}} =
             Catalog.new(adapters: [], tools: [entry(MissingToolCallback, :missing)], hooks: [])

    assert {:error, {:invalid_plugin, :tool, :failed, {:callback_failed, :name, "name failed"}}} =
             Catalog.new(adapters: [], tools: [entry(FailingTool, :failed)], hooks: [])

    assert {:error, {:invalid_plugin, :tool, :missing, :module_not_loaded}} =
             Catalog.new(adapters: [], tools: [entry(Unavailable, :missing)], hooks: [])

    assert {:error, {:missing_catalog_option, :hooks}} =
             Catalog.new(adapters: [], tools: [])

    assert {:error, {:invalid_tool_names, [:atom]}} =
             Catalog.resolve_tools(%Catalog{adapters: [], tools: [], hooks: []}, [:atom])
  end
end
