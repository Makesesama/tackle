defmodule Tackle.Lib.Integrations.RegistryTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Integrations.Registry
  alias Tackle.Lib.Tool

  defmodule FirstTool do
    use Tackle.Lib.Tool

    tool_name("first")
    description("First tool.")

    input do
      field(:value, :string, required: true)
    end

    def run(%{"value" => value}, _context), do: {:ok, value}
  end

  defmodule SecondTool do
    use Tackle.Lib.Tool

    tool_name("second")
    description("Second tool.")

    input do
      field(:value, :string, required: true)
    end

    def run(%{"value" => value}, _context), do: {:ok, value}
  end

  test "new/1 keeps the declaration order and reports tool definitions" do
    registry = Registry.new([FirstTool, SecondTool])

    assert Enum.map(Registry.entries(registry), & &1.name) == ["first", "second"]

    assert Enum.map(Registry.entries(registry), & &1.module) == [FirstTool, SecondTool]

    assert Enum.map(Registry.entries(registry), & &1.definition) == [
             Tool.definition(FirstTool),
             Tool.definition(SecondTool)
           ]
  end

  test "lookup/2 resolves a public tool name and reports missing tools as nil" do
    registry = Registry.new([FirstTool])

    assert %{name: "first", module: FirstTool, definition: definition} =
             Registry.lookup(registry, "first")

    assert definition.name == "first"
    assert Registry.lookup(registry, "missing") == nil
  end

  test "new/1 accepts an empty tool list" do
    assert Registry.new([]) |> Registry.entries() == []
  end
end
