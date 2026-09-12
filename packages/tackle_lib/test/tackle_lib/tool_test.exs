defmodule Tackle.Lib.ToolTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.JSON
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Schema
  alias Tackle.Lib.Tool.Schema.JsonSchema

  defmodule EchoTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "echo"

    @impl true
    def description, do: "Echoes normalized args."

    @impl true
    def parameters_schema do
      [
        query: [type: :string, required: true, description: "Search query"],
        limit: [type: :integer, default: 10],
        tags: [type: {:list, :string}],
        exact: [type: :boolean]
      ]
    end

    @impl true
    def output_schema do
      [
        query: [type: :string, required: true],
        limit: [type: :integer]
      ]
    end

    @impl true
    def execute(args, _context), do: {:ok, args}
  end

  defmodule InvalidOutputTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "invalid_output"

    @impl true
    def description, do: "Returns invalid output."

    @impl true
    def parameters_schema, do: []

    @impl true
    def output_schema, do: [ok: [type: :boolean, required: true]]

    @impl true
    def execute(_args, _context), do: {:ok, %{ok: "not boolean"}}
  end

  defmodule DSLSearchTool do
    use Tackle.Lib.Tool

    tool_name("search")

    description("""
    Search indexed documents.
    """)

    input do
      field(:query, :string, required: true, description: "Search query")
      field(:limit, :integer, default: 10)
    end

    output do
      field(:results, {:list, :map}, required: true)
    end

    def run(%{"query" => query, "limit" => limit}, %{prefix: prefix}) do
      {:ok, %{"results" => [%{"title" => "#{prefix}: #{query}", "limit" => limit}]}}
    end
  end

  defmodule DSLNoOutputTool do
    use Tackle.Lib.Tool

    tool_name("no_output_schema")
    description("Returns any output without validation.")

    input do
      field(:value, :string, required: true)
    end

    def run(args, _context), do: {:ok, args}
  end

  defmodule HostDelegationTool do
    use Tackle.Lib.Tool

    tool_name("delegate_work")
    description("Starts a host-owned child session with narrowed configuration.")

    input do
      field(:request, :string, required: true)
      field(:model, :string, required: true, enum: ["approved/model"])
      field(:max_iterations, :integer, required: true, enum: [1, 2, 3])
      field(:tools, {:list, :string}, required: true)
    end

    output do
      field(:session_id, :string, required: true)
      field(:status, :string, required: true, enum: ["queued"])
    end

    def run(args, %{allowed_tools: allowed_tools}) do
      requested_tools = MapSet.new(args["tools"])

      if MapSet.subset?(requested_tools, allowed_tools) do
        {:ok, %{"session_id" => "child-session", "status" => "queued"}}
      else
        {:error, :tool_policy_broadened}
      end
    end
  end

  defmodule ContentTool do
    use Tackle.Lib.Tool

    tool_name("view")
    description("Returns text plus an image content part.")

    input do
      field(:media_type, :string, required: true)
    end

    def run(%{"media_type" => media_type}, _context) do
      {:ok,
       Tackle.Lib.Tool.Content.new(
         "Read image chart.png (#{media_type}).",
         [Tackle.Lib.Tool.Content.image(media_type, "aGVsbG8=")]
       )}
    end
  end

  defmodule InvalidContentTool do
    use Tackle.Lib.Tool

    tool_name("invalid_content")
    description("Returns an unsupported content part.")

    input do
      field(:value, :string, required: true)
    end

    def run(_args, _context) do
      {:ok, Tackle.Lib.Tool.Content.new("nope", [%{"type" => "video"}])}
    end
  end

  describe "Schema.validate/2" do
    test "coerces known args, applies defaults, and drops unknown args" do
      assert {:ok,
              %{
                "query" => "videos",
                "limit" => 20,
                "tags" => ["a", "b"],
                "exact" => true
              }} =
               Schema.validate(EchoTool.parameters_schema(), %{
                 "query" => "videos",
                 "limit" => "20",
                 "tags" => ["a", "b"],
                 "exact" => "true",
                 "ignored" => "value"
               })
    end

    test "returns structured errors for missing required and invalid values" do
      assert {:error, errors} =
               Schema.validate(EchoTool.parameters_schema(), %{"limit" => "many"})

      assert %{field: "query", message: "is required"} in errors
      assert %{field: "limit", message: "must be an integer"} in errors
    end
  end

  test "definition/1 exposes provider-neutral tool metadata" do
    assert %{
             name: "echo",
             description: "Echoes normalized args.",
             input_schema: [%{name: "query", type: "string", required: true} | _]
           } = Tool.definition(EchoTool)
  end

  test "use Tackle.Lib.Tool defines the canonical callback API" do
    assert DSLSearchTool.name() == "search"
    assert DSLSearchTool.description() == "Search indexed documents."

    assert DSLSearchTool.parameters_schema() == [
             query: [type: :string, required: true, description: "Search query"],
             limit: [type: :integer, default: 10]
           ]

    assert DSLSearchTool.output_schema() == [results: [type: {:list, :map}, required: true]]

    assert {:ok, result} =
             DSLSearchTool.execute(%{"query" => "videos", "limit" => 3}, %{prefix: "Found"})

    assert result == %{"results" => [%{"title" => "Found: videos", "limit" => 3}]}
  end

  test "existing tool schemas validate portable host delegation input and output" do
    assert {:ok, normalized} =
             Tool.validate_args(HostDelegationTool, %{
               "request" => "Summarize the source material",
               "model" => "approved/model",
               "max_iterations" => "2",
               "tools" => ["search"],
               "ignored_broadening" => true
             })

    refute Map.has_key?(normalized, "ignored_broadening")

    assert {:ok, result} =
             HostDelegationTool.execute(normalized, %{
               allowed_tools: MapSet.new(["search", "fetch"])
             })

    assert {:ok, %{"session_id" => "child-session", "status" => "queued"}} =
             Schema.validate_output(HostDelegationTool.output_schema(), result)

    assert {:error, _errors} =
             Schema.validate(HostDelegationTool.parameters_schema(), %{
               "request" => "Do work",
               "model" => "unapproved/model",
               "max_iterations" => 99,
               "tools" => ["search"]
             })

    assert {:error, _reason} =
             Schema.validate_output(HostDelegationTool.output_schema(), %{
               "session_id" => "child-session",
               "status" => "complete",
               "transcript" => "must not escape"
             })

    assert {:error, :tool_policy_broadened} =
             HostDelegationTool.execute(
               %{normalized | "tools" => ["admin_only"]},
               %{allowed_tools: MapSet.new(["search"])}
             )
  end

  test "use Tackle.Lib.Tool defaults output_schema/0 to nil when no output block is declared" do
    assert DSLNoOutputTool.output_schema() == nil
    assert {:ok, %{"value" => "hello"}} = DSLNoOutputTool.execute(%{"value" => "hello"}, %{})
  end

  test "use Tackle.Lib.Tool requires run/2 at compile time" do
    assert_raise ArgumentError, ~r/must define run\/2/, fn ->
      Code.compile_string("""
      defmodule Tackle.Lib.ToolTest.MissingRunTool do
        use Tackle.Lib.Tool

        tool_name "missing_run"
        description "Missing run callback."
      end
      """)
    end
  end

  test "field/3 must be declared inside an input or output block" do
    assert_raise ArgumentError, ~r/field\/3 must be called inside an input or output block/, fn ->
      Code.compile_string("""
      defmodule Tackle.Lib.ToolTest.StrayFieldTool do
        use Tackle.Lib.Tool

        tool_name "stray_field"
        description "Declares a field outside a schema block."
        field :query, :string

        def run(args, _context), do: {:ok, args}
      end
      """)
    end
  end

  test "DSL tools are accepted by the registry" do
    registry = Tackle.Lib.Tool.Registry.new([DSLSearchTool])

    assert [%{name: "search", output_schema: [results: [type: {:list, :map}, required: true]]}] =
             Tackle.Lib.Tool.Registry.definitions(registry)
  end

  test "settle/3 projects tool content into text plus content parts" do
    call = %Tackle.Lib.Tool.Call{
      id: "call_content",
      name: "view",
      arguments: %{"media_type" => "image/png"}
    }

    assert {:ok, %Tackle.Lib.Tool.Result{} = result} = Tool.settle(ContentTool, call, %{})
    assert result.content == "Read image chart.png (image/png)."

    assert result.parts == [
             %{"type" => "image", "media_type" => "image/png", "data" => "aGVsbG8="}
           ]

    assert result.raw == result.output
  end

  test "settle/3 returns an output error for unsupported content parts" do
    call = %Tackle.Lib.Tool.Call{
      id: "call_bad",
      name: "invalid_content",
      arguments: %{"value" => "x"}
    }

    assert {:error, %Tackle.Lib.Tool.Error{} = error} = Tool.settle(InvalidContentTool, call, %{})
    assert error.reason == :invalid_output
    assert error.message =~ "unsupported type \"video\""
  end

  test "settle/3 keeps text-only results free of content parts" do
    call = %Tackle.Lib.Tool.Call{id: "call_plain", name: "echo", arguments: %{"query" => "hi"}}

    assert {:ok, %Tackle.Lib.Tool.Result{} = result} = Tool.settle(EchoTool, call, %{})
    assert result.parts == []
  end

  test "settle/3 returns structured successful results" do
    call = %Tackle.Lib.Tool.Call{
      id: "call_1",
      name: "echo",
      arguments: %{"query" => "hi", "limit" => "3"}
    }

    assert {:ok, %Tackle.Lib.Tool.Result{} = result} = Tool.settle(EchoTool, call, %{})
    assert result.tool_call_id == "call_1"
    assert result.output == %{"limit" => 3, "query" => "hi"}
    assert {:ok, %{"limit" => 3, "query" => "hi"}} = JSON.decode(result.content)
  end

  test "settle/3 returns structured output validation errors" do
    call = %Tackle.Lib.Tool.Call{id: "call_2", name: "invalid_output", arguments: %{}}

    assert {:error, %Tackle.Lib.Tool.Error{} = error} = Tool.settle(InvalidOutputTool, call, %{})
    assert error.reason == :invalid_output
    assert error.message =~ "Invalid tool output"
    assert error.content == "Error: The tool failed while completing the request."
  end

  test "execute_tool_call/3 validates before executing" do
    assert {:ok, encoded} =
             Tool.execute_tool_call(EchoTool, %{"query" => "hi", "limit" => "3"}, %{})

    assert {:ok, %{"limit" => 3, "query" => "hi"}} = JSON.decode(encoded)

    assert {:error, error} = Tool.execute_tool_call(EchoTool, %{"limit" => "nope"}, %{})
    assert error == "Error: The tool received invalid input and could not run."
    refute error =~ "query: is required"
    refute error =~ "limit: must be an integer"
  end

  test "registry assigns stable definition ids and rejects stale calls" do
    registry = Tackle.Lib.Tool.Registry.new([EchoTool])
    [definition] = Tackle.Lib.Tool.Registry.definitions(registry)

    assert %{definition_id: definition_id, name: "echo"} = definition

    fresh_call = %Tackle.Lib.Tool.Call{name: "echo", definition_id: definition_id}
    stale_call = %Tackle.Lib.Tool.Call{name: "echo", definition_id: "old"}

    assert {:ok, %{module: EchoTool}} = Tackle.Lib.Tool.Registry.resolve(registry, fresh_call)

    assert {:error, :stale_tool_definition} =
             Tackle.Lib.Tool.Registry.resolve(registry, stale_call)
  end

  test "JsonSchema.to_json_schema/1 projects schema for provider adapters" do
    assert %{
             "type" => "object",
             "required" => ["query"],
             "properties" => %{
               "query" => %{"type" => "string", "description" => "Search query"},
               "limit" => %{"type" => "integer", "default" => 10},
               "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
             }
           } = JsonSchema.to_json_schema(EchoTool.parameters_schema())
  end

  test "JsonSchema validates output with JSV" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "status" => %{"const" => "complete"},
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{
            "type" => "object",
            "properties" => %{"score" => %{"type" => "number", "minimum" => 0}},
            "required" => ["score"]
          }
        }
      },
      "required" => ["status", "items"],
      "additionalProperties" => false
    }

    output = %{"status" => "complete", "items" => [%{"score" => 0.5}]}
    atom_keyed_output = %{status: "complete", items: [%{score: 0.5}]}

    assert {:ok, ^output} = JsonSchema.validate_output(schema, output)
    assert {:ok, ^atom_keyed_output} = JsonSchema.validate_output(schema, atom_keyed_output)

    assert {:error, error} =
             JsonSchema.validate_output(schema, %{
               "status" => "pending",
               "items" => [%{"score" => -1}],
               "extra" => true
             })

    assert error =~ "Invalid tool output"
    assert error =~ "complete"
    assert error =~ "minimum"
    assert error =~ "additional properties"
  end

  test "JsonSchema returns an error for an invalid schema" do
    assert {:error, error} =
             JsonSchema.validate_output(%{"type" => "not-a-json-schema-type"}, "value")

    assert error =~ "Invalid output schema"
  end
end
