defmodule Tackle.CLI.TUI.StatusView do
  @moduledoc """
  The status row, metric segments, and right-aligned help cue.

  The status row reports honest turn state (`ready`, `thinking`, `running
  <tool>`, `cancelling`, `cancelled`, `failed`) followed by available usage
  metadata: context pressure, combined input/output tokens, cache reuse and
  cost. Missing metadata is omitted rather than shown as zero. While the
  shell is busy, a compact elapsed clock rides with the leading status word
  (`working (1m 12s)`), so state and clock survive narrow terminals together.

  The right-hand hints follow a documented collapse ladder (the pattern is
  ported from codex's `bottom_pane/footer.rs`): hints drop whole, lowest
  priority first, and never render without room for their full text. While
  a turn runs, `esc interrupt` outlives `? help` because the interrupt is
  time-critical and the shortcut reference stays reachable through the
  popup. An open overlay owns the status row, so hints only appear on the
  plain shell.
  """

  alias Tackle.CLI.TUI.{
    Browser,
    Conversation,
    KeyHint,
    MessageView,
    Picker,
    State,
    Subagents,
    Theme,
    UsageChart
  }

  alias Tackle.CLI.TUI.State.Metrics
  alias Tackle.Lib
  alias Tackle.Lib.{ContextUsage, Usage}

  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @doc "Builds the status row for the current state and terminal width."
  @spec status_widget(State.t(), integer()) :: ExRatatui.Widgets.Paragraph.t()
  def status_widget(%State{} = state, width) do
    %ExRatatui.Widgets.Paragraph{
      text: [MessageView.row(status_spans(state, width), %ExRatatui.Style{})]
    }
  end

  @doc "Returns the short word describing the current turn state."
  @spec status_label(State.t()) :: String.t()
  def status_label(%State{} = state) do
    label = turn_label(state)
    if busy?(state), do: "#{spinner(state.spinner_frame)} #{label}", else: label
  end

  defp turn_label(%State{storage: :delayed}), do: "Waiting for session storage"
  defp turn_label(%State{pending_operation: %{kind: :reconfigure}}), do: "reconfiguring"
  defp turn_label(%State{pending_operation: %{kind: :compact}}), do: "compacting"
  defp turn_label(%State{pending_operation: %{kind: :cancel}}), do: "cancelling"

  defp turn_label(%State{pending_operation: %{kind: :submit}, activity: activity}),
    do: activity || "starting"

  defp turn_label(%State{active_turn: nil, error: error}) when is_binary(error), do: "failed"
  defp turn_label(%State{active_turn: nil, outcome: :cancelled}), do: "cancelled"
  defp turn_label(%State{active_turn: nil}), do: "ready"
  defp turn_label(%State{activity: nil}), do: "working"
  defp turn_label(%State{activity: activity}), do: activity

  @doc "Returns the style that carries the current turn state's meaning."
  @spec status_style(State.t()) :: ExRatatui.Style.t()
  def status_style(state) do
    cond do
      state.storage == :delayed -> Theme.style(:warning)
      is_binary(state.error) -> Theme.style(:error)
      state.active_turn != nil or state.pending_operation != nil -> Theme.style(:accent_soft)
      state.outcome == :cancelled -> Theme.style(:warning)
      true -> Theme.style(:muted)
    end
  end

  defp status_spans(state, width) do
    segments = status_segments(state)
    hints = right_hints(state, width, hd(segments))
    # Reserve the hint row plus its two-column gap and one-column right
    # margin when hints are showing.
    hint_width = KeyHint.row_width(hints)
    available = if hints == [], do: width - 1, else: width - hint_width - 3

    [first | rest] = fit_segments(segments, available)

    spans =
      [MessageView.span(" " <> first, status_style(state))] ++
        Enum.map(rest, fn segment ->
          MessageView.span("  ·  " <> segment, Theme.style(:muted))
        end)

    if hints == [] do
      spans
    else
      gap = max(width - spans_width(spans) - hint_width - 1, 0)

      spans ++
        [
          MessageView.span(String.duplicate(" ", gap), %ExRatatui.Style{})
          | KeyHint.row_spans(hints)
        ]
    end
  end

  # Right-side hint ladder, fullest first. Hints drop whole from the
  # ladder's end, so `esc interrupt` outlives `? help` while busy, and the
  # leading state segment always keeps its space: hints are chosen from the
  # width it leaves behind.
  defp right_hints(%State{overlay: nil} = state, width, leading) do
    candidates =
      if busy?(state) do
        [[{"esc", "interrupt"}, {"?", "help"}], [{"esc", "interrupt"}], []]
      else
        [[{"?", "help"}], []]
      end

    KeyHint.first_fitting(candidates, width - 1 - MessageView.display_width(leading) - 3)
  end

  defp right_hints(%State{}, _width, _leading), do: []

  defp spans_width(spans) do
    Enum.reduce(spans, 0, fn span, total -> total + MessageView.display_width(span.content) end)
  end

  # An overlay owns the status row while it is open, so search and menus show
  # what the keyboard will do instead of turn metrics the user cannot act on.
  defp status_segments(%State{overlay: {:help, _}}), do: ["Shortcuts", "↑/↓ scroll · ?/Esc close"]

  defp status_segments(%State{overlay: {:search, search}}) do
    case search.matches do
      [] ->
        ["Search", if(search.query == "", do: "type to search", else: "no matches")]

      matches ->
        [
          "Match #{search.index + 1}/#{length(matches)}",
          current_search_preview(matches, search.index)
        ]
    end
  end

  defp status_segments(%State{overlay: {:usage_chart, chart_state}}),
    do: UsageChart.status_segments(chart_state)

  defp status_segments(%State{overlay: {:picker, %{picker: picker}}}) do
    case Picker.selected(picker) do
      nil -> ["Menu", "no matches"]
      item -> ["Menu", item[:secondary] || item[:primary]]
    end
  end

  defp status_segments(%State{focus: :subagents, notice: notice}) when is_binary(notice),
    do: ["Subagents", notice]

  defp status_segments(%State{focus: :subagents} = state) do
    tasks = Subagents.tasks(state)
    index = Enum.find_index(tasks, &(&1.id == state.subagent_selected)) || 0

    ["Subagents", "#{index + 1}/#{length(tasks)}", "#{length(tasks)} running"]
  end

  defp status_segments(%State{focus: :transcript, notice: notice}) when is_binary(notice),
    do: ["Browsing", notice]

  defp status_segments(%State{focus: :transcript, browse_page: page}) when page != :transcript,
    do: [
      "Browsing",
      Atom.to_string(page),
      "Transcript · Overview · Prompt · Context · Tools · Events"
    ]

  defp status_segments(%State{focus: :transcript} = state) do
    entries = Conversation.entries(state.conversation)
    index = Enum.find_index(entries, &(&1.id == state.selected_entry)) || 0

    case Browser.focused_entry(state) do
      nil -> ["Browsing", "nothing selected"]
      entry -> ["Browsing", "#{index + 1}/#{length(entries)}", entry_preview(entry)]
    end
  end

  defp status_segments(%State{} = state) do
    [leading_segment(state), state.notice]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(busy_segments(state) ++ metric_segments(state))
  end

  # The elapsed clock rides with the leading status word, the way codex
  # prints it inline in the working header, so the clock never competes
  # with metric segments for space.
  defp leading_segment(state) do
    case elapsed_ms(state) do
      nil -> status_label(state)
      elapsed -> "#{status_label(state)} (#{format_elapsed(elapsed)})"
    end
  end

  # An active turn's clock wins over a pending operation's so cancelling a
  # running turn does not restart the clock; a turn adopted from a snapshot
  # has no observable start and shows no clock.
  defp elapsed_ms(%State{active_turn: %{started_at_ms: started_at_ms}}),
    do: max(System.monotonic_time(:millisecond) - started_at_ms, 0)

  defp elapsed_ms(%State{pending_operation: %{started_at_ms: started_at_ms}}),
    do: max(System.monotonic_time(:millisecond) - started_at_ms, 0)

  defp elapsed_ms(%State{}), do: nil

  # codex's compact working clock: 0s … 59s, 1m 00s … 59m 59s, 1h 00m 00s.
  defp format_elapsed(ms) do
    seconds = div(ms, 1000)
    {hours, rest} = {div(seconds, 3600), rem(seconds, 3600)}
    {minutes, secs} = {div(rest, 60), rem(rest, 60)}

    cond do
      hours > 0 -> "#{hours}h #{pad2(minutes)}m #{pad2(secs)}s"
      minutes > 0 -> "#{minutes}m #{pad2(secs)}s"
      true -> "#{seconds}s"
    end
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp current_search_preview(matches, index) do
    case Enum.at(matches, index) do
      nil -> ""
      match -> match.preview
    end
  end

  defp busy_segments(%State{active_turn: nil}), do: []
  defp busy_segments(%State{notice: notice}) when is_binary(notice), do: []
  defp busy_segments(%State{draft_empty?: true}), do: []
  defp busy_segments(%State{}), do: ["new prompts queue at the next safe boundary"]

  # Fits the leading status word plus as many metric segments as the width
  # allows. The first segment is always kept so the working state survives a
  # narrow terminal.
  defp fit_segments([first | rest], width) do
    width = max(width, 1)

    rest
    |> Enum.reduce({[first], MessageView.display_width(first) + 1}, fn segment, {kept, used} ->
      candidate = used + 4 + MessageView.display_width(segment)

      if candidate <= width do
        {[segment | kept], candidate}
      else
        {kept, used}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp entry_preview(entry) do
    text =
      if entry.kind == :tool, do: MessageView.text(entry), else: MessageView.source_text(entry)

    preview =
      text
      |> MessageView.sanitize()
      |> String.split()
      |> Enum.join(" ")

    if String.length(preview) > 72, do: String.slice(preview, 0, 71) <> "…", else: preview
  end

  defp metric_segments(state) do
    usage = displayed_usage(state)

    [
      compaction_indicator(state),
      token_indicator(usage.input_tokens, usage.output_tokens),
      context_indicator(displayed_context_usage(state)),
      cache_hit_indicator(cache_segments(state)),
      cost_indicator(usage)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # A compaction on the active branch means the provider surface is compacted
  # even though the transcript still shows the full history.
  defp compaction_indicator(%State{agent_state: %Lib.State{} = agent_state}) do
    if Lib.State.last_compaction_id(agent_state), do: "compacted"
  end

  defp compaction_indicator(_state), do: nil

  defp displayed_usage(state) do
    settled =
      state.agent_state.messages
      |> Enum.map(&Usage.normalize(&1.token_usage))
      |> Enum.reject(&(is_nil(&1) or not usage_activity?(&1)))

    Usage.aggregate(settled ++ state.metrics.turn_usages)
  end

  # Cache reuse is measured per span between compactions: a compaction
  # rewrites the context, so its new prefix is not a cache miss (see
  # `Tackle.Lib.Usage.cache_reuse/1`). The running turn continues the last
  # settled span until a compaction during the turn starts a new one.
  defp cache_segments(state) do
    [live | live_rest] = Metrics.turn_segments(state.metrics)

    settled =
      state.agent_state
      |> Lib.State.usage_segments()
      |> List.update_at(-1, &(&1 ++ live))

    Enum.map(settled ++ live_rest, fn segment ->
      segment |> Enum.map(&Usage.normalize/1) |> Enum.filter(&usage_activity?/1)
    end)
  end

  defp displayed_context_usage(%State{metrics: %{context_usage: %ContextUsage{} = context}}),
    do: context

  defp displayed_context_usage(%State{} = state), do: ContextUsage.estimate(state.agent_state)

  defp context_indicator(%ContextUsage{} = context) do
    percentage = :erlang.float_to_binary(context.percent, decimals: 1)

    "ctx #{format_token_count(context.tokens)}/#{format_token_count(context.context_window)} " <>
      "(#{percentage}%)"
  end

  defp context_indicator(nil), do: nil

  defp token_indicator(nil, nil), do: nil

  defp token_indicator(input, output) do
    "tokens #{token_count(input)}/#{token_count(output)} in/out"
  end

  defp token_count(nil), do: "–"
  defp token_count(tokens), do: format_token_count(tokens)

  defp cache_hit_indicator(usages) do
    case Usage.cache_reuse_rate(usages) do
      rate when is_float(rate) ->
        percentage = :erlang.float_to_binary(rate * 100, decimals: 1)
        "CH#{percentage}%"

      _unavailable ->
        nil
    end
  end

  defp cost_indicator(%Usage{cost: cost, currency: currency} = usage) when is_number(cost) do
    marker = if usage.cost_estimated == true, do: "~", else: ""
    decimals = if abs(cost) < 0.01, do: 4, else: 2
    amount = :erlang.float_to_binary(cost / 1, decimals: decimals)

    case currency do
      "USD" -> "#{marker}$#{amount}"
      currency when is_binary(currency) -> "#{marker}#{currency} #{amount}"
      nil -> "cost #{marker}#{amount}"
    end
  end

  defp cost_indicator(%Usage{}), do: nil

  defp busy?(state),
    do:
      state.storage == :delayed or not is_nil(state.active_turn) or
        not is_nil(state.pending_operation)

  defp spinner(frame), do: Enum.at(@spinner_frames, rem(frame, length(@spinner_frames)))

  defp format_token_count(tokens) when tokens < 1_000, do: Integer.to_string(tokens)

  defp format_token_count(tokens) when tokens < 1_000_000,
    do: compact_decimal(tokens / 1_000, "k")

  defp format_token_count(tokens), do: compact_decimal(tokens / 1_000_000, "m")

  defp compact_decimal(value, suffix) do
    decimals = if value < 10 and value != trunc(value), do: 1, else: 0
    :erlang.float_to_binary(value / 1, decimals: decimals) <> suffix
  end

  defp usage_activity?(%Usage{} = usage) do
    Enum.any?(
      [
        usage.input_tokens,
        usage.output_tokens,
        usage.reasoning_tokens,
        usage.cache_read_tokens,
        usage.cache_write_tokens,
        usage.total_tokens
      ],
      &is_integer/1
    ) or is_number(usage.cost)
  end
end
