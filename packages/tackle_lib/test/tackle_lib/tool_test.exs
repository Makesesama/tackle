defmodule Tackle.Lib.ToolTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.JSON
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Content
  alias Tackle.Lib.Tool.Schema
  alias Tackle.Lib.Tool.Schema.JsonSchema

  doctest Tool

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

  defmodule DuplicateEchoTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "echo"

    @impl true
    def description, do: "Different tool with the same public name."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, _context), do: {:ok, "different"}
  end

  defmodule EmptyNameTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: ""

    @impl true
    def description, do: "Invalid name."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, _context), do: {:ok, "no name"}
  end

  defmodule MissingCallbacksTool do
    def name, do: "incomplete"
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

  defmodule FailingTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "failing"

    @impl true
    def description, do: "Returns an expected failure."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, _context), do: {:error, "dependency compilation failed around :idna"}
  end

  defmodule OpaqueFailureTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "opaque_failure"

    @impl true
    def description, do: "Returns an internal failure term."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, _context), do: {:error, {:credentials, "secret-token"}}
  end

  defmodule MisbehavingTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "misbehaving"

    @impl true
    def description, do: "Fails in the way named by the test process."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, %{how: :exit}), do: exit(:timeout)
    def execute(_args, %{how: :throw}), do: throw(:oops)
    def execute(_args, %{how: :tuple}), do: {:ok, %{pair: {1, 2}}}
    def execute(_args, %{how: :invalid_utf8}), do: {:ok, %{text: <<255>>}}
  end

  defmodule InvalidUtf8Tool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "invalid_utf8"

    @impl true
    def description, do: "Returns model-facing text with invalid UTF-8."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, %{how: :text}), do: {:ok, "bytes: " <> <<255, 254>>}

    def execute(_args, %{how: :content}),
      do:
        {:ok,
         Content.new("text " <> <<255>>, [%{"type" => "text", "text" => "part " <> <<200>>}])}

    def execute(_args, %{how: :error}), do: {:error, "failed on " <> <<255>>}
  end

  defmodule StrictOutputTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "strict_output"

    @impl true
    def description, do: "Returns what the test asks for under a keyword output schema."

    @impl true
    def parameters_schema, do: []

    @impl true
    def output_schema, do: [ok: [type: :boolean]]

    @impl true
    def execute(_args, %{result: result}), do: {:ok, result}
  end

  defmodule CountingTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "counting"

    @impl true
    def description, do: "Reports that it ran."

    @impl true
    def parameters_schema,
      do: [path: [type: :string, required: true], edits: [type: {:list, :map}]]

    @impl true
    def execute(args, %{test_pid: test_pid}) do
      send(test_pid, {:executed, args})
      {:ok, "ran"}
    end
  end

  defmodule UnknownTypeTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "unknown_type"

    @impl true
    def description, do: "Declares a field of an unknown type."

    @impl true
    def parameters_schema, do: [path: [type: :text]]

    @impl true
    def execute(_args, _context), do: {:ok, "never"}
  end

  defmodule UnknownOutputOptionTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "unknown_output_option"

    @impl true
    def description, do: "Declares an output field with an unknown option."

    @impl true
    def parameters_schema, do: []

    @impl true
    def output_schema, do: [ok: [type: :boolean, min: 1]]

    @impl true
    def execute(_args, _context), do: {:ok, %{ok: true}}
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
       Content.new(
         "Read image chart.png (#{media_type}).",
         [Content.image(media_type, "aGVsbG8=")]
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
      {:ok, Content.new("nope", [%{"type" => "video"}])}
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

  defmodule ReadOnlyEffectTool do
    use Tackle.Lib.Tool

    tool_name("peek")
    description("Reads without changing anything.")

    @impl true
    def effect, do: :read_only

    def run(_args, _context), do: {:ok, %{}}
  end

  test "effect/1 is :external unless a tool declares :read_only" do
    assert Tool.effect(ReadOnlyEffectTool) == :read_only
    assert Tool.effect(EchoTool) == :external
    assert Tool.effect(DSLSearchTool) == :external
  end

  defmodule GoldenTool do
    use Tackle.Lib.Tool

    tool_name("golden")
    description("Exercises every schema feature providers see.")

    input do
      field(:path, :string, required: true, description: "File to change")
      field(:mode, :string, enum: ["append", "replace"], default: "replace")
      field(:limit, :integer, default: 10)
      field(:ratio, :float)
      field(:dry_run, :boolean, default: false)
      field(:note, :string, required: true, nullable: true)
      field(:color, :string, nullable: true, enum: ["red", nil])
      field(:options, :map)
      field(:tags, {:list, :string})
      field(:edits, {:list, :map}, required: true)
      field(:matrix, {:list, {:list, :float}})
    end

    output do
      field(:ok, :boolean, required: true)
    end

    def run(args, _context), do: {:ok, args}
  end

  # The one place the provider-facing JSON Schema is pinned: adapters send a
  # definition's input_schema as it is.
  test "definition/1 carries the JSON Schema of the tool's parameters" do
    assert Tool.definition(GoldenTool) == %{
             name: "golden",
             description: "Exercises every schema feature providers see.",
             input_schema: %{
               "type" => "object",
               "properties" => %{
                 "path" => %{"type" => "string", "description" => "File to change"},
                 "mode" => %{
                   "type" => "string",
                   "enum" => ["append", "replace"],
                   "default" => "replace"
                 },
                 "limit" => %{"type" => "integer", "default" => 10},
                 "ratio" => %{"type" => "number"},
                 "dry_run" => %{"type" => "boolean", "default" => false},
                 "note" => %{"type" => ["string", "null"]},
                 "color" => %{"type" => ["string", "null"], "enum" => ["red", nil]},
                 "options" => %{"type" => "object"},
                 "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
                 "edits" => %{"type" => "array", "items" => %{"type" => "object"}},
                 "matrix" => %{
                   "type" => "array",
                   "items" => %{"type" => "array", "items" => %{"type" => "number"}}
                 }
               },
               "required" => ["path", "note", "edits"]
             },
             output_schema: [ok: [type: :boolean, required: true]]
           }

    assert {:ok, _json} = JSON.encode(Tool.definition(GoldenTool).input_schema)
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

  test "settle/3 shows a tool's binary error message to the model" do
    call = %Tackle.Lib.Tool.Call{id: "call_failure", name: "failing", arguments: %{}}

    assert {:error, %Tackle.Lib.Tool.Error{} = error} = Tool.settle(FailingTool, call, %{})
    assert error.reason == :execution_error
    assert error.message == "dependency compilation failed around :idna"
    assert error.content == "Error: dependency compilation failed around :idna"
  end

  test "settle/3 hides non-binary error reasons from the model" do
    call = %Tackle.Lib.Tool.Call{id: "call_opaque", name: "opaque_failure", arguments: %{}}

    assert {:error, %Tackle.Lib.Tool.Error{} = error} =
             Tool.settle(OpaqueFailureTool, call, %{})

    assert error.reason == :execution_error
    assert error.message =~ "credentials"
    assert error.content == "Error: The tool failed while completing the request."
    refute error.content =~ "secret-token"
  end

  test "settle/3 turns tool exits and throws into execution errors" do
    call = %Tackle.Lib.Tool.Call{id: "call_bad", name: "misbehaving", arguments: %{}}

    for how <- [:exit, :throw] do
      assert {:error, %Tackle.Lib.Tool.Error{} = error} =
               Tool.settle(MisbehavingTool, call, %{how: how})

      assert error.reason == :execution_error
      assert error.content == "Error: The tool failed while completing the request."
    end
  end

  test "settle/3 reports results that cannot be encoded as invalid output" do
    call = %Tackle.Lib.Tool.Call{id: "call_bad", name: "misbehaving", arguments: %{}}

    for how <- [:tuple, :invalid_utf8] do
      assert {:error, %Tackle.Lib.Tool.Error{} = error} =
               Tool.settle(MisbehavingTool, call, %{how: how})

      assert error.reason == :invalid_output
      assert error.message =~ "could not be encoded as JSON"
    end
  end

  describe "settle/3 errors the model sees" do
    test "show argument validation errors, naming only fields and limits" do
      call = %Tackle.Lib.Tool.Call{id: "c", name: "counting", arguments: %{"edits" => "nope"}}

      assert {:error, %Tackle.Lib.Tool.Error{} = error} =
               Tool.settle(CountingTool, call, %{test_pid: self()})

      assert error.reason == :invalid_input
      assert error.message == "Invalid tool arguments: path: is required; edits: must be an array"
      assert error.content == "Error: " <> error.message
      refute_received {:executed, _args}
    end

    test "settle calls whose provider arguments were unusable without running the tool" do
      for {arguments, text} <- [
            {"{", "arguments are not valid JSON"},
            {"[1]", "arguments must be a JSON object"}
          ] do
        {:ok, call} =
          Tackle.Lib.Tool.Call.normalize(%{
            "id" => "c",
            "name" => "counting",
            "arguments" => arguments
          })

        assert {:error, %Tackle.Lib.Tool.Error{} = error} =
                 Tool.settle(CountingTool, call, %{test_pid: self()})

        assert error.reason == :invalid_input
        assert error.tool_call_id == "c"
        assert error.content == "Error: Invalid tool arguments: " <> text
      end

      refute_received {:executed, _args}
    end

    test "fall back to the generic text for an empty error message" do
      defmodule EmptyErrorTool do
        @behaviour Tackle.Lib.Tool
        def name, do: "empty_error"
        def description, do: "Fails with an empty message."
        def parameters_schema, do: []
        def execute(_args, _context), do: {:error, ""}
      end

      call = %Tackle.Lib.Tool.Call{id: "c", name: "empty_error", arguments: %{}}

      assert {:error, %Tackle.Lib.Tool.Error{content: content}} =
               Tool.settle(EmptyErrorTool, call, %{})

      assert content == "Error: The tool failed while completing the request."
    end
  end

  test "settle/3 decodes JSON object strings inside list-of-map arguments" do
    call = %Tackle.Lib.Tool.Call{
      id: "c",
      name: "counting",
      arguments: %{"path" => "", "edits" => [~s({"oldText":"a"})]}
    }

    assert {:ok, %Tackle.Lib.Tool.Result{content: "ran"}} =
             Tool.settle(CountingTool, call, %{test_pid: self()})

    assert_received {:executed, %{"path" => "", "edits" => [%{"oldText" => "a"}]}}
  end

  describe "settle/3 with invalid UTF-8" do
    test "replaces invalid bytes in a binary result" do
      call = %Tackle.Lib.Tool.Call{id: "c", name: "invalid_utf8", arguments: %{}}

      assert {:ok, %Tackle.Lib.Tool.Result{} = result} =
               Tool.settle(InvalidUtf8Tool, call, %{how: :text})

      assert result.content == "bytes: \uFFFD\uFFFD"
      assert result.raw == "bytes: " <> <<255, 254>>
      assert {:ok, _json} = JSON.encode(%{"content" => result.content})
    end

    test "replaces invalid bytes in content text and text parts" do
      call = %Tackle.Lib.Tool.Call{id: "c", name: "invalid_utf8", arguments: %{}}

      assert {:ok, %Tackle.Lib.Tool.Result{} = result} =
               Tool.settle(InvalidUtf8Tool, call, %{how: :content})

      assert result.content == "text \uFFFD"
      assert result.parts == [%{"type" => "text", "text" => "part \uFFFD"}]
    end

    test "replaces invalid bytes in a model-facing error message" do
      call = %Tackle.Lib.Tool.Call{id: "c", name: "invalid_utf8", arguments: %{}}

      assert {:error, %Tackle.Lib.Tool.Error{} = error} =
               Tool.settle(InvalidUtf8Tool, call, %{how: :error})

      assert error.content == "Error: failed on \uFFFD"
      assert error.message == "failed on \uFFFD"
      assert error.details == "failed on " <> <<255>>
    end
  end

  test "settle/3 reports a non-map result under a keyword output schema as invalid output" do
    call = %Tackle.Lib.Tool.Call{id: "c", name: "strict_output", arguments: %{}}

    for result <- ["done", [1, 2], nil] do
      assert {:error, %Tackle.Lib.Tool.Error{} = error} =
               Tool.settle(StrictOutputTool, call, %{result: result})

      assert error.reason == :invalid_output
      assert error.message == "Invalid tool output: must be an object"
      assert error.content == "Error: The tool failed while completing the request."
    end

    assert {:ok, %Tackle.Lib.Tool.Result{output: %{"ok" => true}}} =
             Tool.settle(StrictOutputTool, call, %{result: %{ok: true}})
  end

  defmodule TermOutputValidator do
    def validate_output(_schema, _output), do: {:error, {:mismatch, :ok}}
  end

  defmodule TermValidatedTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "term_validated"

    @impl true
    def description, do: "Has a host output validator that fails with a term."

    @impl true
    def parameters_schema, do: []

    @impl true
    def output_schema, do: {TermOutputValidator, :schema}

    @impl true
    def execute(_args, %{result: result}), do: {:ok, result}
  end

  test "settle/3 reports odd output failures as invalid output without crashing" do
    call = %Tackle.Lib.Tool.Call{id: "c", name: "term_validated", arguments: %{}}

    assert {:error, %Tackle.Lib.Tool.Error{} = error} =
             Tool.settle(TermValidatedTool, call, %{result: %{}})

    assert error.reason == :invalid_output
    assert error.message == "Invalid tool output: {:mismatch, :ok}"
    assert error.details == {:mismatch, :ok}

    content = %Content{text: nil, parts: []}

    assert {:error, %Tackle.Lib.Tool.Error{reason: :invalid_output, message: message}} =
             Tool.settle(StrictOutputTool, call, %{result: content})

    assert message =~ "Tool content text must be a string"
  end

  test "use Tackle.Lib.Tool rejects unknown schema types and options at compile time" do
    assert_raise ArgumentError,
                 ~r/UnknownTypeDSLTool has an invalid input schema: field :path has unknown type :text/,
                 fn ->
                   Code.compile_string("""
                   defmodule Tackle.Lib.ToolTest.UnknownTypeDSLTool do
                     use Tackle.Lib.Tool

                     tool_name "unknown_type_dsl"
                     description "Declares an unknown type."

                     input do
                       field :path, :text
                     end

                     def run(args, _context), do: {:ok, args}
                   end
                   """)
                 end

    assert_raise ArgumentError,
                 ~r/UnknownOptionDSLTool has an invalid output schema: field :ok has unknown options \[:min\]/,
                 fn ->
                   Code.compile_string("""
                   defmodule Tackle.Lib.ToolTest.UnknownOptionDSLTool do
                     use Tackle.Lib.Tool

                     tool_name "unknown_option_dsl"
                     description "Declares an unknown option."

                     output do
                       field :ok, :boolean, min: 1
                     end

                     def run(_args, _context), do: {:ok, %{ok: true}}
                   end
                   """)
                 end
  end

  test "registry rejects behaviour tools with invalid parameter or output schemas" do
    assert_raise ArgumentError,
                 ~r/UnknownTypeTool has an invalid parameters schema: field :path has unknown type :text/,
                 fn -> Tackle.Lib.Tool.Registry.new([UnknownTypeTool]) end

    assert_raise ArgumentError,
                 ~r/UnknownOutputOptionTool has an invalid output schema: field :ok has unknown options \[:min\]/,
                 fn -> Tackle.Lib.Tool.Registry.new([UnknownOutputOptionTool]) end
  end

  test "settle/3 validates before executing" do
    call = %Tackle.Lib.Tool.Call{
      id: "call_echo",
      name: "echo",
      arguments: %{"query" => "hi", "limit" => "3"}
    }

    assert {:ok, %Tackle.Lib.Tool.Result{content: encoded}} = Tool.settle(EchoTool, call, %{})
    assert {:ok, %{"limit" => 3, "query" => "hi"}} = JSON.decode(encoded)

    invalid = %{call | arguments: %{"limit" => "nope"}}

    assert {:error, %Tackle.Lib.Tool.Error{reason: :invalid_input} = error} =
             Tool.settle(EchoTool, invalid, %{})

    assert error.message ==
             "Invalid tool arguments: query: is required; limit: must be an integer"

    assert error.content ==
             "Error: Invalid tool arguments: query: is required; limit: must be an integer"
  end

  test "registry resolves calls by tool name" do
    registry = Tackle.Lib.Tool.Registry.new([EchoTool])

    assert {:ok, %{name: "echo", module: EchoTool}} =
             Tackle.Lib.Tool.Registry.resolve(registry, %Tackle.Lib.Tool.Call{name: "echo"})

    assert {:error, :unknown_tool} =
             Tackle.Lib.Tool.Registry.resolve(registry, %Tackle.Lib.Tool.Call{name: "missing"})
  end

  test "tool?/1 and missing_callbacks/1 tell tool modules from other terms" do
    assert Tool.tool?(EchoTool)
    assert Tool.tool?(DSLSearchTool)
    assert Tool.missing_callbacks(EchoTool) == []

    refute Tool.tool?(MissingCallbacksTool)

    assert Tool.missing_callbacks(MissingCallbacksTool) ==
             [description: 0, parameters_schema: 0, execute: 2]

    for not_a_module <- [:missing_tool_module, "not a module", nil, 42] do
      refute Tool.tool?(not_a_module)

      assert Tool.missing_callbacks(not_a_module) ==
               [name: 0, description: 0, parameters_schema: 0, execute: 2]
    end
  end

  test "registry keeps registration order for entries, modules, and definitions" do
    # Names out of alphabetical order and more tools than a small map holds
    # sorted, so neither name nor hash order passes by accident.
    names = for i <- 40..1//-1, do: "tool_#{i}"

    tools =
      for name <- names do
        module = Module.concat(__MODULE__, "Ordered_#{name}")

        Module.create(
          module,
          quote do
            @behaviour Tackle.Lib.Tool
            def name, do: unquote(name)
            def description, do: "Ordered test tool."
            def parameters_schema, do: []
            def execute(_args, _context), do: {:ok, "ok"}
          end,
          Macro.Env.location(__ENV__)
        )

        module
      end

    registry = Tackle.Lib.Tool.Registry.new(tools)

    assert Enum.map(Tackle.Lib.Tool.Registry.definitions(registry), & &1.name) == names
    assert Enum.map(Tackle.Lib.Tool.Registry.entries(registry), & &1.name) == names
    assert Tackle.Lib.Tool.Registry.modules(registry) == tools
    assert %{module: first} = Tackle.Lib.Tool.Registry.lookup(registry, "tool_40")
    assert first == hd(tools)
    assert Tackle.Lib.Tool.Registry.lookup(registry, "missing") == nil
  end

  test "registry rejects invalid modules instead of dropping them" do
    for invalid <- [MissingCallbacksTool, :missing_tool_module, "not a module"] do
      assert_raise ArgumentError, ~r/not a valid Tackle.Lib.Tool; missing callbacks:/, fn ->
        Tackle.Lib.Tool.Registry.new([EchoTool, invalid])
      end
    end
  end

  test "registry rejects invalid tool names" do
    assert_raise ArgumentError, ~r/invalid tool name/, fn ->
      Tackle.Lib.Tool.Registry.new([EmptyNameTool])
    end
  end

  test "registry rejects duplicate names instead of selecting the last implementation" do
    for tools <- [
          [EchoTool, DuplicateEchoTool],
          [DuplicateEchoTool, EchoTool],
          [EchoTool, EchoTool]
        ] do
      assert_raise ArgumentError, ~s(duplicate tool name: "echo"), fn ->
        Tackle.Lib.Tool.Registry.new(tools)
      end
    end
  end

  test "nullable fields preserve explicit nil and project to JSON Schema" do
    schema = [
      color: [type: :string, nullable: true, enum: ["red", nil]],
      note: [type: :string, required: true, nullable: true],
      plain: [type: :string]
    ]

    assert {:ok, %{"color" => nil, "note" => nil}} =
             Schema.validate(schema, %{"color" => nil, "note" => nil, "plain" => nil})

    assert {:error, [%{field: "note", message: "is required"}]} =
             Schema.validate(schema, %{})

    assert {:error, [%{field: "color"}]} =
             Schema.validate([color: [type: :string, nullable: true, enum: ["red"]]], %{
               "color" => nil
             })

    assert %{
             "properties" => %{
               "color" => %{"type" => ["string", "null"], "enum" => ["red", nil]},
               "plain" => %{"type" => "string"}
             }
           } = JsonSchema.to_json_schema(schema)
  end
end
