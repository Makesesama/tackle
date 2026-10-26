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

defmodule Tackle.Lib.Bench.UnvalidatedTool do
  use Tackle.Lib.Tool

  tool_name("unvalidated_echo")
  description("Synthetic benchmark echo without an output schema")

  input do
    field(:items, {:list, :map}, required: true)
  end

  def run(args, _context), do: {:ok, args}
end

alias Tackle.Lib.Bench.{KeywordTool, UnvalidatedTool}
alias Tackle.Lib.Tool
alias Tackle.Lib.Tool.{Call, Result}

inputs =
  Map.new([1, 10, 100], fn count ->
    args = %{"items" => for(i <- 1..count, do: %{"name" => "item-#{i}", "value" => i})}

    {"#{count} items",
     %{
       args: args,
       keyword_call: %Call{id: "bench", name: KeywordTool.name(), arguments: args},
       unvalidated_call: %Call{id: "bench", name: UnvalidatedTool.name(), arguments: args}
     }}
  end)

Enum.each(inputs, fn {_name, input} ->
  Enum.each(
    [{KeywordTool, input.keyword_call}, {UnvalidatedTool, input.unvalidated_call}],
    fn {tool, call} ->
      {:ok, %Result{content: content}} = Tool.settle(tool, call, %{})
      true = JSON.decode!(content) == input.args
    end
  )
end)

Tackle.Bench.run(
  %{
    "settlement / keyword output" => &Tool.settle(KeywordTool, &1.keyword_call, %{}),
    "settlement / no output schema" => &Tool.settle(UnvalidatedTool, &1.unvalidated_call, %{})
  },
  inputs: inputs
)
