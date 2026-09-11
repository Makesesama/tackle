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
  and the session's compaction events drive the live status row. A completed
  compaction reports how much the projection shrank.
  """

  alias ExRatatui.Command
  alias Tackle.CLI.TUI.State

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

    {:noreply, state, commands: [command]}
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

  defp tokens(count) when count < 1_000, do: Integer.to_string(count)

  defp tokens(count) when count < 1_000_000,
    do: compact_decimal(count / 1_000, "k")

  defp tokens(count), do: compact_decimal(count / 1_000_000, "m")

  defp compact_decimal(value, suffix) do
    decimals = if value < 10 and value != trunc(value), do: 1, else: 0
    :erlang.float_to_binary(value / 1, decimals: decimals) <> suffix
  end
end
