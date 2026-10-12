defmodule Tackle.CLI.TUI.ReviewView do
  @moduledoc """
  Draws the `/review` overlay over the whole screen.

  While the review runs it shows `Tackle.CLI.TUI.ReviewProgress` as a short
  flow: the units being reviewed, then the candidates waiting for or
  carrying a verdict. Once findings exist the overlay splits into a list
  (grouped into blocking and optional, each row `severity · path:line ·
  title · rule`, with the feedback given so far) and a detail pane for the
  selected finding: its explanation, trigger, suggestion, and the code it
  points at, cut from the change's function-context diff and highlighted
  with `Tackle.CLI.TUI.Highlight`. Wide terminals put the panes side by
  side; narrow ones stack them.

  Every row is clipped to its pane, so the overlay never wraps outside its
  frame. The bottom border carries the key hints, or the latest notice.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Clear, Paragraph}
  alias ExRatatui.Widgets.Block.Title
  alias Tackle.CLI.Output.Review, as: ReviewOutput
  alias Tackle.CLI.TUI.{Highlight, MessageView, Review, ReviewProgress, State, Theme}
  alias Tackle.Review.{Change, Finding}

  # Below this width the list and the detail pane are stacked.
  @side_by_side_width 100
  # Lines of code shown around a finding's range.
  @excerpt_context 3
  @max_excerpt_lines 40
  @severity_width 7

  @doc "Paints the overlay over the whole screen."
  @spec widgets(State.t()) :: [{struct(), Rect.t()}]
  def widgets(%State{size: {width, height}} = state) do
    screen = %Rect{x: 0, y: 0, width: width, height: height}
    review = state.review

    block = %{
      Theme.panel_block(title(review), :accent)
      | titles: [%Title{content: hints(state), position: :bottom, style: Theme.style(:subtle)}]
    }

    inner = %Rect{
      x: 1,
      y: 1,
      width: max(width - 2, 0),
      height: max(height - 2, 0)
    }

    content =
      if inner.width > 2 and inner.height > 0,
        do: Enum.filter(body(review, inner), fn {_widget, rect} -> visible?(rect) end),
        else: []

    [{%Clear{}, screen}, {block, screen}] ++ content
  end

  # -- chrome -----------------------------------------------------------------

  defp title(nil), do: " Review "

  defp title(%Review{} = review) do
    parts = ["Review", describe_target(review), status_text(review)]
    " " <> Enum.join(Enum.reject(parts, &(&1 in [nil, ""])), " · ") <> " "
  end

  defp describe_target(%Review{target: %{staged: true}}), do: "staged changes"
  defp describe_target(%Review{target: %{range: range}}) when is_binary(range), do: range

  defp describe_target(%Review{change: %Change{base_ref: base}}) when is_binary(base),
    do: "changes since #{base}"

  defp describe_target(%Review{}), do: "branch changes"

  defp status_text(%Review{status: :loading}), do: "loading the change"
  defp status_text(%Review{status: :cancelling}), do: "cancelling"
  defp status_text(%Review{status: :running, mode: :rereview}), do: "re-reviewing"
  defp status_text(%Review{status: :running}), do: "reviewing"
  defp status_text(%Review{status: :failed}), do: "failed"
  defp status_text(%Review{status: :cancelled}), do: "cancelled"

  defp status_text(%Review{} = review),
    do: "#{length(review.blocking)} blocking · #{length(review.optional)} optional"

  defp hints(%State{notice: notice}) when is_binary(notice), do: " #{notice} · Esc close "
  defp hints(%State{review: nil}), do: " Esc close "

  defp hints(%State{review: review}) do
    cond do
      Review.running?(review) and Review.findings(review) == [] ->
        " x cancel · Esc close (keeps running) "

      Review.running?(review) ->
        " ↑/↓ select · u/n useful · d dismiss · x cancel · Esc close "

      Review.findings(review) == [] ->
        " #{rereview_hint(review)}Esc close "

      true ->
        " ↑/↓ select · PgUp/PgDn detail · u/n useful/not · d dismiss · f fix · " <>
          "F fix blocking · #{rereview_hint(review)}Esc close "
    end
  end

  # `r` is offered only once a review finished; a cancelled or failed one
  # never reviewed its change.
  defp rereview_hint(review),
    do: if(Review.rereviewable?(review), do: "r re-review · ", else: "")

  # -- body -------------------------------------------------------------------

  defp body(nil, rect), do: [{text_widget([muted_row("No review in this session.")]), rect}]

  defp body(%Review{} = review, rect) do
    findings = Review.findings(review)

    cond do
      findings != [] and Review.running?(review) ->
        {status, rest} = split_top(rect, 1)
        [{text_widget(progress_line(review, status.width)), status} | panes(review, rest)]

      findings != [] ->
        panes(review, rect)

      Review.running?(review) ->
        [{text_widget(progress_rows(review, rect.width, rect.height)), rect}]

      true ->
        [{text_widget(outcome_rows(review, rect.width)), rect}]
    end
  end

  defp split_top(rect, rows) do
    rows = min(rows, rect.height)

    {%{rect | height: rows}, %{rect | y: rect.y + rows, height: max(rect.height - rows, 0)}}
  end

  defp panes(review, rect) do
    if rect.width >= @side_by_side_width do
      list_width = div(rect.width * 45, 100)
      list = %{rect | width: list_width}
      rule = %{rect | x: rect.x + list_width, width: 1}
      detail = %{rect | x: rect.x + list_width + 2, width: max(rect.width - list_width - 2, 1)}

      [
        {text_widget(list_rows(review, list.width, list.height)), list},
        {text_widget(List.duplicate(muted_row("│"), rect.height)), rule},
        {text_widget(detail_rows(review, detail.width, detail.height)), detail}
      ]
    else
      list_height = max(div(rect.height * 2, 5), 3) |> min(rect.height)
      list = %{rect | height: list_height}
      rule = %{rect | y: rect.y + list_height, height: min(1, rect.height - list_height)}

      detail = %{
        rect
        | y: rect.y + list_height + 1,
          height: max(rect.height - list_height - 1, 0)
      }

      [
        {text_widget(list_rows(review, list.width, list.height)), list},
        {text_widget([muted_row(String.duplicate("─", rect.width))]), rule},
        {text_widget(detail_rows(review, detail.width, detail.height)), detail}
      ]
    end
  end

  defp visible?(%Rect{width: width, height: height}), do: width > 0 and height > 0

  defp text_widget(rows), do: %Paragraph{text: rows, style: Theme.style(:text)}

  # -- progress ---------------------------------------------------------------

  defp progress_line(review, width) do
    counts = ReviewProgress.counts(review.progress)
    files = length(review.touched || [])

    label =
      case review.status do
        :loading -> "Loading the change…"
        :cancelling -> "Cancelling the review…"
        _running -> "Re-reviewing #{plural(files, "changed file")} · #{unit_counts(counts)}"
      end

    [fit(MessageView.row([span("● ", :accent_soft), span(label, :muted)]), width)]
  end

  @doc false
  @spec progress_rows(Review.t(), pos_integer(), non_neg_integer()) :: [MessageView.row()]
  def progress_rows(%Review{} = review, width, height) do
    rows =
      case {review.status, ReviewProgress.phase(review.progress)} do
        {:loading, _phase} ->
          [node_row(:running, "Loading the change from Git…")]

        {_status, :starting} ->
          [node_row(:running, "Splitting the change into review units…")]

        _other ->
          unit_rows(review.progress, height) ++ candidate_rows(review.progress, height)
      end

    rows =
      if review.status == :cancelling,
        do: rows ++ [muted_row(""), node_row(:failed, "Cancelling the review…")],
        else: rows

    (rows ++ note_rows(review.notes))
    |> Enum.take(max(height, 0))
    |> Enum.map(&fit(&1, width))
  end

  defp unit_rows(progress, height) do
    counts = ReviewProgress.counts(progress)
    status = if counts.done + counts.failed < (progress.total || 0), do: :running, else: :done

    head =
      node_row(status, "Detecting", unit_counts(counts) <> failed_suffix(counts.failed))

    # A long list keeps the units that need attention (running or failed)
    # and counts the rest, so a large change stays a handful of rows.
    budget = max(div(height, 2) - 1, 1)

    listed =
      if length(progress.units) <= budget,
        do: progress.units,
        else: progress.units |> Enum.reject(&match?({_id, :done}, &1)) |> Enum.take(budget)

    hidden = length(progress.units) - length(listed)

    rows =
      Enum.map(listed, fn {id, status} ->
        branch_row(unit_glyph(status), unit_label(id, status))
      end) ++
        if(hidden > 0, do: [branch_row(:done, "#{hidden} more")], else: [])

    [head | rows]
  end

  defp candidate_rows(%ReviewProgress{candidates: []}, _height), do: []

  defp candidate_rows(progress, height) do
    counts = ReviewProgress.counts(progress)
    status = if counts.verifying > 0, do: :running, else: :done

    details =
      ["#{counts.candidates - counts.verifying}/#{plural(counts.candidates, "candidate")}"] ++
        Enum.flat_map([confirmed: "confirmed", rejected: "rejected", uncertain: "unverified"], fn
          {key, label} -> if counts[key] > 0, do: ["#{counts[key]} #{label}"], else: []
        end)

    budget = max(div(height, 2) - 2, 1)

    rows =
      progress.candidates
      |> Enum.take(-budget)
      |> Enum.map(fn candidate ->
        branch_row(verdict_glyph(candidate.verdict), candidate_label(candidate))
      end)

    [muted_row(""), node_row(status, "Verifying", Enum.join(details, " · ")) | rows]
  end

  defp unit_counts(%{total: total, done: done, failed: failed}) do
    "#{done + failed}/#{plural(total || 0, "unit")}"
  end

  defp failed_suffix(0), do: ""
  defp failed_suffix(failed), do: " · #{failed} failed"

  defp unit_glyph(:running), do: :running
  defp unit_glyph(:done), do: :done
  defp unit_glyph({:failed, _reason}), do: :failed

  defp unit_label("change", status), do: unit_label("the change overview", status)

  defp unit_label(id, {:failed, reason}),
    do: "#{id}  failed: #{first_line(Tackle.Review.Delegation.format_error(reason))}"

  defp unit_label(id, _status), do: id

  defp verdict_glyph(nil), do: :running
  defp verdict_glyph(:confirmed), do: :done
  defp verdict_glyph(:rejected), do: :failed
  defp verdict_glyph(:uncertain), do: :ended

  defp candidate_label(%{finding: %Finding{} = finding, verdict: verdict}) do
    suffix =
      case verdict do
        :rejected -> "  rejected"
        :uncertain -> "  unverified"
        _other -> ""
      end

    "#{ReviewOutput.location(finding.location)}  #{finding.title}#{suffix}"
  end

  defp candidate_label(%{fingerprint: fingerprint}), do: fingerprint

  defp node_row(status, label, details \\ nil) do
    spans = [span(glyph(status) <> " ", glyph_style(status)), span(label, :text)]
    spans = if details, do: spans ++ [span("  " <> details, :muted)], else: spans
    MessageView.row(spans)
  end

  defp branch_row(status, label) do
    MessageView.row([
      span("  ", :muted),
      span(glyph(status) <> " ", glyph_style(status)),
      span(label, :muted)
    ])
  end

  defp glyph(:done), do: "✓"
  defp glyph(:failed), do: "✗"
  defp glyph(:running), do: "●"
  defp glyph(_ended), do: "◌"

  defp glyph_style(:done), do: :success
  defp glyph_style(:failed), do: :error
  defp glyph_style(:running), do: :accent_soft
  defp glyph_style(_ended), do: :muted

  # -- finished without findings ----------------------------------------------

  defp outcome_rows(%Review{status: status, error: error} = review, width)
       when status in [:failed, :cancelled] do
    ([MessageView.row([span(error || "The review failed.", :error)])] ++ note_rows(review.notes))
    |> Enum.map(&fit(&1, width))
  end

  defp outcome_rows(%Review{} = review, width) do
    headline =
      case review.summary do
        %{units: 0} -> "Nothing to review in this change."
        _summary -> "No findings."
      end

    ([MessageView.row([span(headline, :success)])] ++
       summary_rows(review.summary) ++ note_rows(review.notes))
    |> Enum.map(&fit(&1, width))
  end

  defp summary_rows(%{units: units} = summary) when units > 0 do
    [
      muted_row(""),
      muted_row(
        "Reviewed #{plural(length(summary.files), "file")} in #{plural(units, "unit")} · " <>
          "#{plural(summary.candidates, "candidate")}, #{summary.rejected} rejected"
      )
    ]
  end

  defp summary_rows(_summary), do: []

  defp note_rows([]), do: []

  defp note_rows(notes),
    do:
      [muted_row(""), MessageView.row([span("Notes", :warning)])] ++
        Enum.map(notes, &muted_row("  " <> &1))

  # -- list -------------------------------------------------------------------

  @doc false
  @spec list_rows(Review.t(), pos_integer(), non_neg_integer()) :: [MessageView.row()]
  def list_rows(%Review{} = review, width, height) do
    entries =
      group_entries("Blocking", review.blocking, 0) ++
        group_entries("Optional", review.optional, length(review.blocking))

    selected = review.selected
    selected_row = Enum.find_index(entries, &match?({:finding, ^selected, _finding}, &1)) || 0
    offset = if selected_row < height, do: 0, else: selected_row - height + 1

    entries
    |> Enum.drop(offset)
    |> Enum.take(max(height, 0))
    |> Enum.map(&entry_row(&1, review, width))
  end

  defp group_entries(_label, [], _first), do: []

  defp group_entries(label, findings, first) do
    rows =
      findings
      |> Enum.with_index(first)
      |> Enum.map(fn {finding, index} -> {:finding, index, finding} end)

    [{:heading, "#{label} (#{length(findings)})"} | rows]
  end

  defp entry_row({:heading, text}, _review, width),
    do: fit(MessageView.row([span(text, Theme.bold(Theme.style(:accent_soft)))]), width)

  defp entry_row({:finding, index, finding}, review, width) do
    selected? = index == review.selected
    outcome = Map.get(review.outcomes, finding.fingerprint)

    spans =
      [
        span(if(selected?, do: "› ", else: "  "), :accent),
        span(severity_label(finding.severity), severity_style(finding.severity)),
        span(ReviewOutput.location(finding.location) <> "  ", :accent_soft),
        span(finding.title, if(outcome == :dismissed, do: :muted, else: :text))
      ] ++
        if(finding.rule_id, do: [span("  " <> finding.rule_id, :subtle)], else: []) ++
        outcome_spans(outcome)

    row = fit(MessageView.row(spans), width)

    if selected?,
      do: pad(%{row | style: Theme.style(:selection_surface)}, width),
      else: row
  end

  defp outcome_spans(nil), do: []
  defp outcome_spans(:useful), do: [span("  ✓ useful", :success)]
  defp outcome_spans(:not_useful), do: [span("  ✗ not useful", :warning)]
  defp outcome_spans(:dismissed), do: [span("  dismissed", :muted)]
  defp outcome_spans(:fixed), do: [span("  fix requested", :accent_soft)]

  defp severity_label(severity),
    do: severity |> to_string() |> String.upcase() |> String.pad_trailing(@severity_width)

  defp severity_style(severity) when severity in [:blocker, :high], do: :error
  defp severity_style(:medium), do: :warning
  defp severity_style(_severity), do: :muted

  # -- detail -----------------------------------------------------------------

  @doc false
  @spec detail_rows(Review.t(), pos_integer(), non_neg_integer()) :: [MessageView.row()]
  def detail_rows(%Review{} = review, width, height) do
    case Review.selected(review) do
      nil ->
        []

      finding ->
        rows = MessageView.wrap_rows(finding_rows(finding, review.change), max(width, 1))
        last = max(length(rows) - height, 0)

        rows
        |> Enum.drop(min(review.scroll, last))
        |> Enum.take(max(height, 0))
    end
  end

  defp finding_rows(%Finding{} = finding, change) do
    verdict =
      case finding.verdict do
        :confirmed -> "confirmed"
        :uncertain -> "unverified"
        nil -> nil
      end

    facts =
      [
        to_string(finding.severity),
        to_string(finding.category),
        finding.rule_id && "rule #{finding.rule_id}",
        if(finding.blocking, do: "blocking", else: "optional"),
        verdict,
        "confidence #{:erlang.float_to_binary(finding.confidence / 1, decimals: 2)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    [
      MessageView.row([span(finding.title, Theme.bold(Theme.style(:text)))]),
      MessageView.row([span(facts, :muted)]),
      MessageView.row([span(ReviewOutput.location(finding.location), :accent_soft)]),
      muted_row("")
    ] ++
      text_rows(finding.body, :text) ++
      section("Trigger", text_rows(finding.trigger, :text)) ++
      section("Suggestion", suggestion_rows(finding)) ++
      section("Code", code_rows(change, finding))
  end

  defp section(_heading, []), do: []

  defp section(heading, rows),
    do:
      [muted_row(""), MessageView.row([span(heading, Theme.bold(Theme.style(:accent_soft)))])] ++
        rows

  defp text_rows(text, style) do
    text
    |> String.split("\n")
    |> Enum.map(&MessageView.row([span(&1, style)]))
  end

  defp suggestion_rows(%Finding{suggestion: nil}), do: []

  defp suggestion_rows(%Finding{suggestion: suggestion, location: location}) do
    tokens = Highlight.lines(suggestion, location.path)

    suggestion
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} -> MessageView.row(code_spans(line, number, tokens)) end)
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

  Lines come from the function-context diff when it has the file (falling
  back to the plain diff), from #{@excerpt_context} lines before the range to
  #{@excerpt_context} after it on the location's side, with the other side's
  lines in between kept so a range over a replacement shows both. At most
  #{@max_excerpt_lines} lines are returned.
  """
  @spec excerpt(Change.t(), Finding.location()) :: [Tackle.Review.Diff.line()]
  def excerpt(%Change{} = change, %{path: path, side: side} = location) do
    file =
      Enum.find(change.context_diff.files, &(&1.path == path)) ||
        Enum.find(change.diff.files, &(&1.path == path))

    lines = if file, do: Enum.flat_map(file.hunks, & &1.lines), else: []
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

  # -- helpers ----------------------------------------------------------------

  defp muted_row(text), do: MessageView.row([span(text, :muted)])

  defp span(text, style) when is_atom(style), do: MessageView.span(text, Theme.style(style))
  defp span(text, %Style{} = style), do: MessageView.span(text, style)

  # Clips a row to `width` cells, ending a cut row with an ellipsis.
  defp fit(%{spans: spans} = row, width) do
    if spans |> Enum.map(&MessageView.display_width(&1.content)) |> Enum.sum() <= width do
      row
    else
      {kept, _used} =
        Enum.reduce_while(spans, {[], 0}, fn span, {kept, used} ->
          room = width - 1 - used
          size = MessageView.display_width(span.content)

          cond do
            room <= 0 -> {:halt, {kept, used}}
            size <= room -> {:cont, {[span | kept], used + size}}
            true -> {:halt, {[%{span | content: clip(span.content, room)} | kept], width - 1}}
          end
        end)

      %{row | spans: Enum.reverse(kept) ++ [MessageView.span("…", Theme.style(:subtle))]}
    end
  end

  defp clip(text, room) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, used} ->
      size = MessageView.display_width(grapheme)

      if used + size <= room,
        do: {:cont, {acc <> grapheme, used + size}},
        else: {:halt, {acc, used}}
    end)
    |> elem(0)
  end

  # Pads a row to the full width so its surface style paints the whole line.
  defp pad(%{spans: spans} = row, width) do
    used = spans |> Enum.map(&MessageView.display_width(&1.content)) |> Enum.sum()

    if used < width,
      do: %{row | spans: spans ++ [MessageView.span(String.duplicate(" ", width - used))]},
      else: row
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"
end
