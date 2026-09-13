defmodule Tackle.Lib.Event do
  @moduledoc """
  Provider-independent events emitted by the Tackle.Lib harness.

  Provider streaming APIs expose very different event shapes. Tackle.Lib normalizes
  those into this small event algebra so hosts can render, persist, or transport
  agent progress without depending on a provider SDK.

  Events are intentionally plain structs with a `:type` atom and `:data` map.
  This keeps the public API stable while still allowing new event types/data
  fields to be added over time.
  """

  alias Tackle.Lib.Message
  alias Tackle.Lib.Usage

  @type type ::
          :turn_start
          | :turn_end
          | :turn_cancelled
          | :step_start
          | :step_end
          | :message_start
          | :message_delta
          | :message_end
          | :tool_start
          | :tool_execution_end
          | :tool_end
          | :tool_error
          | :subagent_started
          | :subagent_finished
          | :usage
          | :status_change
          | :error
          | :provider_event
          | :compaction_start
          | :compaction_end
          | :compaction_retry
          | :retry_scheduled
          | :retry_start
          | :retry_end

  @type t :: %__MODULE__{
          type: type(),
          id: String.t() | nil,
          parent_id: String.t() | nil,
          data: map(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  defstruct [:type, :id, :parent_id, data: %{}, timestamp: nil, metadata: %{}]

  @doc """
  Builds a Tackle.Lib event.
  """
  @spec new(type(), map(), keyword()) :: t()
  def new(type, data \\ %{}, opts \\ []) when is_atom(type) and is_map(data) do
    %__MODULE__{
      type: type,
      id: Keyword.get(opts, :id),
      parent_id: Keyword.get(opts, :parent_id),
      data: data,
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Normalizes a provider/adapter stream event into a Tackle.Lib event.

  Adapters should prefer emitting Tackle.Lib-shaped events directly, but this helper
  accepts common provider-ish event maps so `Tackle.Lib.LLM.stream/4` can be the
  normalization boundary.
  """
  @spec normalize(t() | tuple() | map(), keyword()) :: t()
  def normalize(event, opts \\ [])

  def normalize(%__MODULE__{} = event, _opts), do: event

  def normalize({type, data}, opts) when is_atom(type) and is_map(data) do
    normalize(Map.put(data, :type, type), opts)
  end

  def normalize({type, value}, opts) when is_atom(type) do
    normalize(%{type: type, value: value}, opts)
  end

  def normalize(%{} = event, opts) do
    type = event_value(event, [:type, "type"])
    provider = Keyword.get(opts, :provider) || event_value(event, [:provider, "provider"])

    metadata =
      %{}
      |> maybe_put(:provider, provider)
      |> maybe_put(:raw, event_value(event, [:raw, "raw"], event))

    build_normalized(normalize_type(type), event, metadata)
  end

  defp build_normalized(:message_delta, event, metadata) do
    new(
      :message_delta,
      %{delta: event_value(event, [:delta, "delta", :text, "text"], "")},
      metadata: metadata
    )
  end

  defp build_normalized(:reasoning_delta, event, metadata) do
    new(
      :message_delta,
      %{
        delta: event_value(event, [:delta, "delta", :text, "text"], ""),
        field: :reasoning
      },
      metadata: metadata
    )
  end

  defp build_normalized(:tool_input_delta, event, metadata) do
    new(
      :message_delta,
      %{
        delta: event_value(event, [:delta, "delta", :input, "input"], ""),
        field: :tool_input,
        tool_call_id: event_value(event, [:tool_call_id, "tool_call_id"]),
        tool_name: event_value(event, [:tool_name, "tool_name", :name, "name"]),
        tool_calls: event_value(event, [:tool_calls, "tool_calls"])
      },
      metadata: metadata
    )
  end

  defp build_normalized(:usage, event, metadata) do
    new(:usage, %{usage: Usage.normalize(event_value(event, [:usage, "usage"], event))},
      metadata: metadata
    )
  end

  defp build_normalized(:error, event, metadata) do
    new(
      :error,
      %{error: event_value(event, [:error, "error", :message, "message"])},
      metadata: metadata
    )
  end

  defp build_normalized(type, event, metadata) when is_atom(type) do
    data = event |> drop_keys([:type, "type", :raw, "raw"])
    new(type, data, metadata: metadata)
  end

  defp event_value(event, keys, default \\ nil) do
    Enum.find_value(keys, default, fn key -> Map.get(event, key) end)
  end

  @doc """
  Creates a message-start event for an assistant message.

  The event can carry the pre-minted message id and role in the payload for
  incremental persistence hooks. The `id` field mirrors `Message.id`.
  """
  @spec message_start(keyword()) :: t()
  def message_start(opts \\ []) do
    id = Keyword.get(opts, :id)

    role = Keyword.get(opts, :role, :assistant)

    new(:message_start, %{id: id, role: role}, Keyword.delete(opts, :role))
  end

  @doc """
  Creates a message-end event for a settled Tackle.Lib message.
  """
  @spec message_end(Message.t(), keyword()) :: t()
  def message_end(%Message{} = message, opts \\ []) do
    new(
      :message_end,
      %{message: message, role: message.role},
      Keyword.merge([id: message.id], opts)
    )
  end

  @doc """
  Creates a usage event.
  """
  @spec usage(Usage.t() | map() | nil, keyword()) :: t()
  def usage(usage, opts \\ []) do
    new(:usage, %{usage: Usage.normalize(usage)}, opts)
  end

  defp normalize_type(type)
       when type in [
              :text,
              :text_delta,
              :content,
              :content_delta,
              "text",
              "text_delta",
              "content",
              "content_delta"
            ],
       do: :message_delta

  defp normalize_type(type)
       when type in [:reasoning, :reasoning_delta, "reasoning", "reasoning_delta"],
       do: :reasoning_delta

  defp normalize_type(type)
       when type in [
              :tool_input,
              :tool_input_delta,
              :tool_calls,
              "tool_input",
              "tool_input_delta",
              "tool_calls"
            ],
       do: :tool_input_delta

  defp normalize_type(type) when type in [:usage, "usage"], do: :usage

  defp normalize_type(type) when type in [:error, :provider_error, "error", "provider_error"],
    do: :error

  defp normalize_type(type) when type in [:message_start, "message_start"], do: :message_start
  defp normalize_type(type) when type in [:message_end, "message_end"], do: :message_end
  defp normalize_type(type) when type in [:step_start, "step_start"], do: :step_start
  defp normalize_type(type) when type in [:step_end, "step_end"], do: :step_end
  defp normalize_type(type) when type in [:tool_start, "tool_start"], do: :tool_start

  defp normalize_type(type) when type in [:tool_execution_end, "tool_execution_end"],
    do: :tool_execution_end

  defp normalize_type(type) when type in [:tool_end, "tool_end"], do: :tool_end
  defp normalize_type(type) when type in [:tool_error, "tool_error"], do: :tool_error
  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(_type), do: :provider_event

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_keys(map, keys) do
    Enum.reduce(keys, map, &Map.delete(&2, &1))
  end
end
