defmodule Tackle.Lib.Event do
  @moduledoc """
  Provider-independent events emitted by the Tackle.Lib harness.

  Provider streaming APIs expose very different event shapes. Tackle.Lib normalizes
  those into this small event algebra so hosts can render, persist, or transport
  agent progress without depending on a provider SDK.

  Events are intentionally plain structs with a `:type` atom and `:data` map.
  New event types and data fields may be added over time.

  ## Core events

  The library's own events are listed in `t:core_type/0`. Each has one
  constructor below, and so one payload shape: every key of the payload is
  always present, `nil` when it does not apply. Constructors take the value
  the event reports (a `Tackle.Lib.Tool.Call`, `Tackle.Lib.Tool.Result`,
  `Tackle.Lib.Tool.Error`, `Tackle.Lib.Message`, `Tackle.Lib.LLM.Response`,
  or plain values), then the event options of `new/3` (`:id`, `:parent_id`,
  `:timestamp`, `:metadata`). The compaction events, whose payloads are
  long, take their fields as a keyword list.

  | Type | Payload |
  |---|---|
  | `:turn_start` | `session_id` |
  | `:turn_end` | `session_id`, `status` (`:completed`, `:error`, `:cancelled`) |
  | `:turn_cancelled` | `session_id`, `reason` |
  | `:status_change` | `status` |
  | `:step_start` | `iteration` |
  | `:step_end` | `iteration`, `usage`, `model`, `provider` |
  | `:message_start` | `id`, `role` |
  | `:message_delta` | `delta`, and `field` etc. for reasoning and tool input (`normalize/2`) |
  | `:message_end` | `message`, `role` |
  | `:usage` | `usage` |
  | `:tool_start` | `tool_call_id`, `name`, `arguments` |
  | `:tool_progress` | `tool_call_id`, plus the reporting tool's own fields |
  | `:tool_execution_end` | `tool_call_id`, `name`, `status` (`:completed`, `:failed`), `result`, `error`, `reason` |
  | `:tool_end` | `tool_call_id`, `name`, `result`, `raw`, `metadata` |
  | `:tool_error` | `tool_call_id`, `name`, `error`, `reason`, `details`, `metadata` |
  | `:retry_scheduled` | `attempt`, `max_retries`, `delay_ms`, `reason` |
  | `:retry_start` | `attempt` |
  | `:retry_end` | `attempt`, `success?`, `reason` |
  | `:compaction_start` | `compaction_id`, `trigger`, `pass`, `tokens_before` |
  | `:compaction_end` | see `compaction_end/2` |
  | `:compaction_retry` | `trigger`, `reason` |
  | `:error` | `error`, `reason` |

  `:message_start`, `:message_delta`, and the retry events carry the id of the
  assistant message they concern as the event `id`. `:tool_progress` events
  are reported by tools themselves (`Tackle.Lib.Tool.progress/3`), so beyond
  `tool_call_id` their payload is the tool's, and `:provider_event` wraps an adapter
  stream event `normalize/2` does not recognize.

  ## Host events

  Hosts and tools may emit events of their own types, any atom (for example
  the harness's `:subagent_progress` or `:workflow_progress`), with `new/3`.
  The library passes them through unchanged.

  Events whose data carries `auxiliary: true` describe an agent without being
  its progress, for example a `:narration` status line
  (`%{run_id: id, tool_call_id: id | nil, text: text, auxiliary: true}`)
  published by a host service. Hosts must not persist them or count them as
  activity.
  """

  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error, as: ToolError
  alias Tackle.Lib.Tool.Result, as: ToolResult
  alias Tackle.Lib.Usage

  @typedoc "The event types the library itself emits."
  @type core_type ::
          :turn_start
          | :turn_end
          | :turn_cancelled
          | :step_start
          | :step_end
          | :message_start
          | :message_delta
          | :message_end
          | :tool_start
          | :tool_progress
          | :tool_execution_end
          | :tool_end
          | :tool_error
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

  @typedoc "A core event type, or any atom a host uses for its own events."
  @type type :: core_type() | atom()

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
  Whether `event` is auxiliary: its data carries `auxiliary: true`.

  Auxiliary events report on an agent without being its progress, so they are
  neither persisted nor treated as activity (for example, they do not renew a
  delegated run's inactivity timeout).
  """
  @spec auxiliary?(t()) :: boolean()
  def auxiliary?(%__MODULE__{data: %{auxiliary: true}}), do: true
  def auxiliary?(%__MODULE__{}), do: false

  @doc """
  Normalizes a provider/adapter stream event into a Tackle.Lib event.

  Adapters should prefer emitting Tackle.Lib-shaped events directly, but this helper
  accepts common provider-ish event maps so the optional `stream/3` callback in
  `Tackle.Lib.LLM` can produce standard events for hosts at this normalization
  boundary.
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

    case normalize_type(type) do
      :provider_event when not is_nil(type) ->
        # Keep an unrecognized provider type, which `build_normalized/3` would
        # otherwise drop with the other `type` keys.
        build_normalized(:provider_event, Map.put(event, :provider_type, type), metadata)

      normalized ->
        build_normalized(normalized, event, metadata)
    end
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
    usage(event_value(event, [:usage, "usage"], event), metadata: metadata)
  end

  defp build_normalized(:error, event, metadata) do
    error(event_value(event, [:error, "error", :message, "message"]), nil, metadata: metadata)
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

  # ── Turns and steps ───────────────────────────────────────────────────

  @doc "Creates the event that starts a turn of session `session_id`."
  @spec turn_start(String.t(), keyword()) :: t()
  def turn_start(session_id, opts \\ []) do
    new(:turn_start, %{session_id: session_id}, opts)
  end

  @doc """
  Creates the event that ends a turn of session `session_id`, every turn's
  last event. `status` is the turn's outcome.
  """
  @spec turn_end(String.t(), :completed | :error | :cancelled, keyword()) :: t()
  def turn_end(session_id, status, opts \\ []) when status in [:completed, :error, :cancelled] do
    new(:turn_end, %{session_id: session_id, status: status}, opts)
  end

  @doc """
  Creates the event that reports a cancelled turn, before its `turn_end`.
  `reason` is the cancellation reason the state keeps in `:error`.
  """
  @spec turn_cancelled(String.t(), String.t() | nil, keyword()) :: t()
  def turn_cancelled(session_id, reason, opts \\ []) do
    new(:turn_cancelled, %{session_id: session_id, reason: reason}, opts)
  end

  @doc "Creates the event that reports the agent's new `Tackle.Lib.State` status."
  @spec status_change(atom(), keyword()) :: t()
  def status_change(status, opts \\ []) when is_atom(status) do
    new(:status_change, %{status: status}, opts)
  end

  @doc "Creates the event that starts step `iteration` (1 for a turn's first step)."
  @spec step_start(pos_integer(), keyword()) :: t()
  def step_start(iteration, opts \\ []) do
    new(:step_start, %{iteration: iteration}, opts)
  end

  @doc """
  Creates the event that ends step `iteration` with the response the step
  keeps: its usage, model, and provider.
  """
  @spec step_end(pos_integer(), Response.t(), keyword()) :: t()
  def step_end(iteration, %Response{} = response, opts \\ []) do
    new(
      :step_end,
      %{
        iteration: iteration,
        usage: response.usage,
        model: response.model,
        provider: response.provider
      },
      opts
    )
  end

  @doc """
  Creates an error event: `error` is the human-readable message and `reason`
  the structured reason behind it, or `nil` (see `Tackle.Lib.State`).
  """
  @spec error(String.t() | nil, term(), keyword()) :: t()
  def error(error, reason, opts \\ []) do
    new(:error, %{error: error, reason: reason}, opts)
  end

  # ── Tools ─────────────────────────────────────────────────────────────

  @doc "Creates the event that starts tool `call`."
  @spec tool_start(Call.t(), keyword()) :: t()
  def tool_start(%Call{} = call, opts \\ []) do
    new(:tool_start, %{tool_call_id: call.id, name: call.name, arguments: call.arguments}, opts)
  end

  @doc """
  Creates a progress event a tool reports while call `tool_call_id` runs:
  `data`, the tool's own presentation fields, with `:tool_call_id` put in it.
  Tools report progress with `Tackle.Lib.Tool.progress/3`, which builds this
  event.
  """
  @spec tool_progress(String.t() | nil, map(), keyword()) :: t()
  def tool_progress(tool_call_id, data, opts \\ []) when is_map(data) do
    new(:tool_progress, Map.put(data, :tool_call_id, tool_call_id), opts)
  end

  @doc """
  Creates the event that reports a tool call's execution settled, from its
  settlement. It is transient progress, possibly out of call order; the call's
  `tool_end` or `tool_error` follows once its result is recorded. `result` is
  set for a completed call, `error` and `reason` for a failed one.
  """
  @spec tool_execution_end({:ok, ToolResult.t()} | {:error, ToolError.t()}, keyword()) :: t()
  def tool_execution_end(settlement, opts \\ [])

  def tool_execution_end({:ok, %ToolResult{} = result}, opts) do
    new(
      :tool_execution_end,
      %{
        tool_call_id: result.tool_call_id,
        name: result.name,
        status: :completed,
        result: result.content,
        error: nil,
        reason: nil
      },
      opts
    )
  end

  def tool_execution_end({:error, %ToolError{} = error}, opts) do
    new(
      :tool_execution_end,
      %{
        tool_call_id: error.tool_call_id,
        name: tool_name(error),
        status: :failed,
        result: nil,
        error: error.message,
        reason: error.reason
      },
      opts
    )
  end

  @doc "Creates the event that reports a tool call's recorded result."
  @spec tool_end(ToolResult.t(), keyword()) :: t()
  def tool_end(%ToolResult{} = result, opts \\ []) do
    new(
      :tool_end,
      %{
        tool_call_id: result.tool_call_id,
        name: result.name,
        result: result.content,
        raw: result.raw,
        metadata: result.metadata
      },
      opts
    )
  end

  @doc """
  Creates the event that reports a tool call's recorded failure, including a
  call left unresolved when its turn ended (`Tackle.Lib.Tool.Error.interrupted/3`,
  reason `:interrupted`). A call whose tool has no name is reported as
  `"unknown"`.
  """
  @spec tool_error(ToolError.t(), keyword()) :: t()
  def tool_error(%ToolError{} = error, opts \\ []) do
    new(
      :tool_error,
      %{
        tool_call_id: error.tool_call_id,
        name: tool_name(error),
        error: error.message,
        reason: error.reason,
        details: error.details,
        metadata: error.metadata
      },
      opts
    )
  end

  defp tool_name(%ToolError{name: name}) when is_binary(name), do: name
  defp tool_name(%ToolError{}), do: "unknown"

  # ── Retries ───────────────────────────────────────────────────────────

  @doc """
  Creates the event that schedules provider retry `attempt` of at most
  `max_retries`, after `delay_ms`, because of `reason`. Pass the assistant
  message's id as `:id`.
  """
  @spec retry_scheduled(pos_integer(), non_neg_integer(), non_neg_integer(), term(), keyword()) ::
          t()
  def retry_scheduled(attempt, max_retries, delay_ms, reason, opts \\ []) do
    new(
      :retry_scheduled,
      %{attempt: attempt, max_retries: max_retries, delay_ms: delay_ms, reason: reason},
      opts
    )
  end

  @doc "Creates the event that starts provider retry `attempt`. Pass the message id as `:id`."
  @spec retry_start(pos_integer(), keyword()) :: t()
  def retry_start(attempt, opts \\ []) do
    new(:retry_start, %{attempt: attempt}, opts)
  end

  @doc """
  Creates the event that ends a retried request at `attempt`: `success?` with
  a `nil` reason, or the reason it failed. Pass the message id as `:id`.
  """
  @spec retry_end(pos_integer(), boolean(), term(), keyword()) :: t()
  def retry_end(attempt, success?, reason, opts \\ []) when is_boolean(success?) do
    new(:retry_end, %{attempt: attempt, success?: success?, reason: reason}, opts)
  end

  # ── Compaction ────────────────────────────────────────────────────────

  @compaction_start_fields [:compaction_id, :trigger, :pass, :tokens_before]

  @compaction_end_fields [
    :compaction_id,
    :trigger,
    :status,
    :pass,
    :tokens_before,
    :estimated_tokens_after,
    :retained_count,
    :shadowed_count,
    :duration,
    :summary_model,
    :summary_usage,
    :error
  ]

  @doc """
  Creates the event that starts a compaction pass, from the keyword `fields`
  `:compaction_id`, `:trigger` (`:pressure`, `:overflow`, `:manual`), `:pass`,
  and `:tokens_before`. Unknown fields raise `ArgumentError`.
  """
  @spec compaction_start(keyword(), keyword()) :: t()
  def compaction_start(fields, opts \\ []) when is_list(fields) do
    new(:compaction_start, compaction_data(fields, @compaction_start_fields), opts)
  end

  @doc """
  Creates the event that ends a compaction pass, from the keyword `fields`:
  `:compaction_id`, `:trigger`, `:status` (`:completed`, `:failed`,
  `:cancelled`), `:pass`, `:tokens_before`, `:duration` (native time units),
  and `:error` for a pass that did not complete; `:estimated_tokens_after`,
  `:retained_count`, `:shadowed_count`, `:summary_model`, and `:summary_usage`
  for one that did. Fields not given are `nil`; unknown fields raise
  `ArgumentError`. It never carries prompts or summary content.
  """
  @spec compaction_end(keyword(), keyword()) :: t()
  def compaction_end(fields, opts \\ []) when is_list(fields) do
    new(:compaction_end, compaction_data(fields, @compaction_end_fields), opts)
  end

  @doc """
  Creates the event that reports a provider request is compacted and sent
  again: `trigger` is `:overflow`, and `reason` the provider's error.
  """
  @spec compaction_retry(atom(), term(), keyword()) :: t()
  def compaction_retry(trigger, reason, opts \\ []) do
    new(:compaction_retry, %{trigger: trigger, reason: reason}, opts)
  end

  defp compaction_data(fields, keys) do
    fields
    |> Keyword.validate!(Enum.map(keys, &{&1, nil}))
    |> Map.new()
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
  defp normalize_type(type) when type in [:tool_progress, "tool_progress"], do: :tool_progress

  defp normalize_type(type) when type in [:tool_execution_end, "tool_execution_end"],
    do: :tool_execution_end

  defp normalize_type(type) when type in [:tool_end, "tool_end"], do: :tool_end
  defp normalize_type(type) when type in [:tool_error, "tool_error"], do: :tool_error

  defp normalize_type(type) when is_atom(type) and not is_nil(type), do: type
  defp normalize_type(_type), do: :provider_event

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_keys(map, keys) do
    Enum.reduce(keys, map, &Map.delete(&2, &1))
  end
end
