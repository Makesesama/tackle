defmodule Tackle.Lib.Message do
  @moduledoc """
  Message struct for agent conversations.

  Represents messages from users, assistant responses, and tool results. This is
  a pure in-memory value — Tackle.Lib does not persist messages. Host applications
  map this struct to their own storage if they need durability.

  An assistant message's `tool_calls` are always `Tackle.Lib.Tool.Call`
  structs, and every other message has none (`[]`). `assistant/1` normalizes
  the calls it is given, so a host that rebuilds messages from stored data
  passes them through it (or through `Tackle.Lib.Tool.Call.normalize/1`).
  """

  alias Tackle.Lib.ID
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Usage

  @type role :: :user | :assistant | :tool

  @type t :: %__MODULE__{
          id: String.t(),
          role: role(),
          content: String.t() | nil,
          thinking: String.t() | nil,
          tool_calls: [Call.t()],
          tool_call_id: String.t() | nil,
          tool_name: String.t() | nil,
          parts: [map()] | nil,
          timestamp: DateTime.t(),
          token_usage: Usage.t() | nil,
          model: String.t() | nil,
          provider_state: map() | nil
        }

  defstruct id: nil,
            role: nil,
            content: nil,
            thinking: nil,
            tool_calls: [],
            tool_call_id: nil,
            tool_name: nil,
            parts: nil,
            timestamp: nil,
            token_usage: nil,
            model: nil,
            provider_state: nil

  @doc """
  Creates a new user message.

  ## Options
    * `:id_generator` - zero-arity function returning a message id
  """
  @spec user(String.t(), keyword()) :: t()
  def user(content, opts \\ []) when is_binary(content) do
    %__MODULE__{
      id: generate_id(opts),
      role: :user,
      content: content,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Creates a new assistant message with optional tool calls.

  ## Options
    * `:tool_calls` - the calls the assistant made: `Tackle.Lib.Tool.Call`
      structs, or maps that `Tackle.Lib.Tool.Call.normalize/1` accepts
      (default none). A call that does not normalize raises `ArgumentError`.
    * `:id` - explicit message id (overrides :id_generator)
    * `:id_generator` - zero-arity function returning a message id
    * `:provider_state` - opaque, non-secret continuation metadata returned by
      the selected adapter; adapters must ignore state from other providers or
      models
  """
  @spec assistant(keyword()) :: t()
  def assistant(opts) do
    %__MODULE__{
      id: generate_id(opts),
      role: :assistant,
      content: Keyword.get(opts, :content),
      thinking: Keyword.get(opts, :thinking),
      tool_calls: normalize_tool_calls(Keyword.get(opts, :tool_calls)),
      token_usage:
        Usage.normalize(Keyword.get(opts, :token_usage), model: Keyword.get(opts, :model)),
      model: Keyword.get(opts, :model),
      provider_state: Keyword.get(opts, :provider_state),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Creates a new tool result message.

  `parts` carries extra provider-neutral content parts (for example an image the
  tool read). `content` remains the string projection that human-facing surfaces
  and token estimates use; adapters combine both when building the model input.

  ## Options
    * `:parts` - extra content parts (see `Tackle.Lib.Tool.Content`)
    * `:id_generator` - zero-arity function returning a message id
  """
  @spec tool_result(String.t(), String.t(), String.t(), keyword()) :: t()
  def tool_result(tool_call_id, tool_name, content, opts \\ []) do
    %__MODULE__{
      id: generate_id(opts),
      role: :tool,
      content: content,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      parts: normalize_parts(Keyword.get(opts, :parts)),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Checks if this is a final answer message (assistant with content, no tool calls).
  """
  @spec final_answer?(t()) :: boolean()
  def final_answer?(%__MODULE__{role: :assistant, content: content, tool_calls: []}),
    do: content not in [nil, ""]

  def final_answer?(_), do: false

  @doc """
  Checks if this message has tool calls.
  """
  @spec has_tool_calls?(t()) :: boolean()
  def has_tool_calls?(%__MODULE__{tool_calls: [_ | _]}), do: true
  def has_tool_calls?(%__MODULE__{}), do: false

  defp generate_id(opts) do
    case Keyword.get(opts, :id) do
      nil ->
        opts
        |> Keyword.get(:id_generator, &ID.uuid4/0)
        |> then(fn generator -> generator.() end)

      id when is_binary(id) ->
        id
    end
  end

  defp normalize_tool_calls(nil), do: []

  defp normalize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      case Call.normalize(call) do
        {:ok, call} ->
          call

        {:error, reason} ->
          raise ArgumentError, "invalid tool call #{inspect(call)}: #{inspect(reason)}"
      end
    end)
  end

  defp normalize_tool_calls(calls),
    do: raise(ArgumentError, "tool calls must be a list, got: #{inspect(calls)}")

  defp normalize_parts(parts) when is_list(parts) and parts != [], do: parts
  defp normalize_parts(_parts), do: nil
end
