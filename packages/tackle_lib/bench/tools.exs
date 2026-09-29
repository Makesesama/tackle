Code.require_file("../../../bench/support.exs", __DIR__)

defmodule Tackle.Lib.Bench.KeywordTool do
  use Tackle.Lib.Tool

  tool_name("keyword_echo")
  description("Synthetic benchmark echo")

  input do
    field(:items, {:list, :map}, required: true)
  end

  output do
    field(:items, {:list, :map}, required: true)
  end

  def run(args, _context), do: {:ok, args}
end

defmodule Tackle.Lib.Bench.JsonTool do
  use Tackle.Lib.Tool

  tool_name("json_echo")
  description("Synthetic benchmark echo with nested JSON Schema validation")

  input do
    field(:items, {:list, :map}, required: true)
  end

  def output_schema do
    {Tackle.Lib.Tool.Schema.JsonSchema,
     %{
       "type" => "object",
       "required" => ["items"],
       "properties" => %{
         "items" => %{
           "type" => "array",
           "items" => %{
             "type" => "object",
             "required" => ["name", "value"],
             "properties" => %{
               "name" => %{"type" => "string"},
               "value" => %{"type" => "integer"}
             }
           }
         }
       }
     }}
  end

  def run(args, _context), do: {:ok, args}
end

alias Tackle.Lib.Bench.{JsonTool, KeywordTool}
alias Tackle.Lib.Tool
alias Tackle.Lib.Tool.{Call, Result}
alias Tackle.Lib.Tool.Schema.JsonSchema

{JsonSchema, schema} = JsonTool.output_schema()
{:ok, compiled} = JSV.build(schema, atoms: false, warnings: :silent)

inputs =
  Map.new([1, 10, 100], fn count ->
    args = %{"items" => for(i <- 1..count, do: %{"name" => "item-#{i}", "value" => i})}

    {"#{count} items",
     %{
       args: args,
       schema: schema,
       compiled: compiled,
       keyword_call: %Call{id: "bench", name: KeywordTool.name(), arguments: args},
       json_call: %Call{id: "bench", name: JsonTool.name(), arguments: args}
     }}
  end)

Enum.each(inputs, fn {_name, input} ->
  Enum.each([{KeywordTool, input.keyword_call}, {JsonTool, input.json_call}], fn {tool, call} ->
    {:ok, %Result{content: content}} = Tool.settle(tool, call, %{})
    true = JSON.decode!(content) == input.args
  end)

  {:ok, _} = JSV.validate(input.args, compiled, cast: false)
end)

Tackle.Bench.run(
  %{
    "settlement / keyword output" => &Tool.settle(KeywordTool, &1.keyword_call, %{}),
    "settlement / nested JSON Schema output" => &Tool.settle(JsonTool, &1.json_call, %{}),
    "JSON Schema / build only" => &JSV.build(&1.schema, atoms: false, warnings: :silent),
    "JSON Schema / validate precompiled (lower-level)" =>
      &JSV.validate(&1.args, &1.compiled, cast: false),
    "JSON Schema / library build + validate" => &JsonSchema.validate_output(&1.schema, &1.args)
  },
  inputs: inputs
)
