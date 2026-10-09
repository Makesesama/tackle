defmodule Tackle.CLI.TUI.StatusViewTest do
  @moduledoc """
  The elapsed clock and the right-side hint ladder.

  The clock rides with the leading status word; the hints collapse by
  documented priority (`esc interrupt` outlives `? help` while busy) and are
  dropped whole, never truncated.
  """

  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{State, StatusView}
  alias Tackle.Lib.State, as: AgentState

  defp shell(attrs \\ []) do
    struct(
      %State{
        session_id: "session",
        agent_state: %AgentState{messages: []},
        size: {80, 24}
      },
      attrs
    )
  end

  defp status_text(state, width \\ 80) do
    state
    |> StatusView.status_widget(width)
    |> Map.fetch!(:text)
    |> Enum.map_join("\n", fn line -> Enum.map_join(line.spans, & &1.content) end)
  end

  defp status_spans(state, width \\ 80) do
    state
    |> StatusView.status_widget(width)
    |> Map.fetch!(:text)
    |> hd()
    |> Map.fetch!(:spans)
  end

  test "durability waiting takes priority over activity, cancellation, and transient notices" do
    state =
      shell(
        storage: :delayed,
        activity: "thinking",
        notice: nil,
        pending_operation: %{kind: :cancel, started_at_ms: System.monotonic_time(:millisecond)}
      )

    assert status_text(state) =~ "Waiting for session storage"
    refute status_text(state) =~ "cancelling"
    assert status_text(%{state | storage: :ready}) =~ "cancelling"
  end

  describe "elapsed clock" do
    test "rides with the working status" do
      started_at_ms = System.monotonic_time(:millisecond) - 72_000
      state = shell(active_turn: %{id: "turn", started_at_ms: started_at_ms})

      assert status_text(state) =~ "working (1m 12s)"
    end

    test "follows codex's compact boundaries" do
      now = System.monotonic_time(:millisecond)

      for {elapsed, expected} <- [
            {0, "(0s)"},
            {59_000, "(59s)"},
            {60_000, "(1m 00s)"},
            {3_599_000, "(59m 59s)"},
            {3_600_000, "(1h 00m 00s)"}
          ] do
        state = shell(active_turn: %{id: "turn", started_at_ms: now - elapsed})
        assert status_text(state) =~ expected
      end
    end

    test "runs for pending operations too" do
      started_at_ms = System.monotonic_time(:millisecond) - 5_000
      state = shell(pending_operation: %{kind: :compact, started_at_ms: started_at_ms})

      assert status_text(state) =~ "compacting (5s)"
    end

    test "an active turn's clock wins over a pending operation's" do
      now = System.monotonic_time(:millisecond)

      state =
        shell(
          active_turn: %{id: "turn", started_at_ms: now - 60_000},
          pending_operation: %{kind: :cancel, started_at_ms: now}
        )

      assert status_text(state) =~ "cancelling (1m 00s)"
    end

    test "a turn without an observable start shows no clock" do
      assert status_text(shell(active_turn: %{id: "turn"})) =~ "working"
      refute status_text(shell(active_turn: %{id: "turn"})) =~ ~r/\(\d+[smh]/
      refute status_text(shell()) =~ ~r/\(\d+[smh]/
    end
  end

  describe "right-side hint ladder" do
    test "an idle shell right-aligns the shortcuts hint" do
      text = status_text(shell())

      assert text =~ "? help"
      assert String.ends_with?(text, "? help")
    end

    test "hint keys are bold and labels are muted" do
      key = Enum.find(status_spans(shell()), &(&1.content == "?"))
      assert :bold in key.style.modifiers
    end

    test "a busy shell keeps the interrupt hint longer than the shortcuts cue" do
      # A minute-old turn keeps the leading segment a stable width.
      state =
        shell(
          active_turn: %{id: "turn", started_at_ms: System.monotonic_time(:millisecond) - 61_000}
        )

      wide = status_text(state, 50)
      assert wide =~ "esc interrupt"
      assert wide =~ "? help"

      # Narrow terminals drop `? help` first, whole.
      narrow = status_text(state, 40)
      assert narrow =~ "esc interrupt"
      refute narrow =~ "? help"

      # The leading state outlives every hint.
      tight = status_text(state, 24)
      assert tight =~ "working"
      refute tight =~ "esc interrupt"
    end

    test "an open overlay owns the status row, so hints step aside" do
      state = shell(overlay: {:help, %{offset: 0}})

      assert status_text(state) =~ "Shortcuts"
      refute status_text(state) =~ "? help"
    end
  end
end
