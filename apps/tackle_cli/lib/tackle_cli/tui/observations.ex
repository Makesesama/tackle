defmodule Tackle.CLI.TUI.Observations do
  @moduledoc """
  Bounded, local lifecycle observations for the attached session, not a journal
  or a VM-wide telemetry collector. Only correlated events are recorded. Streaming
  deltas are counted without retaining their payloads; other events retain a small
  allowlist of scalar fields, never arbitrary provider metadata or error bodies.
  """

  alias Tackle.Lib.Event

  @limit 500
  @fields [
    :iteration,
    :attempt,
    :max_retries,
    :delay_ms,
    :status,
    :name,
    :tool_call_id,
    :model,
    :provider,
    :trigger,
    :run_id,
    :profile,
    :agent_ref
  ]

  defstruct events: [], dropped: 0, deltas: 0, origin: nil, sequence: 0

  @type t :: %__MODULE__{
          events: [map()],
          dropped: non_neg_integer(),
          deltas: non_neg_integer(),
          origin: integer() | nil,
          sequence: non_neg_integer()
        }

  @doc "Records only messages belonging to the currently attached session and turn."
  @spec observe(term(), Tackle.CLI.TUI.State.t()) :: Tackle.CLI.TUI.State.t()
  def observe(message, state) do
    case event(message, state) do
      nil -> state
      {turn_id, event} -> %{state | observations: record(state.observations, turn_id, event)}
    end
  end

  defp event(
         {:tackle_event, session, turn, %Event{} = event},
         %{session_id: session, active_turn: %{id: turn}}
       ),
       do: {turn, event}

  defp event({:tackle_compaction, session, %Event{} = event}, %{session_id: session}),
    do: {nil, event}

  defp event(
         {:tackle_turn_finished, session, turn, {outcome, _agent}},
         %{session_id: session, active_turn: %{id: turn}}
       )
       when outcome in [:ok, :error, :cancelled],
       do: {turn, Event.new(:turn_finished, %{status: outcome})}

  defp event(
         {:tackle_turn_failed, session, turn, _reason},
         %{session_id: session, active_turn: %{id: turn}}
       ),
       do: {turn, Event.new(:turn_failed)}

  defp event(_message, _state), do: nil

  defp record(observations, _turn, %Event{type: :message_delta}),
    do: %{observations | deltas: observations.deltas + 1}

  defp record(observations, turn, event) do
    now = System.monotonic_time(:millisecond)
    origin = observations.origin || now
    sequence = observations.sequence + 1

    row = %{
      sequence: sequence,
      received_at: DateTime.to_iso8601(DateTime.utc_now()),
      emitted_at: timestamp(event.timestamp),
      elapsed_ms: now - origin,
      turn_id: scalar(turn),
      type: scalar(event.type),
      id: scalar(event.id),
      parent_id: scalar(event.parent_id),
      data: Map.new(Map.take(event.data, @fields), fn {key, value} -> {key, scalar(value)} end)
    }

    %{
      observations
      | events: Enum.take([row | observations.events], @limit),
        dropped: max(sequence - @limit, 0),
        sequence: sequence,
        origin: origin
    }
  end

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(_value), do: nil

  defp scalar(value) when is_binary(value), do: String.slice(value, 0, 200)
  defp scalar(value) when is_atom(value) or is_number(value), do: value
  defp scalar(_value), do: :omitted
end
