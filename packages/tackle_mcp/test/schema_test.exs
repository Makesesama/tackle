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

  test "projects nullable unions and type arrays while preserving explicit null" do
    colors = ["dark-pink", "none"]

    schema = %{
      "type" => "object",
      "properties" => %{
        "color" => %{
          "anyOf" => [%{"type" => "string", "enum" => colors}, %{"type" => "null"}],
          "description" => "New project color. Use null to clear."
        },
        "due_on" => %{"oneOf" => [%{"type" => "null"}, %{"type" => "string"}]},
        "limit" => %{"type" => ["integer", "null"]}
      }
    }

    assert {:ok, projected} = Schema.to_tackle(schema)

    assert projected == [
             color: [
               type: :string,
               required: false,
               description: "New project color. Use null to clear.",
               enum: colors ++ [nil],
               nullable: true
             ],
             due_on: [type: :string, required: false, nullable: true],
             limit: [type: :integer, required: false, nullable: true]
           ]

    assert {:ok, %{"color" => nil}} =
             Tackle.Lib.Tool.Schema.validate(projected, %{"color" => nil})

    assert {:error, [%{field: "color"}]} =
             Tackle.Lib.Tool.Schema.validate(projected, %{"color" => "blue"})
  end

  test "rejects option values Tackle cannot register" do
    for {property, message} <- [
          {%{"type" => "string", "enum" => "one"}, "field :value option :enum must be a list"},
          {%{"type" => "string", "description" => 42},
           "field :value option :description must be a string"}
        ] do
      assert {:error, {:invalid_input_schema, ^message}} =
               Schema.to_tackle(%{"type" => "object", "properties" => %{"value" => property}})
    end
  end

  test "rejects unions that are not a single type plus null" do
    for property <- [
          %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]},
          %{"anyOf" => [%{"type" => "string"}, %{"type" => "null", "description" => "x"}]},
          %{"type" => ["string", "integer"]},
          %{"type" => ["string", "integer", "null"]}
        ] do
      assert {:error, {:unsupported_property_schema, ^property}} =
               Schema.to_tackle(%{"type" => "object", "properties" => %{"value" => property}})
    end
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
