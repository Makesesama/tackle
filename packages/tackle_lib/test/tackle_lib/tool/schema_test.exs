defmodule Tackle.Lib.Tool.SchemaTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Tool.Schema
  alias Tackle.Lib.Tool.Schema.JsonSchema

  doctest Schema

  describe "empty strings" do
    test "are values of string fields, required or with a default" do
      schema = [content: [type: :string, required: true], note: [type: :string, default: "n/a"]]

      assert {:ok, %{"content" => "", "note" => ""}} =
               Schema.validate(schema, %{"content" => "", "note" => ""})
    end

    test "are checked against a string field's enum" do
      assert {:error, [%{field: "mode", message: "must be one of fast, slow"}]} =
               Schema.validate([mode: [type: :string, enum: ["fast", "slow"]]], %{"mode" => ""})
    end

    test "count as absent for every other type" do
      schema = [
        limit: [type: :integer, default: 10],
        ratio: [type: :float],
        exact: [type: :boolean],
        options: [type: :map],
        tags: [type: {:list, :string}],
        count: [type: :integer, required: true]
      ]

      args = %{
        "limit" => "",
        "ratio" => "",
        "exact" => "",
        "options" => "",
        "tags" => "",
        "count" => ""
      }

      assert {:error, [%{field: "count", message: "is required"}]} = Schema.validate(schema, args)

      assert {:ok, %{"limit" => 10} = normalized} =
               Schema.validate(schema, Map.put(args, "count", 1))

      assert Map.keys(normalized) == ["count", "limit"]
    end
  end

  describe "string coercion" do
    test "turns numbers and booleans into strings" do
      schema = [a: [type: :string], b: [type: :string], c: [type: :string]]

      assert {:ok, %{"a" => "12", "b" => "1.5", "c" => "true"}} =
               Schema.validate(schema, %{"a" => 12, "b" => 1.5, "c" => true})
    end

    test "rejects lists and maps instead of converting or raising" do
      schema = [command: [type: :string, required: true]]

      for value <- [["ls", " -la"], ~c"ls", %{"cmd" => "ls"}, [1, 2], {:tuple}] do
        assert {:error, [%{field: "command", message: "must be a string"}]} =
                 Schema.validate(schema, %{"command" => value}),
               inspect(value)
      end
    end

    test "rejects non-string list items" do
      assert {:error, [%{field: "tags", message: "list item must be a string"}]} =
               Schema.validate([tags: [type: {:list, :string}]], %{"tags" => ["a", %{}]})
    end
  end

  test "float fields always return floats" do
    schema = [ratio: [type: :float], scores: [type: {:list, :float}]]

    assert {:ok, %{"ratio" => 1.0, "scores" => [2.0, 0.5, 3.0]}} =
             Schema.validate(schema, %{"ratio" => 1, "scores" => [2, 0.5, "3"]})

    assert {:ok, %{"ratio" => ratio}} = Schema.validate(schema, %{"ratio" => 1})
    assert is_float(ratio)
  end

  describe "map fields" do
    test "decode JSON object strings, including list items" do
      schema = [options: [type: :map], edits: [type: {:list, :map}]]

      assert {:ok,
              %{
                "options" => %{"a" => 1},
                "edits" => [%{"oldText" => "a"}, %{"newText" => "b"}]
              }} =
               Schema.validate(schema, %{
                 "options" => ~s({"a": 1}),
                 "edits" => [~s({"oldText": "a"}), %{"newText" => "b"}]
               })
    end

    test "reject strings that are not a JSON object" do
      for value <- ["not json", "[1]", "42"] do
        assert {:error, [%{field: "options", message: "must be an object"}]} =
                 Schema.validate([options: [type: :map]], %{"options" => value})
      end

      assert {:error, [%{field: "edits", message: "list item must be an object"}]} =
               Schema.validate([edits: [type: {:list, :map}]], %{"edits" => ["[]"]})
    end
  end

  describe "validate/2 on values that are not maps" do
    test "treats nil as no arguments" do
      assert {:ok, %{"limit" => 10}} =
               Schema.validate([limit: [type: :integer, default: 10]], nil)
    end

    test "returns an error instead of raising" do
      for value <- ["text", [1], 42] do
        assert {:error, [%{field: nil, message: "must be an object"}]} =
                 Schema.validate([limit: [type: :integer]], value)
      end
    end
  end

  describe "validate_output/2 with a keyword schema" do
    test "reports outputs that are not maps, nil included, as invalid output" do
      schema = [ok: [type: :boolean]]

      for output <- ["done", [1, 2], nil, 42] do
        assert {:error, "Invalid tool output: must be an object"} =
                 Schema.validate_output(schema, output),
               inspect(output)
      end
    end

    test "still validates map outputs" do
      assert {:ok, %{"ok" => true}} =
               Schema.validate_output([ok: [type: :boolean, required: true]], %{ok: true})

      assert {:error, "Invalid tool output: ok: is required"} =
               Schema.validate_output([ok: [type: :boolean, required: true]], %{})
    end
  end

  describe "validate_schema/1" do
    test "accepts every known type and option" do
      schema = [
        a: [type: :string, required: true, description: "A", enum: ["x", nil], nullable: true],
        b: [type: :integer, default: 1],
        c: [type: :float],
        d: [type: :boolean, required: false, nullable: false],
        e: [type: :map, description: nil],
        f: [type: {:list, {:list, :map}}],
        g: []
      ]

      assert Schema.validate_schema(schema) == :ok
      assert Schema.validate_schema([]) == :ok
    end

    test "rejects unknown types, including nested and the removed {:array, type}" do
      for type <- [:text, :number, :object, {:list, :text}, {:array, :string}, {:map, :string}] do
        assert {:error, message} = Schema.validate_schema(field: [type: type])
        assert message =~ "field :field has unknown type #{inspect(type)}"
      end
    end

    test "rejects unknown options and malformed option values" do
      for {opts, message} <- [
            {[type: :string, min_length: 1], "field :f has unknown options [:min_length]"},
            {[required: "yes"], "field :f option :required must be a boolean"},
            {[nullable: 1], "field :f option :nullable must be a boolean"},
            {[description: :text], "field :f option :description must be a string"},
            {[enum: "a,b"], "field :f option :enum must be a list"}
          ] do
        assert {:error, error} = Schema.validate_schema(f: opts)
        assert error =~ message
      end
    end

    test "rejects malformed schemas and fields" do
      assert {:error, "schema must be a keyword list of fields" <> _} =
               Schema.validate_schema(%{f: [type: :string]})

      assert {:error, "fields must be {atom_name, keyword_options} pairs" <> _} =
               Schema.validate_schema([{"f", [type: :string]}])

      assert {:error, "field :f options must be a keyword list"} =
               Schema.validate_schema(f: [:string])

      assert {:error, "field :f is declared more than once"} =
               Schema.validate_schema(f: [type: :string], f: [type: :integer])
    end
  end

  test "the JSON Schema projection raises on an unknown type instead of advertising a string" do
    assert_raise ArgumentError, "unknown tool schema type: :text", fn ->
      JsonSchema.to_json_schema(f: [type: :text])
    end

    assert %{"properties" => %{"f" => %{"type" => "array", "items" => %{"type" => "number"}}}} =
             JsonSchema.to_json_schema(f: [type: {:list, :float}])
  end
end
