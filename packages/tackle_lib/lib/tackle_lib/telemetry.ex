defmodule Tackle.Lib.Telemetry do
  @moduledoc """
  Small, exporter-neutral lifecycle telemetry spans.

  A span follows the `:telemetry.span/3` conventions for work whose start and
  end happen in different places (a turn that starts in one process and
  settles in another), so it cannot wrap a single function:

    * `start/2` emits `prefix ++ [:start]` with `:system_time` and
      `:monotonic_time` measurements and returns the span;
    * `stop/3` emits `prefix ++ [:stop]`, and `exception/4`
      `prefix ++ [:exception]`, each with `:duration` (native time units since
      the start) and `:monotonic_time` measurements added to the caller's.

  Every event's metadata holds the start metadata, merged with the stop or
  exception metadata, and the span's `:telemetry_ref` to correlate the
  events. Exception metadata also holds `:kind` (`:error`, `:exit`, or
  `:throw`). Unlike `:telemetry.span/3`, it never holds the raw reason or
  stacktrace: event metadata intentionally contains only correlation
  references and bounded classifications. Callers must never pass prompts,
  messages, tool arguments, tool results, or raw errors to these functions;
  classify a failure into a bounded value (such as `:error_type`) instead.
  """

  @enforce_keys [:event_prefix, :telemetry_ref, :metadata, :started_at]
  defstruct [:event_prefix, :telemetry_ref, :metadata, :started_at]

  @type event_prefix :: [atom()]
  @type kind :: :error | :exit | :throw

  @typedoc """
  A started span: its event prefix, its `:telemetry_ref`, its start metadata,
  and its monotonic start time.
  """
  @type t :: %__MODULE__{
          event_prefix: event_prefix(),
          telemetry_ref: reference(),
          metadata: map(),
          started_at: integer()
        }

  @doc """
  Starts a span: emits `event_prefix ++ [:start]` and returns the span to
  pass to `stop/3` or `exception/4`.
  """
  @spec start(event_prefix(), map()) :: t()
  def start(event_prefix, metadata \\ %{}) when is_list(event_prefix) and is_map(metadata) do
    span = %__MODULE__{
      event_prefix: event_prefix,
      telemetry_ref: make_ref(),
      metadata: metadata,
      started_at: System.monotonic_time()
    }

    :telemetry.execute(
      event_prefix ++ [:start],
      %{system_time: System.system_time(), monotonic_time: span.started_at},
      event_metadata(span, %{})
    )

    span
  end

  @doc """
  Ends a span successfully: emits `event_prefix ++ [:stop]` with the span's
  `:duration` and the given measurements, and the start metadata merged with
  `metadata`.
  """
  @spec stop(t(), map(), map()) :: :ok
  def stop(%__MODULE__{} = span, measurements \\ %{}, metadata \\ %{})
      when is_map(measurements) and is_map(metadata) do
    emit(span, :stop, measurements, metadata)
  end

  @doc """
  Ends a span with a failure of `kind`: emits `event_prefix ++ [:exception]`
  with the span's `:duration` and the given measurements, and the start
  metadata merged with `metadata` and `:kind`.
  """
  @spec exception(t(), kind(), map(), map()) :: :ok
  def exception(%__MODULE__{} = span, kind, measurements \\ %{}, metadata \\ %{})
      when kind in [:error, :exit, :throw] and is_map(measurements) and is_map(metadata) do
    emit(span, :exception, measurements, Map.put(metadata, :kind, kind))
  end

  defp emit(span, event, measurements, metadata) do
    now = System.monotonic_time()

    :telemetry.execute(
      span.event_prefix ++ [event],
      Map.merge(measurements, %{duration: now - span.started_at, monotonic_time: now}),
      event_metadata(span, metadata)
    )

    :ok
  end

  defp event_metadata(span, metadata) do
    span.metadata
    |> Map.merge(metadata)
    |> Map.put(:telemetry_ref, span.telemetry_ref)
  end
end
