defmodule Tackle.CLI.TUI.ReviewView do
  @moduledoc """
  Draws the `/review` overlay over the whole screen.

  The frame holds a header, a body, and a footer:

    * the **header** carries a verdict badge (`REVIEWING`, `✗ 2 BLOCKING`,
      `✓ CLEAN`, ...), what is reviewed with its diff size, the elapsed
      time while the review runs or its cost once it finished, and below
      them either the tabs (`Findings` / `Summary`) with a count per
      severity, or the pipeline stepper while the review runs;
    * the **body** is the live dashboard while the review runs without
      findings (`Tackle.CLI.TUI.ReviewDashboard`), the findings once there
      are some, or the summary page (`ReviewDashboard.summary_rows/2`) for
      the `Summary` tab and for a review that ended without findings;
    * the **footer** carries the latest notice, or the key hints that fit,
      dropped whole by priority when the screen is narrow.

  The findings body splits into a list, grouped into blocking and optional
  with two rows per finding (a severity badge and the title, then the
  location, category, and rule), and a detail pane for the selected
  finding: its facts, a confidence meter, the explanation, trigger,
  suggested fix, and the code it points at, cut from the function around
  it (`Tackle.Review.FunctionContext`) and highlighted with
  `Tackle.CLI.TUI.Highlight`. Wide terminals put the panes side by side;
  narrow ones stack them. A pane longer than its space shows how much is
  left, and `max_scroll/1` bounds the scroll so it never runs past the end.

  Every row is clipped to its pane, so the overlay never wraps outside its
  frame.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Clear, Paragraph}
  alias Tackle.CLI.Output.Review, as: ReviewOutput
  alias Tackle.CLI.TUI.{Highlight, KeyHint, MessageView, Review, ReviewDashboard}
  alias Tackle.CLI.TUI.{ReviewProgress, State, Theme}
  alias Tackle.Review.{Change, Finding, FunctionContext}

  import Tackle.CLI.TUI.ReviewRows

  # Below this width the list and the detail pane are stacked.
  @side_by_side_width 100
  # Lines of code shown around a finding's range.
  @excerpt_context 3
  @max_excerpt_lines 40
  @confidence_width 10
  # Columns before a finding's title in the list: marker and badge.
  @list_indent 2 + 7 + 1

  @typedoc "What the body shows."
  @type body :: :empty | :dashboard | :findings | :summary

  @doc "Paints the overlay over the whole screen."
  @spec widgets(State.t()) :: [{struct(), Rect.t()}]
  def widgets(%State{size: {width, height}} = state) do
    screen = %Rect{x: 0, y: 0, width: width, height: height}
    block = Theme.panel_block(" Review ", :accent)
    layout = layout(state)

    content =
      if layout.inner.width > 2 and layout.inner.height > 0 do
        {body, max_scroll} = body(state, layout)

        (header(state, layout) ++ body ++ footer(state, layout, max_scroll))
        |> Enum.filter(fn {_widget, rect} -> visible?(rect) end)
      else
        []
      end

    [{%Clear{}, screen}, {block, screen}] ++ content
  end

  @doc """
  The furthest the current pane can scroll: the detail pane for findings,
  the summary page for the summary. `Tackle.CLI.TUI.Review` clamps its
  scroll to it.
  """
  @spec max_scroll(State.t()) :: non_neg_integer()
  def max_scroll(%State{review: %Review{} = review} = state) do
    layout = layout(state)

    {rows, height} =
      case body_kind(review) do
        :findings ->
          {_list, detail} = panes(layout.body)
          {all_detail_rows(review, detail.width), detail.height}

        :summary ->
          {ReviewDashboard.summary_rows(review, layout.body.width), layout.body.height}

        _other ->
          {[], layout.body.height}
      end

    scroll_limit(length(rows), height)
  end

  def max_scroll(%State{}), do: 0

  # How many of `count` rows fit `height` when the last row may be needed
  # for the scroll indicator: all of them, or all but the indicator's row.
  # A single row has no room for the indicator.
  defp visible_rows(count, height) when count <= height, do: count
  defp visible_rows(_count, height) when height <= 1, do: max(height, 0)
  defp visible_rows(_count, height), do: height - 1

  defp scroll_limit(_count, height) when height <= 0, do: 0
  defp scroll_limit(count, height), do: count - visible_rows(count, height)

  @doc "What the body of the overlay shows for `review`."
  @spec body_kind(Review.t() | nil) :: body()
  def body_kind(nil), do: :empty

  def body_kind(%Review{} = review) do
    findings? = Review.findings(review) != []

    cond do
      review.tab == :summary and (findings? or not Review.running?(review)) -> :summary
      findings? -> :findings
      Review.running?(review) -> :dashboard
      true -> :summary
    end
  end

  # -- layout -------------------------------------------------------------------

  defp layout(%State{size: {width, height}, review: review}) do
    inner = %Rect{x: 1, y: 1, width: max(width - 2, 0), height: max(height - 2, 0)}

    header_rows =
      cond do
        inner.height >= 10 and nav?(review) -> 3
        inner.height >= 10 -> 2
        inner.height >= 5 -> 1
        true -> 0
      end

    footer_rows = if inner.height >= 4, do: 1, else: 0
    body_height = max(inner.height - header_rows - footer_rows, 0)

    %{
      inner: inner,
      header: %{inner | height: header_rows},
      body: %{inner | y: inner.y + header_rows, height: body_height},
      footer: %{inner | y: inner.y + header_rows + body_height, height: footer_rows}
    }
  end

  defp panes(rect) do
    if rect.width >= @side_by_side_width do
      list_width = div(rect.width * 42, 100)
      list = %{rect | width: list_width}
      detail = %{rect | x: rect.x + list_width + 3, width: max(rect.width - list_width - 3, 1)}
      {list, detail}
    else
      list_height = max(div(rect.height * 2, 5), 3) |> min(rect.height)
      list = %{rect | height: list_height}

      detail = %{
        rect
        | y: rect.y + list_height + 1,
          height: max(rect.height - list_height - 1, 0)
      }

      {list, detail}
    end
  end

  defp visible?(%Rect{width: width, height: height}), do: width > 0 and height > 0

  defp text_widget(rows), do: %Paragraph{text: rows, style: Theme.style(:text)}

  # -- header -------------------------------------------------------------------

  defp header(_state, %{header: %Rect{height: 0}}), do: []

  defp header(%State{review: review, spinner_frame: frame}, %{header: rect}) do
    width = rect.width

    first =
      split_row(
        [status_badge(review, frame), span(" ", :text)] ++ target_spans(review),
        timing_spans(review),
        width
      )

    nav =
      if rect.height >= 3,
        do: [split_row(nav_spans(review, frame), severity_spans(review), width)],
        else: []

    rule = if rect.height >= 2, do: [muted_row(String.duplicate("─", width))], else: []
    rows = [first | nav] ++ rule

    [{text_widget(Enum.map(rows, &fit(&1, width))), rect}]
  end

  defp status_badge(nil, _frame), do: badge("REVIEW", :accent)

  defp status_badge(%Review{status: :loading}, frame),
    do: badge(glyph(:running, frame) <> " LOADING", :accent)

  defp status_badge(%Review{status: :running, mode: :rereview}, frame),
    do: badge(glyph(:running, frame) <> " RE-REVIEWING", :accent)

  defp status_badge(%Review{status: :running}, frame),
    do: badge(glyph(:running, frame) <> " REVIEWING", :accent)

  defp status_badge(%Review{status: :cancelling}, _frame), do: badge("CANCELLING", :warning)
  defp status_badge(%Review{status: :failed}, _frame), do: badge("✗ FAILED", :error)
  defp status_badge(%Review{status: :cancelled}, _frame), do: badge("CANCELLED", :muted)

  defp status_badge(%Review{blocking: [_ | _] = blocking}, _frame),
    do: badge("✗ #{length(blocking)} BLOCKING", :error)

  defp status_badge(%Review{optional: [_ | _] = optional}, _frame),
    do: badge("● #{length(optional)} OPTIONAL", :warning)

  defp status_badge(%Review{}, _frame), do: badge("✓ CLEAN", :success)

  defp target_spans(nil), do: [span("No review in this session", :muted)]

  defp target_spans(%Review{} = review) do
    [span(describe_target(review), bold(:text))] ++ diff_stat_spans(review.change)
  end

  defp describe_target(%Review{target: %{staged: true}}), do: "staged changes"
  defp describe_target(%Review{target: %{range: range}}) when is_binary(range), do: range

  defp describe_target(%Review{change: %Change{base_ref: base}}) when is_binary(base),
    do: "changes since #{base}"

  defp describe_target(%Review{}), do: "branch changes"

  defp diff_stat_spans(%Change{diff: %{files: files}}) do
    additions = files |> Enum.map(&Map.get(&1, :additions, 0)) |> Enum.sum()
    deletions = files |> Enum.map(&Map.get(&1, :deletions, 0)) |> Enum.sum()

    [
      span("  " <> plural(length(files), "file"), :muted),
      span(" +#{additions}", :success),
      span(" −#{deletions}", :error)
    ]
  end

  defp diff_stat_spans(_change), do: []

  defp timing_spans(%Review{started_at: started_at} = review) when is_integer(started_at) do
    if Review.running?(review) do
      elapsed = System.monotonic_time(:millisecond) - started_at
      progress = if Review.findings(review) != [], do: rereview_progress(review), else: []
      progress ++ [span("⏱ " <> clock(max(elapsed, 0)), :subtle)]
    else
      finished_spans(review)
    end
  end

  defp timing_spans(%Review{} = review), do: finished_spans(review)
  defp timing_spans(nil), do: []

  defp finished_spans(%Review{summary: summary}) when is_map(summary) do
    case ReviewOutput.cost_summary(summary) do
      nil -> []
      cost -> [span(cost, :subtle)]
    end
  end

  defp finished_spans(_review), do: []

  # A re-review keeps its findings on screen, so its progress rides in the
  # header instead of the dashboard.
  defp rereview_progress(%Review{status: :loading}), do: [span("loading  ", :muted)]

  defp rereview_progress(%Review{progress: progress} = review) do
    counts = ReviewProgress.counts(progress)
    files = plural(length(review.touched || []), "file")

    units =
      if counts.total, do: " · #{counts.done + counts.failed}/#{counts.total} units", else: ""

    [span("#{files}#{units}  ", :muted)]
  end

  # Whether the header has a second row: the tabs, or the stepper.
  defp nav?(review), do: nav_spans(review, 0) != []

  defp nav_spans(nil, _frame), do: []

  defp nav_spans(%Review{} = review, frame) do
    case body_kind(review) do
      :dashboard ->
        ReviewDashboard.stepper(review.status, review.progress, frame)

      kind ->
        if Review.findings(review) != [] do
          count = length(Review.findings(review))

          [
            tab("Findings #{count}", kind == :findings),
            span(" ", :text),
            tab("Summary", kind == :summary)
          ]
        else
          []
        end
    end
  end

  defp tab(label, true), do: span(" #{label} ", Theme.bold(Theme.style(:selection_surface)))
  defp tab(label, false), do: span(" #{label} ", :muted)

  defp severity_spans(nil), do: []

  defp severity_spans(%Review{} = review) do
    counts = review |> Review.findings() |> Enum.frequencies_by(& &1.severity)

    severities()
    |> Enum.filter(&Map.has_key?(counts, &1))
    |> Enum.map(fn severity ->
      [span("● ", severity_tone(severity)), span("#{counts[severity]} #{severity}", :muted)]
    end)
    |> Enum.intersperse([span("  ", :text)])
    |> Enum.concat()
  end

  # -- footer -------------------------------------------------------------------

  defp footer(_state, %{footer: %Rect{height: 0}}, _max_scroll), do: []

  defp footer(%State{notice: notice}, %{footer: rect}, _max_scroll) when is_binary(notice) do
    row = MessageView.row([span("● ", :accent), span(notice, :text)])
    [{text_widget([fit(row, rect.width)]), rect}]
  end

  defp footer(%State{} = state, %{footer: rect}, max_scroll) do
    hints = state.review |> hints(max_scroll > 0) |> fitting_hints(rect.width)
    [{text_widget([MessageView.row(KeyHint.row_spans(hints))]), rect}]
  end

  @doc """
  The key hints for `review`, as `{priority, hint}` pairs in display
  order; a lower priority survives a narrower screen. `scrollable?` says
  whether the shown pane can scroll.
  """
  @spec hints(Review.t() | nil, boolean()) :: [{non_neg_integer(), KeyHint.hint()}]
  def hints(nil, _scrollable?), do: [{0, {"Esc", "close"}}]

  def hints(%Review{} = review, scrollable?) do
    running? = Review.running?(review)
    scroll = if scrollable?, do: [{4, {"PgUp/PgDn", "scroll"}}], else: []
    cancel = if running?, do: [{1, {"x", "cancel"}}], else: []

    case body_kind(review) do
      :dashboard ->
        [{1, {"x", "cancel"}}, {0, {"Esc", "close (keeps running)"}}]

      :findings ->
        [
          {0, {"↑↓", "select"}}
        ] ++
          scroll ++
          [
            {2, {"Tab", "summary"}},
            {1, {"f", "fix"}},
            {3, {"F", "fix blocking"}},
            {5, {"u/n", "useful/not"}},
            {5, {"d", "dismiss"}}
          ] ++
          rereview_hint(review) ++
          cancel ++
          [{0, {"Esc", "close"}}]

      :summary ->
        tab = if Review.findings(review) != [], do: [{1, {"Tab", "findings"}}], else: []

        tab ++
          scroll ++
          rereview_hint(review) ++
          cancel ++
          [{0, {"Esc", "close"}}]
    end
  end

  # `r` is offered only once a review finished; a cancelled or failed one
  # never reviewed its change.
  defp rereview_hint(review),
    do: if(Review.rereviewable?(review), do: [{2, {"r", "re-review"}}], else: [])

  defp fitting_hints(prioritized, width) do
    levels = prioritized |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort(:desc)

    candidates =
      Enum.map(levels, fn level ->
        for {priority, hint} <- prioritized, priority <= level, do: hint
      end) ++ [[]]

    KeyHint.first_fitting(candidates, width)
  end

  # -- body ---------------------------------------------------------------------

  # The body's widgets, and how far its scrolling pane can scroll.
  defp body(%State{review: review} = state, %{body: rect}) do
    case body_kind(review) do
      :empty ->
        {[{text_widget([muted_row("Start one with /review [RANGE | --staged].")]), rect}], 0}

      :dashboard ->
        {ReviewDashboard.widgets(review, rect, state.spinner_frame), 0}

      :summary ->
        rows = ReviewDashboard.summary_rows(review, rect.width)

        {[{text_widget(window(rows, review.scroll, rect.height, rect.width)), rect}],
         scroll_limit(length(rows), rect.height)}

      :findings ->
        findings_panes(review, rect)
    end
  end

  defp findings_panes(review, rect) do
    {list, detail} = panes(rect)
    rows = all_detail_rows(review, detail.width)

    separator =
      if rect.width >= @side_by_side_width do
        rule = %{rect | x: rect.x + list.width + 1, width: 1}
        {text_widget(List.duplicate(muted_row("│"), rect.height)), rule}
      else
        rule = %{rect | y: rect.y + list.height, height: min(1, rect.height - list.height)}
        {text_widget([muted_row(String.duplicate("─", rect.width))]), rule}
      end

    widgets = [
      {text_widget(list_rows(review, list.width, list.height)), list},
      separator,
      {text_widget(window(rows, review.scroll, detail.height, detail.width)), detail}
    ]

    {widgets, scroll_limit(length(rows), detail.height)}
  end

  # Shows the rows from `scroll` that fit `height`. When they do not all
  # fit, the last row says how much is left, or that the end is reached.
  defp window(rows, scroll, height, width) do
    count = length(rows)
    visible = visible_rows(count, height)

    cond do
      height <= 0 ->
        []

      count <= height ->
        rows

      visible == height ->
        rows |> Enum.drop(min(scroll, count - visible)) |> Enum.take(visible)

      true ->
        offset = min(scroll, count - visible)
        below = count - visible - offset

        indicator =
          if below > 0,
            do: "↓ #{plural(below, "more line")} · PgDn",
            else: "↑ end · PgUp scrolls back"

        (rows |> Enum.drop(offset) |> Enum.take(visible)) ++
          [fit(MessageView.row([span(indicator, :subtle)]), width)]
    end
  end

  # -- list ---------------------------------------------------------------------

  @doc false
  @spec list_rows(Review.t(), pos_integer(), non_neg_integer()) :: [MessageView.row()]
  def list_rows(%Review{} = review, width, height) do
    rows =
      group_rows("Blocking", :error, review.blocking, 0, review, width) ++
        group_rows("Optional", :warning, review.optional, length(review.blocking), review, width)

    # Scroll so the selected finding's last row is visible.
    selected = review.selected

    last =
      rows
      |> Enum.with_index()
      |> Enum.reduce(0, fn {{index, _row}, row}, last ->
        if index == selected, do: row, else: last
      end)

    offset = if last < height, do: 0, else: last - height + 1

    rows
    |> Enum.drop(offset)
    |> Enum.take(max(height, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp group_rows(_label, _tone, [], _first, _review, _width), do: []

  defp group_rows(label, tone, findings, first, review, width) do
    spacer = if first > 0, do: [{nil, blank()}], else: []
    count = length(findings)
    title = String.upcase(label)

    rule =
      String.duplicate("─", max(width - String.length(title) - String.length("#{count}") - 3, 0))

    heading =
      MessageView.row([span(title, bold(tone)), span(" #{count} ", :muted), span(rule, :subtle)])

    entries =
      findings
      |> Enum.with_index(first)
      |> Enum.flat_map(fn {finding, index} ->
        Enum.map(finding_entry(finding, index, review, width), &{index, &1})
      end)

    spacer ++ [{nil, fit(heading, width)} | entries]
  end

  defp finding_entry(%Finding{} = finding, index, review, width) do
    selected? = index == review.selected
    outcome = Map.get(review.outcomes, finding.fingerprint)
    marker = if selected?, do: span("▌ ", :accent), else: span("  ", :text)

    title_style =
      cond do
        outcome == :dismissed -> %{Theme.style(:muted) | modifiers: [:crossed_out]}
        selected? -> bold(:text)
        true -> Theme.style(:text)
      end

    meta =
      [ReviewOutput.location(finding.location), to_string(finding.category), finding.rule_id]
      |> Enum.reject(&is_nil/1)

    [location | details] = meta

    first =
      MessageView.row(
        [marker, severity_badge(finding.severity), span(" " <> finding.title, title_style)] ++
          outcome_spans(outcome)
      )

    second =
      MessageView.row([
        marker,
        span(String.duplicate(" ", @list_indent - 2), :text),
        span(location, :accent_soft),
        span(Enum.map_join(details, "", &("  " <> &1)), :subtle)
      ])

    rows = Enum.map([first, second], &fit(&1, width))

    if selected?,
      do: Enum.map(rows, &pad(%{&1 | style: Theme.style(:selection_surface)}, width)),
      else: rows
  end

  defp outcome_spans(nil), do: []
  defp outcome_spans(:useful), do: [span("  ✓ useful", :success)]
  defp outcome_spans(:not_useful), do: [span("  ✗ not useful", :warning)]
  defp outcome_spans(:dismissed), do: [span("  dismissed", :muted)]
  defp outcome_spans(:fixed), do: [span("  ⚒ fix requested", :accent_soft)]

  # -- detail -------------------------------------------------------------------

  @doc false
  @spec detail_rows(Review.t(), pos_integer(), non_neg_integer()) :: [MessageView.row()]
  def detail_rows(%Review{} = review, width, height),
    do: review |> all_detail_rows(width) |> window(review.scroll, height, width)

  defp all_detail_rows(review, width) do
    case Review.selected(review) do
      nil -> []
      finding -> MessageView.wrap_rows(finding_rows(finding, review, width), max(width, 1))
    end
  end

  defp finding_rows(%Finding{} = finding, review, width) do
    position = "#{review.selected + 1}/#{length(Review.findings(review))}"

    [
      split_row(
        [severity_badge(finding.severity), span(" " <> facts(finding), :muted)],
        [span(position, :subtle)],
        width
      ),
      blank(),
      MessageView.row([span(finding.title, bold(:text))]),
      MessageView.row(
        [span(ReviewOutput.location(finding.location), :accent_soft)] ++
          if(finding.rule_id, do: [span("  rule " <> finding.rule_id, :subtle)], else: [])
      ),
      confidence_row(finding)
    ] ++
      feedback_rows(Map.get(review.outcomes, finding.fingerprint)) ++
      section("Why", text_rows(finding.body), width) ++
      section("Trigger", text_rows(finding.trigger), width) ++
      section("Suggested fix", suggestion_rows(finding, width), width) ++
      section(code_heading(finding), code_rows(review.change, finding), width)
  end

  defp facts(%Finding{} = finding) do
    verdict =
      case finding.verdict do
        :confirmed -> "✓ confirmed"
        :uncertain -> "? unverified"
        nil -> nil
      end

    [
      to_string(finding.category),
      if(finding.blocking, do: "blocking", else: "optional"),
      verdict,
      if(finding.support > 1, do: "seen #{finding.support}×")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp confidence_row(%Finding{confidence: confidence}) do
    value = round(confidence * 100)

    tone =
      cond do
        value >= 75 -> :success
        value >= 50 -> :warning
        true -> :error
      end

    MessageView.row(
      [span("confidence ", :muted)] ++
        bar(value, 100, @confidence_width, tone) ++ [span(" #{value}%", :muted)]
    )
  end

  defp feedback_rows(nil), do: []

  defp feedback_rows(outcome),
    do: [MessageView.row([span("feedback ", :muted) | outcome_spans(outcome) |> trim_first()])]

  defp trim_first([first | rest]),
    do: [%{first | content: String.trim_leading(first.content)} | rest]

  defp code_heading(%Finding{location: %{path: path}}), do: "Code · " <> Path.basename(path)

  defp section(_heading, [], _width), do: []
  defp section(heading, rows, width), do: [blank(), heading(heading, width) | rows]

  defp text_rows(nil), do: []

  defp text_rows(text) do
    text
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&MessageView.row([span(&1, :text)]))
  end

  defp suggestion_rows(%Finding{suggestion: nil}, _width), do: []

  defp suggestion_rows(%Finding{suggestion: suggestion, location: location}, width) do
    tokens = Highlight.lines(suggestion, location.path)
    surface = Theme.style(:code_surface)

    suggestion
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} ->
      MessageView.row([span(" ", surface) | code_spans(line, number, tokens)], surface)
      |> pad(width)
    end)
  end

  defp code_rows(nil, _finding), do: []

  defp code_rows(%Change{} = change, %Finding{location: location}) do
    lines = excerpt(change, location)
    tokens = lines |> Enum.map_join("\n", & &1.text) |> Highlight.lines(location.path)
    width = lines |> Enum.map(&number(&1, location.side)) |> Enum.max(fn -> 0 end) |> digits()

    lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, index} -> code_row(line, index, tokens, location, width) end)
  end

  @doc """
  The diff lines around `location` in `change`, for the detail pane.

  Lines come from the file's hunks expanded to their functions
  (`Tackle.Review.FunctionContext.regions/1`), from #{@excerpt_context}
  lines before the range to #{@excerpt_context} after it on the location's
  side, with the other side's
  lines in between kept so a range over a replacement shows both. At most
  #{@max_excerpt_lines} lines are returned.
  """
  @spec excerpt(Change.t(), Finding.location()) :: [Tackle.Review.Diff.line()]
  def excerpt(%Change{} = change, %{path: path, side: side} = location) do
    file = Enum.find(change.diff.files, &(&1.path == path))
    lines = if file, do: file |> FunctionContext.regions() |> Enum.concat(), else: []
    first = location.start_line - @excerpt_context
    last = location.end_line + @excerpt_context

    indices =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _index} ->
        number = Map.get(line, side)
        is_integer(number) and number >= first and number <= last
      end)
      |> Enum.map(&elem(&1, 1))

    case indices do
      [] ->
        []

      indices ->
        lines |> Enum.slice(Enum.min(indices)..Enum.max(indices)) |> Enum.take(@max_excerpt_lines)
    end
  end

  defp code_row(line, index, tokens, location, width) do
    number = number(line, location.side)
    marked? = in_range?(line, location)
    tag = tag(line.kind)

    gutter =
      if number,
        do: String.pad_leading(to_string(number), width),
        else: String.duplicate(" ", width)

    MessageView.row(
      [
        span(if(marked?, do: "▌", else: " "), :accent),
        span(gutter <> " ", gutter_style(tag)),
        span(sign(tag) <> " ", diff_style(tag))
        | code_spans(line.text, index, tokens)
      ],
      fill_style(tag)
    )
  end

  defp number(line, side), do: Map.get(line, side) || line.new || line.old

  defp in_range?(line, %{side: side, start_line: first, end_line: last}) do
    number = Map.get(line, side)
    is_integer(number) and number >= first and number <= last
  end

  defp code_spans(text, number, tokens) do
    case Map.get(tokens, number) do
      nil -> [span(text, :text)]
      runs -> Enum.map(runs, fn {run, style} -> span(run, style || Theme.style(:text)) end)
    end
  end

  defp tag(:add), do: :ins
  defp tag(:remove), do: :del
  defp tag(:context), do: :ctx

  defp sign(:ins), do: "+"
  defp sign(:del), do: "-"
  defp sign(:ctx), do: " "

  defp fill_style(:ins), do: Theme.style(:diff_add_bg)
  defp fill_style(:del), do: Theme.style(:diff_del_bg)
  defp fill_style(:ctx), do: %Style{}

  defp gutter_style(:ins), do: Theme.style(:diff_add_gutter)
  defp gutter_style(:del), do: Theme.style(:diff_del_gutter)
  defp gutter_style(:ctx), do: Theme.style(:subtle)

  defp diff_style(:ins), do: Theme.style(:diff_add)
  defp diff_style(:del), do: Theme.style(:diff_del)
  defp diff_style(:ctx), do: Theme.style(:diff_context)

  defp digits(number), do: number |> to_string() |> String.length() |> max(1)
end
