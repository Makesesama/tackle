defmodule Tackle.CLI.UsageChartTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Native
  alias ExRatatui.Widgets.{Chart, Paragraph, Popup}
  alias Tackle.CLI.Keybinds
  alias Tackle.CLI.TUI.{State, UsageChart}
  alias Tackle.Session.Projection
  alias Tackle.Session.UsageTimeline

  test "F6 opens a non-repeatable usage chart from either base focus" do
    key = %Key{code: "f6", modifiers: []}

    assert Keybinds.base(key, :composer) == :usage_chart
    assert Keybinds.base(key, :transcript) == :usage_chart
    refute Keybinds.repeatable?(key)
  end

  test "chart bindings switch, reload, close, and isolate other keys" do
    assert Keybinds.usage_chart(%Key{code: "tab"}) == :toggle
    assert Keybinds.usage_chart(%Key{code: "left"}) == :toggle
    assert Keybinds.usage_chart(%Key{code: "right"}) == :toggle
    assert Keybinds.usage_chart(%Key{code: "r"}) == :reload
    assert Keybinds.usage_chart(%Key{code: "esc"}) == :close
    assert Keybinds.usage_chart(%Key{code: "x"}) == :ignore
  end

  test "open loads current usage asynchronously and correlates the result" do
    timeline = timeline([{"one", "2026-01-01T00:00:00Z", 5}])

    state = %State{
      session_id: "session-1",
      usage_timeline_loader: fn mode, session_id ->
        assert mode == :current
        assert session_id == "session-1"
        {:ok, timeline}
      end
    }

    assert {:noreply, loading, commands: [command]} = UsageChart.open(state)
    assert {:usage_chart, %{mode: :current, status: :loading, request_ref: ref}} = loading.overlay

    message = command.mapper.(command.fun.())
    assert {:tui_usage_timeline_result, ^ref, :current, "session-1", {:ok, ^timeline}} = message

    assert {:noreply, loaded} =
             UsageChart.apply_result(loading, ref, :current, "session-1", {:ok, timeline})

    assert {:usage_chart, %{status: :loaded, timeline: ^timeline}} = loaded.overlay
    assert loaded.usage_timeline_cache[{:current, "session-1"}] == timeline
  end

  test "cached modes switch without I/O while reload bypasses the cache" do
    timeline = timeline([{"one", "2026-01-01T00:00:00Z", 5}])

    state = %State{
      session_id: "session-1",
      usage_timeline_cache: %{{:current, "session-1"} => timeline},
      usage_timeline_loader: fn _mode, _session_id -> flunk("cached load performed I/O") end
    }

    assert {:noreply, cached} = UsageChart.open(state)
    assert {:usage_chart, %{status: :loaded, timeline: ^timeline}} = cached.overlay

    reloading = %{cached | usage_timeline_loader: fn _mode, _session_id -> {:ok, timeline} end}
    assert {:noreply, loading, commands: [_]} = UsageChart.handle(:reload, reloading)
    assert {:usage_chart, %{status: :loading}} = loading.overlay

    assert UsageChart.invalidate_cache(cached).usage_timeline_cache == %{}
  end

  test "stale asynchronous results do not replace a newer mode" do
    state = %State{
      session_id: "session-1",
      usage_timeline_loader: fn _mode, _session_id -> {:ok, timeline([])} end
    }

    {:noreply, current, commands: [_]} = UsageChart.open(state)
    {:usage_chart, %{request_ref: stale_ref}} = current.overlay
    {:noreply, all, commands: [_]} = UsageChart.handle(:toggle, current)

    assert {:noreply, unchanged, render?: false} =
             UsageChart.apply_result(
               all,
               stale_ref,
               :current,
               "session-1",
               {:ok, timeline([])}
             )

    assert unchanged == all
  end

  test "buckets accumulate chronological usage and stay flat across gaps" do
    timeline =
      timeline([
        {"one", "2026-01-01T00:00:00Z", 2},
        {"two", "2026-01-01T00:00:00Z", 3},
        {"three", "2026-01-01T00:10:00Z", 7}
      ])

    model = UsageChart.buckets(timeline.samples, 80)

    assert model.interval_seconds == 60
    assert Enum.map(model.buckets, &elem(&1, 1)) == [5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 12]

    assert model.data == [
             {0.0, 5.0},
             {1.0, 5.0},
             {2.0, 5.0},
             {3.0, 5.0},
             {4.0, 5.0},
             {5.0, 5.0},
             {6.0, 5.0},
             {7.0, 5.0},
             {8.0, 5.0},
             {9.0, 5.0},
             {10.0, 12.0}
           ]

    assert model.x_bounds == {0.0, 10.0}
    assert model.y_bounds == {0.0, 12.0}
  end

  test "one observation gets non-degenerate axes without decreasing" do
    timeline = timeline([{"one", "2026-01-01T00:00:00Z", 5}])
    model = UsageChart.buckets(timeline.samples, 40)

    assert model.x_bounds == {0.0, 1.0}
    assert model.y_bounds == {0.0, 5.0}
    assert Enum.map(model.buckets, &elem(&1, 1)) == [5, 5]
    assert [_, _, _] = model.x_labels
  end

  test "all-session visibility is limited to the current UTC calendar week" do
    timeline =
      timeline([
        {"before", "2026-09-06T23:59:59Z", 3},
        {"monday", "2026-09-07T00:00:00Z", 5},
        {"today", "2026-09-09T12:00:00Z", 7},
        {"future", "2026-09-09T12:00:01Z", 11}
      ])

    now = ~U[2026-09-09 12:00:00Z]

    assert timeline.samples
           |> UsageChart.visible_samples(:all, now)
           |> Enum.map(& &1.message_id) == ["monday", "today"]

    assert UsageChart.visible_samples(timeline.samples, :current, now) == timeline.samples
  end

  test "loaded popup uses cumulative tokens and draws the requested breakdown" do
    timeline =
      detailed_timeline([
        {"one", "2026-09-08T00:00:00Z",
         %{
           "input_tokens" => 5,
           "output_tokens" => 2,
           "cache_read_tokens" => 3,
           "cost" => 0.001,
           "cost_estimated" => true,
           "currency" => "USD"
         }},
        {"two", "2026-09-09T00:00:00Z",
         %{
           "input_tokens" => 7,
           "output_tokens" => 4,
           "cache_write_tokens" => 2,
           "cost" => 0.002,
           "cost_estimated" => true,
           "currency" => "USD"
         }}
      ])

    state = %State{
      size: {80, 24},
      overlay:
        {:usage_chart,
         %{
           mode: :current,
           status: :loaded,
           request_ref: make_ref(),
           session_id: "session-1",
           timeline: timeline,
           error: nil
         }}
    }

    assert %Popup{content: %Chart{} = chart} = popup = UsageChart.popup(state)

    assert [%ExRatatui.Widgets.Chart.Dataset{graph_type: :line, marker: :braille}] =
             chart.datasets

    terminal = ExRatatui.init_test_terminal(80, 24)
    on_exit(fn -> Native.restore_terminal(terminal) end)

    assert :ok = ExRatatui.draw(terminal, [{popup, %Rect{x: 0, y: 0, width: 80, height: 24}}])
    content = ExRatatui.get_buffer_content(terminal)
    assert content =~ "Usage"
    assert content =~ "generations"
    assert content =~ "in 12"
    assert content =~ "out 6"
    assert content =~ "cache 5"
    assert content =~ "cost ~$0.0030"
    assert content =~ "cumulative tokens"
  end

  test "empty, error, and small-terminal states use explanatory paragraphs" do
    for chart_state <- [
          %{mode: :current, status: :empty, timeline: timeline([]), error: nil},
          %{mode: :current, status: :error, timeline: nil, error: :broken}
        ] do
      state = %State{size: {80, 24}, overlay: {:usage_chart, chart_state}}
      assert %Popup{content: %Paragraph{}} = UsageChart.popup(state)
    end

    chart_state = %{mode: :current, status: :loaded, timeline: timeline([]), error: nil}
    state = %State{size: {30, 8}, overlay: {:usage_chart, chart_state}}
    assert %Popup{content: %Paragraph{text: text}} = UsageChart.popup(state)
    assert text =~ "too small"
  end

  defp timeline(entries) do
    detailed_timeline(
      Enum.map(entries, fn {id, timestamp, total} ->
        {id, timestamp, %{"total_tokens" => total}}
      end)
    )
  end

  defp detailed_timeline(entries) do
    messages =
      Enum.map(entries, fn {id, timestamp, usage} ->
        %{
          "id" => id,
          "role" => "assistant",
          "timestamp" => timestamp,
          "token_usage" => usage
        }
      end)

    UsageTimeline.from_projection(%Projection{session_id: "session-1", messages: messages})
  end
end
