defmodule Tackle.Lib.ContextUsage do
  @moduledoc """
  Provider-neutral context-window pressure derived from model metadata and usage.

  The most recent valid assistant usage is the authoritative checkpoint. Messages
  after that checkpoint are estimated at four UTF-8 characters per token so a
  host can make compaction decisions before another provider response arrives.
  """

  alias Tackle.Lib.Message
  alias Tackle.Lib.ModelInfo
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Registry
  alias Tackle.Lib.Usage

  @chars_per_token 4

  @type t :: %__MODULE__{
          tokens: non_neg_integer(),
          context_window: pos_integer(),
          percent: float(),
          remaining_tokens: non_neg_integer(),
          usage_tokens: non_neg_integer(),
          trailing_tokens: non_neg_integer(),
          estimated?: boolean()
        }

  @enforce_keys [:tokens, :context_window, :percent, :remaining_tokens]
  defstruct [
    :tokens,
    :context_window,
    :percent,
    :remaining_tokens,
    usage_tokens: 0,
    trailing_tokens: 0,
    estimated?: false
  ]

  @doc "Returns context pressure for a state when its selected model declares a window."
  @spec estimate(State.t()) :: t() | nil
  def estimate(%State{llm: %{model_info: %ModelInfo{} = info}} = state), do: estimate(state, info)
  def estimate(%State{}), do: nil

  @doc "Returns context pressure using explicit model metadata."
  @spec estimate(State.t(), ModelInfo.t() | nil) :: t() | nil
  def estimate(%State{}, nil), do: nil

  def estimate(%State{} = state, %ModelInfo{context_window: window})
      when is_integer(window) and window > 0 do
    case latest_usage_checkpoint(state.messages) do
      nil ->
        trailing = estimate_initial_context(state)
        build(trailing, window, 0, trailing, true)

      {index, usage_tokens} ->
        trailing = state.messages |> Enum.drop(index + 1) |> estimate_messages()
        build(usage_tokens + trailing, window, usage_tokens, trailing, trailing > 0)
    end
  end

  def estimate(%State{}, %ModelInfo{}), do: nil

  @doc "Returns context pressure directly from one provider usage checkpoint."
  @spec from_usage(Usage.t() | map() | nil, ModelInfo.t() | nil) :: t() | nil
  def from_usage(usage, %ModelInfo{context_window: window})
      when is_integer(window) and window > 0 do
    case Usage.context_tokens(usage) do
      tokens when is_integer(tokens) and tokens > 0 -> build(tokens, window, tokens, 0, false)
      _unavailable -> nil
    end
  end

  def from_usage(_usage, _info), do: nil

  defp latest_usage_checkpoint(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: :assistant, token_usage: usage}, index} ->
        case Usage.context_tokens(usage) do
          tokens when is_integer(tokens) and tokens > 0 -> {index, tokens}
          _invalid -> nil
        end

      {_message, _index} ->
        nil
    end)
  end

  defp estimate_initial_context(state) do
    tool_definitions = Registry.definitions(state.tool_registry)

    estimate_text(state.system_prompt) + estimate_messages(state.messages) +
      estimate_collection(tool_definitions)
  end

  defp estimate_messages(messages), do: Enum.reduce(messages, 0, &(&2 + estimate_message(&1)))

  defp estimate_message(%Message{} = message) do
    estimate_text(message.content) + estimate_text(message.thinking) +
      estimate_collection(message.tool_calls || [])
  end

  defp estimate_text(nil), do: 0

  defp estimate_text(text) when is_binary(text),
    do: ceil_div(String.length(text), @chars_per_token)

  defp estimate_text(value), do: estimate_term(value)

  defp estimate_collection([]), do: 0
  defp estimate_collection(values), do: estimate_term(values)

  defp estimate_term(value) do
    value
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> estimate_text()
  end

  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp build(tokens, window, usage_tokens, trailing_tokens, estimated?) do
    %__MODULE__{
      tokens: tokens,
      context_window: window,
      percent: tokens / window * 100,
      remaining_tokens: max(window - tokens, 0),
      usage_tokens: usage_tokens,
      trailing_tokens: trailing_tokens,
      estimated?: estimated?
    }
  end
end
