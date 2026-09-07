defmodule Tackle.Tool.Policy do
  @moduledoc """
  Central policy for how Tackle exposes and executes tools.

  Tackle intentionally keeps tool policy small and provider-agnostic:

  * tool calls are executed sequentially, in the exact order requested by the model;
  * Tackle does not force a tool choice;
  * Tackle does not apply allow/disallow lists or weighting;
  * Tackle does not ask providers to run tool calls in parallel.

  Hosts still decide which tools are present by constructing the state with a
  scoped tool list. Once tools are registered for a run, this policy keeps the
  loop deterministic and leaves more advanced scheduling/selection strategies to
  future explicit work.
  """

  @type execution_mode :: :sequential

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
  Returns the default Tackle tool policy.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Drops provider/tool-selection options that Tackle does not support.

  The loop owns the registered tool list and sequential execution order. Host
  `llm_opts` are otherwise pass-through, but these policy-shaped options would
  introduce forced choice, disallow lists, weighting, or provider-side parallel
  tool execution, so Tackle filters them at the boundary.
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
