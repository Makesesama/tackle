defmodule Tackle.Lib.Tool.Policy do
  @moduledoc """
  Central policy for how Tackle.Lib exposes and executes tools.

  Tackle.Lib intentionally keeps tool policy small and provider-agnostic:

  * tool calls execute in the exact order requested by the model, sequentially by
    default or concurrently when the host opts in;
  * Tackle.Lib does not force a tool choice;
  * Tackle.Lib does not apply allow/disallow lists or weighting;
  * Tackle.Lib never asks the provider to run or schedule tool calls.

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

  Hosts still decide which tools are present by constructing the state with a
  scoped tool list. Once tools are registered for a run, this policy keeps the
  loop deterministic and leaves more advanced scheduling/selection strategies to
  future explicit work.
  """

  @type execution_mode :: :sequential | :concurrent

  @type unsupported_llm_opt ::
          :tool_choice
          | :parallel_tool_calls
          | :allowed_tools
          | :disallowed_tools
          | :tool_weights
          | :tool_policy

  @type t :: %__MODULE__{execution_mode: execution_mode()}

  defstruct execution_mode: :sequential

  @unsupported_llm_opts [
    :tool_choice,
    :parallel_tool_calls,
    :allowed_tools,
    :disallowed_tools,
    :tool_weights,
    :tool_policy
  ]

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

  @doc """
  Drops provider/tool-selection options that Tackle.Lib does not support.

  The loop owns the registered tool list and the local execution order. Host
  `llm_opts` are otherwise pass-through, but these policy-shaped options would
  introduce forced choice, disallow lists, weighting, or provider-side parallel
  tool execution, so Tackle.Lib filters them at the boundary. Local concurrent
  execution is a library concern, never a provider option.
  """
  @spec sanitize_llm_opts(keyword()) :: keyword()
  def sanitize_llm_opts(opts) when is_list(opts) do
    Keyword.drop(opts, @unsupported_llm_opts)
  end

  @doc """
  Returns the unsupported LLM option keys filtered by `sanitize_llm_opts/1`.
  """
  @spec unsupported_llm_opts() :: [unsupported_llm_opt(), ...]
  def unsupported_llm_opts, do: @unsupported_llm_opts
end
