defmodule Tackle.CLI.TUI.Compaction do
  @moduledoc """
  Manual context compaction from the shell.

  Compaction rewrites the provider-visible model projection — a synthetic
  checkpoint plus a verbatim recent tail — while the canonical transcript stays
  intact. It is an idle-only session operation, so the shell refuses to start it
  during a turn or while another operation is pending, and reports the session's
  own `:turn_in_progress` rejection if it races with a starting turn.

  The shell starts compaction as an asynchronous command because the session
  performs the summarization synchronously; the spinner keeps the UI responsive
  and the session's compaction events update an inline transcript card. A completed
  compaction reports how much the projection shrank in a chronological transcript
  card. Automatic lifecycle events use the same card; resumed checkpoints expose
  their summary through the existing transcript inspector.
  """

  alias ExRatatui.Command
  alias Tackle.CLI.TUI.{State, Util, Viewport}
  alias Tackle.Lib.Compaction, as: LibCompaction

  @doc """
  Starts a manual compaction command when the shell is idle.

  Returns a notice instead when a turn is running or another operation is
  already pending.
  """
  @spec request(State.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def request(%State{active_turn: turn} = state) when not is_nil(turn) do
    {:noreply, %{state | notice: "Compaction is available when idle"}}
  end

  def request(%State{pending_operation: operation} = state) when not is_nil(operation) do
    {:noreply, %{state | notice: "Wait for the current operation to finish"}}
  end

  def request(%State{} = state) do
    ref = make_ref()
    agent_ref = state.agent_ref

    command =
      Command.async(
        fn -> Tackle.compact(agent_ref) end,
        &{:tui_operation_result, ref, :compact, &1}
      )

    state = %{
      state
      | pending_operation: %{ref: ref, kind: :compact},
        activity: "compacting",
        error: nil,
        outcome: nil,
        notice: nil
    }

    {:noreply,
     state
     |> project(:compaction_start, %{trigger: :manual})
     |> Viewport.refresh([:settled, :turn]), commands: [command]}
  end

  @doc """
  Returns the human summary of a completed compaction.

  Uses the durable record's before/after token estimates and shadowed-message
  count. Falls back to a plain confirmation when the record is unavailable.
  """
  @spec notice(map() | nil) :: String.t()
  def notice(%{
        tokens_before: before,
        estimated_tokens_after: after_tokens,
        shadowed_message_ids: shadowed
      })
      when is_integer(before) and is_integer(after_tokens) and is_list(shadowed) do
    count = length(shadowed)
    unit = if count == 1, do: "message", else: "messages"

    "Compacted #{count} #{unit} · #{tokens(before)} → #{tokens(after_tokens)} est. tokens"
  end

  def notice(_record), do: "Compacted context"

  @doc "Returns the status-row activity for one compaction lifecycle event."
  @spec activity(term()) :: String.t()
  def activity({:compaction_start, _data}), do: "compacting"
  def activity({:compaction_retry, _data}), do: "compacting"
  def activity({:compaction_end, %{status: :completed}}), do: "compacted"
  def activity({:compaction_end, %{status: :cancelled}}), do: "compaction cancelled"
  def activity({:compaction_end, _data}), do: "compaction failed"
  def activity(_other), do: "compacting"

  @doc "Projects lifecycle metadata into a stable chronological transcript entry."
  @spec project(State.t(), atom(), map()) :: State.t()
  def project(state, type, data) do
    status = if type == :compaction_end, do: Map.get(data, :status, :failed), else: :running
    state = put_card(state, Map.put(data, :status, status), type != :compaction_end)
    %{state | activity: activity({type, data})}
  end

  @doc "Attaches the committed summary without duplicating the lifecycle entry."
  @spec completed(State.t(), map() | nil) :: State.t()
  def completed(state, record) when is_map(record) do
    put_card(state, %{
      compaction_id: Map.get(record, :compaction_id),
      status: :completed,
      trigger: Map.get(record, :trigger),
      tokens_before: Map.get(record, :tokens_before),
      estimated_tokens_after: Map.get(record, :estimated_tokens_after),
      summary: LibCompaction.checkpoint_body(Map.get(record, :summary_message))
    })
  end

  def completed(state, _record), do: put_card(state, %{status: :completed})

  # A provisional manual/retry entry acquires the engine's id on start. Further
  # events and the async result update that same entry, never its position.
  defp put_card(state, data, starting? \\ false) do
    if card = find_card(state.compactions, Map.get(data, :compaction_id), starting?) do
      updated = Map.merge(card, data)

      %{
        state
        | compactions: Enum.map(state.compactions, &if(&1.id == card.id, do: updated, else: &1))
      }
    else
      append_card(state, data)
    end
  end

  defp find_card(cards, id, starting?) do
    last = List.last(cards)
    existing = if id, do: Enum.find(cards, &(Map.get(&1, :compaction_id) == id))
    provisional? = last && last.status == :running && is_nil(Map.get(last, :compaction_id))
    existing || if(provisional? || (is_nil(id) and not starting?), do: last)
  end

  defp append_card(state, data) do
    turn_id = if state.active_turn, do: state.active_turn.id
    known_ids = MapSet.new(state.agent_state.messages, & &1.id)
    new_ids = Enum.reject(state.stream.message_ids, &MapSet.member?(known_ids, &1))
    pending = if state.pending_prompt && new_ids == [], do: 1, else: 0

    card =
      Map.merge(data, %{
        id: "context:compaction:#{System.unique_integer([:positive, :monotonic])}",
        turn_id: turn_id,
        boundary: length(state.agent_state.messages) + length(new_ids) + pending
      })

    timeline =
      if turn_id,
        do: state.stream.timeline ++ [%{kind: :compaction, id: card.id}],
        else: state.stream.timeline

    %{
      state
      | compactions: state.compactions ++ [card],
        stream: %{state.stream | timeline: timeline}
    }
  end

  @doc "Moves live entries to their canonical message boundaries when a turn settles."
  @spec settle(State.t(), Tackle.Lib.State.t()) :: State.t()
  def settle(state, agent_state) do
    checkpoint = checkpoint(agent_state)

    cards =
      Enum.map(state.compactions, fn card ->
        card =
          if state.active_turn && card.turn_id == state.active_turn.id,
            do: %{card | turn_id: nil, boundary: min(card.boundary, length(agent_state.messages))},
            else: card

        if checkpoint && Map.get(card, :compaction_id) == checkpoint.id,
          do: Map.put(card, :summary, LibCompaction.checkpoint_body(checkpoint)),
          else: card
      end)

    %{state | compactions: cards}
  end

  @doc "Exposes a resumed checkpoint without inventing its historical position."
  @spec restore(State.t()) :: State.t()
  def restore(state) do
    case checkpoint(state.agent_state) do
      nil ->
        state

      checkpoint ->
        card = %{
          id: "context:checkpoint:#{checkpoint.id}",
          compaction_id: checkpoint.id,
          status: :completed,
          turn_id: nil,
          boundary: 0,
          restored?: true,
          summary: LibCompaction.checkpoint_body(checkpoint)
        }

        %{state | compactions: [card]}
    end
  end

  defp checkpoint(agent_state) do
    case agent_state.model_messages do
      [first | _] -> if LibCompaction.checkpoint?(first), do: first
      _ -> nil
    end
  end

  @doc "Returns the visible card text; estimates are never presented as measured usage."
  @spec card_text(map()) :: String.t()
  def card_text(%{status: :running} = data) do
    label =
      case Map.get(data, :trigger) do
        :pressure -> "Auto-compacting context (context pressure)…"
        :overflow -> "Auto-compacting context (context overflow)…"
        _ -> "Compacting context…"
      end

    case Map.get(data, :pass) do
      pass when is_integer(pass) and pass > 1 -> label <> " · pass #{pass}"
      _ -> label
    end
  end

  def card_text(%{status: :completed} = data) do
    case data do
      %{tokens_before: before, estimated_tokens_after: after_tokens}
      when is_integer(before) and is_integer(after_tokens) ->
        "Context compacted · #{tokens(before)} → #{tokens(after_tokens)} est. tokens"

      _ ->
        "Context compacted"
    end
  end

  def card_text(%{status: status} = data) do
    label = if status == :cancelled, do: "Compaction cancelled", else: "Compaction failed"

    case Map.get(data, :error) do
      nil -> label
      reason -> label <> ": " <> Util.format_reason(reason)
    end
  end

  defp tokens(count) when count < 1_000, do: Integer.to_string(count)

  defp tokens(count) when count < 1_000_000,
    do: compact_decimal(count / 1_000, "k")

  defp tokens(count), do: compact_decimal(count / 1_000_000, "m")

  defp compact_decimal(value, suffix) do
    decimals = if value < 10 and value != trunc(value), do: 1, else: 0
    :erlang.float_to_binary(value / 1, decimals: decimals) <> suffix
  end
end
