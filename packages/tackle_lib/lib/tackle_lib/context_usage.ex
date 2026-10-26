defmodule Tackle.Lib.ContextUsage do
  @moduledoc """
  Provider-neutral context-window pressure derived from model metadata and usage.

  The most recent valid assistant usage is the authoritative checkpoint. Messages
  after that checkpoint are estimated (`estimate_message/1`: four UTF-8
  characters per token, a fixed cost per image) so a host can make compaction
  decisions before another provider response arrives.

  Estimation reads the **model projection** (`Tackle.Lib.State.model_messages/1`),
  not the canonical transcript: after compaction the provider-visible array is
  what consumes the window. Retained copies have their stale usage stripped, so
  the first post-compaction assistant response becomes the next checkpoint.
  """

  alias Tackle.Lib.Message
  alias Tackle.Lib.ModelInfo
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Registry
  alias Tackle.Lib.Usage

  @chars_per_token 4

  # Providers downscale large images (Anthropic to about 1.15 megapixels, about
  # 1,600 tokens; OpenAI to a similar budget), so one image costs at most about
  # this much regardless of its file size.
  @image_tokens 1_600

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
    messages = State.model_messages(state)

    case since_checkpoint(Enum.reverse(messages)) do
      {nil, message_tokens} ->
        trailing = estimate_context(state, message_tokens)
        build(trailing, window, 0, trailing, true)

      {usage_tokens, trailing} ->
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

  @doc """
  Estimates the token cost of a complete projected context.

  Combines optional system text, the model message projection, and provider tool
  definitions. Used to report post-compaction pressure and to size a replacement
  against the whole request, not just the messages.
  """
  @spec estimate_projection(String.t() | nil, [Message.t()], [map()]) :: non_neg_integer()
  def estimate_projection(system, messages, tools) do
    estimate_text(system) + estimate_messages(messages) + estimate_collection(tools)
  end

  @doc "Estimates the token cost of a list of model messages."
  @spec estimate_messages([Message.t()]) :: non_neg_integer()
  def estimate_messages(messages), do: Enum.reduce(messages, 0, &(&2 + estimate_message(&1)))

  @doc """
  Estimates the token cost of a list of tool definitions.

  Kept public for compaction policy and for hosts that report context pressure.
  """
  @spec estimate_tools([map()]) :: non_neg_integer()
  def estimate_tools(tools), do: estimate_collection(tools)

  @doc """
  Splits model messages at their latest usage checkpoint.

  Takes the messages **newest first**, as any enumerable, so a host can decode
  stored messages lazily, and stops at the checkpoint: the newest assistant
  message whose usage reports positive context tokens
  (`Tackle.Lib.Usage.context_tokens/1`). Returns the checkpoint's tokens, or
  `nil` without one, and the estimated tokens of the messages after it (all
  messages without a checkpoint).
  """
  @spec since_checkpoint(Enumerable.t(Message.t())) ::
          {non_neg_integer() | nil, non_neg_integer()}
  def since_checkpoint(newest_first) do
    Enum.reduce_while(newest_first, {nil, 0}, fn message, {nil, trailing} ->
      case checkpoint_tokens(message) do
        nil -> {:cont, {nil, trailing + estimate_message(message)}}
        tokens -> {:halt, {tokens, trailing}}
      end
    end)
  end

  @doc """
  Estimates the token cost of one message.

  Text, reasoning, and tool calls count four characters per token. Content
  parts (`Tackle.Lib.Message.parts`) count too: a text part like text, an
  image #{@image_tokens} tokens, about what providers charge for an image at the
  size they downscale to, and other parts by their inspected size.
  """
  @spec estimate_message(Message.t()) :: non_neg_integer()
  def estimate_message(%Message{} = message) do
    estimate_text(message.content) + estimate_text(message.thinking) +
      estimate_collection(message.tool_calls) + estimate_parts(message.parts)
  end

  @doc "Estimates text tokens at four UTF-8 characters per token."
  @spec estimate_text(String.t() | nil) :: non_neg_integer()
  def estimate_text(nil), do: 0

  def estimate_text(text) when is_binary(text),
    do: ceil_div(String.length(text), @chars_per_token)

  def estimate_text(value), do: estimate_term(value)

  defp checkpoint_tokens(%Message{role: :assistant, token_usage: usage}) do
    case Usage.context_tokens(usage) do
      tokens when is_integer(tokens) and tokens > 0 -> tokens
      _unavailable -> nil
    end
  end

  defp checkpoint_tokens(%Message{}), do: nil

  defp estimate_parts(parts) when is_list(parts),
    do: Enum.reduce(parts, 0, &(&2 + estimate_part(&1)))

  defp estimate_parts(_parts), do: 0

  defp estimate_part(%{"type" => "image"}), do: @image_tokens

  defp estimate_part(%{"type" => "text", "text" => text}) when is_binary(text),
    do: estimate_text(text)

  defp estimate_part(part), do: estimate_term(part)

  defp estimate_context(state, message_tokens) do
    tool_definitions = Registry.definitions(state.tool_registry)

    estimate_text(state.system_prompt) + message_tokens + estimate_collection(tool_definitions)
  end

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
