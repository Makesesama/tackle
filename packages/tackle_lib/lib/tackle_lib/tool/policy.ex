defmodule Tackle.Lib.Tool.Policy do
  @moduledoc """
  How the loop executes a batch of tool calls: sequentially (the default) or
  concurrently when the host opts in. Either way the calls run in the exact
  order the model requested them and their results are committed in that
  order.

  In `:concurrent` mode the loop runs every call in a batch as a supervised task
  and commits the results in the original call order, so the transcript is
  identical to the sequential one. Choosing that mode is a host decision: the
  host owns the `Task.Supervisor` and passes it as the `:tool_supervisor` run
  option. The library default stays sequential so a host never needs a
  supervisor to run a turn.

  The modes differ only in when a batch runs, not in result order. Sequential
  guarantees that requested order equals effect order and needs no supervisor;
  concurrent removes ordering between calls and needs one. Prefer sequential for
  tools with ordered or shared side effects; prefer concurrent for independent
  calls such as reads and per-file edits. See the tool execution modes section
  of the Tackle.Lib README for the full comparison.

  Hosts decide which tools are present by constructing the state with a scoped
  tool list; Tackle.Lib does not force a tool choice, apply allow/deny lists or
  weighting, or let the provider schedule tool calls (see
  `Tackle.Lib.LLM.request_opts/3`).
  """

  @type execution_mode :: :sequential | :concurrent

  @type t :: %__MODULE__{execution_mode: execution_mode()}

  defstruct execution_mode: :sequential

  @doc """
  Returns the default Tackle.Lib tool policy (`:sequential`).
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Returns a policy that executes every tool in a batch concurrently.

  The host must pass a `Task.Supervisor` as the `:tool_supervisor` run option; the
  loop raises otherwise. Results are still committed in the model's call order.
  """
  @spec concurrent() :: t()
  def concurrent, do: %__MODULE__{execution_mode: :concurrent}
end
