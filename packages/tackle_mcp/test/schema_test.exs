defmodule Tackle.Plugins.MCP.SchemaTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.MCP.Schema

  test "projects top-level JSON Schema fields" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "count" => %{"type" => "integer", "default" => 2},
        "filters" => %{"type" => "object", "description" => "Search filters"},
        "query" => %{"type" => "string", "enum" => ["one", "two"]},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["query"]
    }

    assert {:ok, projected} = Schema.to_tackle(schema)

    assert projected == [
             count: [type: :integer, required: false, default: 2],
             filters: [type: :map, required: false, description: "Search filters"],
             query: [type: :string, required: true, enum: ["one", "two"]],
             tags: [type: {:list, :string}, required: false]
           ]
  end

  test "accepts MCP object-or-string property as an object" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "params" => %{
          "description" => "Filter parameters",
          "oneOf" => [%{"type" => "object"}, %{"type" => "string"}]
        }
      }
    }

    assert {:ok, [params: [type: :map, required: false, description: "Filter parameters"]]} =
             Schema.to_tackle(schema)
  end

  test "rejects malformed or unsupported root schemas" do
    assert {:error, {:unsupported_root_type, "array"}} =
             Schema.to_tackle(%{"type" => "array"})

    assert {:error, {:invalid_properties, []}} =
             Schema.to_tackle(%{"type" => "object", "properties" => []})

    assert {:error, {:unsupported_property_schema, %{"oneOf" => []}}} =
             Schema.to_tackle(%{
               "type" => "object",
               "properties" => %{"value" => %{"oneOf" => []}}
             })
  end
end
