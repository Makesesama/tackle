defmodule Tackle.CLI.TUI.TurnTipTest do
  @moduledoc """
  Exposure-tracked working tips and their activation wiring.

  A tip appears once a turn has outgrown the delay, but only when the layout
  can spare the row: measuring never counts as exposure. Each template is
  exposed at most once per session.
  """

  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{RuntimeEvents, State, TurnTip}

  @delay_ms 30_000

  defp working(attrs \\ []) do
    started_at_ms = System.monotonic_time(:millisecond) - (@delay_ms + 1_000)

    struct(
      %State{active_turn: %{id: "turn", started_at_ms: started_at_ms}},
      attrs
    )
  end

  describe "activate/1" do
    test "shows one unexposed template once the turn outgrows the delay" do
      tip = TurnTip.activate(working())

      assert %TurnTip{current: current, exposed: [current | _]} = tip
      assert current in TurnTip.remaining(%TurnTip{})
    end

    test "a young turn is not tipped" do
      started_at_ms = System.monotonic_time(:millisecond) - 1_000
      state = working(active_turn: %{id: "turn", started_at_ms: started_at_ms})
      assert TurnTip.activate(state) == nil
    end

    test "a turn adopted from a snapshot has no observable start" do
      assert TurnTip.activate(working(active_turn: %{id: "turn"})) == nil
    end

    test "an open overlay, a typed draft, or another focus defers the tip" do
      assert TurnTip.activate(working(overlay: {:help, %{offset: 0}})) == nil
      assert TurnTip.activate(working(draft_empty?: false)) == nil
      assert TurnTip.activate(working(focus: :transcript)) == nil
    end

    test "a tip already showing is left alone" do
      showing = %TurnTip{current: "already showing", exposed: ["already showing"]}
      assert TurnTip.activate(working(turn_tip: showing)) == nil
    end

    test "a terminal without a spare row defers the tip without exposing it" do
      state = working(size: {80, 6})

      assert TurnTip.activate(state) == nil
      assert state.turn_tip.exposed == []

      assert %TurnTip{} = TurnTip.activate(working(size: {80, 7}))
    end
  end

  describe "exposure" do
    test "each template is shown at most once per session" do
      {tips, exhausted} =
        Enum.reduce(1..20, {[], %TurnTip{}}, fn _turn, {shown, tip} ->
          case TurnTip.activate(working(turn_tip: tip)) do
            %TurnTip{current: current} = activated ->
              {[current | shown], TurnTip.dismiss(activated)}

            nil ->
              {[nil | shown], tip}
          end
        end)

      templates = Enum.reject(tips, &is_nil/1)
      assert templates == Enum.uniq(templates)
      assert length(templates) == length(TurnTip.remaining(%TurnTip{}))

      assert exhausted.current == nil
      assert MapSet.new(exhausted.exposed) == MapSet.new(templates)
    end

    test "dismiss clears the visible tip and keeps the exposure history" do
      tip = %TurnTip{current: "shown", exposed: ["shown"]}

      assert TurnTip.dismiss(tip) == %TurnTip{current: nil, exposed: ["shown"]}
    end
  end

  describe "spinner tick wiring" do
    test "the tick activates an eligible tip exactly once" do
      {:noreply, ticked} = RuntimeEvents.handle({:tui_spinner_tick}, working())
      assert ticked.turn_tip.current != nil

      {:noreply, ticked_again} = RuntimeEvents.handle({:tui_spinner_tick}, ticked)
      assert ticked_again.turn_tip == ticked.turn_tip
    end

    test "the tick leaves an idle shell untouched" do
      idle = working(active_turn: nil)
      assert {:noreply, ticked, _opts} = RuntimeEvents.handle({:tui_spinner_tick}, idle)
      assert ticked.turn_tip == %TurnTip{}
    end
  end
end
