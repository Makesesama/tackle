defmodule Tackle.Tool.Adapters.WebTest do
  use ExUnit.Case, async: true

  alias Tackle.Tool.Adapters.Web

  defmodule SearchTool do
    use Tackle.Tool

    tool_name("search")
    description("Search indexed documents.")

    input do
      field :query, :string, required: true
    end

    def run(args, _context), do: {:ok, args}
  end

  defmodule ManualTool do
    @behaviour Tackle.Tool

    @impl true
    def name, do: "manual"

    @impl true
    def description, do: "Manually implemented tool."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(args, _context), do: {:ok, args}
  end

  defmodule InvalidTool do
    def name, do: "invalid"
  end

  test "wrap/1 validates and returns DSL tools unchanged" do
    assert Web.wrap([SearchTool]) == [SearchTool]
  end

  test "wrap/1 accepts a single tool module" do
    assert Web.wrap(SearchTool) == [SearchTool]
  end

  test "wrap/1 accepts manually implemented Tackle.Tool modules" do
    assert Web.wrap([ManualTool]) == [ManualTool]
  end

  test "wrapped tools can be passed to Tackle.Tool.Registry" do
    registry = Web.wrap([SearchTool]) |> Tackle.Tool.Registry.new()

    assert [%{name: "search"}] = Tackle.Tool.Registry.definitions(registry)
  end

  test "wrap/1 raises a helpful error for invalid tool modules" do
    assert_raise ArgumentError, ~r/InvalidTool.*missing callbacks: description\/0/, fn ->
      Web.wrap([InvalidTool])
    end
  end

  test "wrap/1 raises a helpful error for non-module values" do
    assert_raise ArgumentError, ~r/expects a module or list of modules/, fn ->
      Web.wrap(["not a module"])
    end
  end
end
