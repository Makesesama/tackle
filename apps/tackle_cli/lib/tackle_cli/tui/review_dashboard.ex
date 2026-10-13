defmodule Tackle.CLI.TUI.ReviewDashboard do
  @moduledoc """
  The `/review` overlay's live dashboard and its summary page.

  While a review runs without findings to show, `widgets/3` draws the
  pipeline as a stepper (load, detect, verify, rank), a progress bar for
  the units and one for the verified candidates, then the units (running
  ones animated) beside a live feed of the candidates and their verdicts.
  Narrow panes stack the two lists.

  `summary_rows/3` is the summary page: the outcome, the verification
  funnel as bars, the changed files with their diff size and findings, the
  per-stage cost, and the notes. It is the body of a review that ended
  without findings and the `Summary` tab of one that has them.

  Everything is built from `Tackle.CLI.TUI.ReviewProgress` and the
  review's summary; nothing here changes state.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias Tackle.CLI.Output.Review, as: ReviewOutput
  alias Tackle.CLI.TUI.{MessageView, Review, ReviewProgress, Theme}
  alias Tackle.Review.Change

  import Tackle.CLI.TUI.ReviewRows

  # Below this width the units and candidates are stacked.
  @columns_width 90
  @bar_width 24

  # -- live progress ------------------------------------------------------------

  @doc "Draws the running review's dashboard into `rect`; `frame` animates spinners."
  @spec widgets(Review.t(), Rect.t(), non_neg_integer()) :: [{struct(), Rect.t()}]
  def widgets(%Review{} = review, %Rect{} = rect, frame) do
    top = top_rows(review, rect.width, frame)
    top_height = min(length(top), rect.height)
    rest = %{rect | y: rect.y + top_height, height: max(rect.height - top_height, 0)}

    [{paragraph(top), %{rect | height: top_height}} | lists(review, rest, frame)]
  end

  defp top_rows(review, width, frame) do
    rows =
      case {review.status, ReviewProgress.phase(review.progress)} do
        {:loading, _phase} ->
          [MessageView.row([glyph_span(:running, frame), span("Loading the change…", :text)])]

        {_status, :starting} ->
          [
            MessageView.row([
              glyph_span(:running, frame),
              span("Splitting the change into review units…", :text)
            ])
          ]

        _other ->
          progress_rows(review.progress, width)
      end

    cancelling =
      if review.status == :cancelling,
        do: [
          blank(),
          MessageView.row([glyph_span(:failed, frame), span("Cancelling the review…", :warning)])
        ],
        else: []

    notes = Enum.map(review.notes, &MessageView.row([span("! ", :warning), span(&1, :muted)]))
    notes = if notes == [], do: [], else: [blank() | notes]

    (rows ++ cancelling ++ notes ++ [blank()]) |> Enum.map(&fit(&1, width))
  end

  @doc """
  Two rows of progress: the settled units and the verified candidates,
  each with a bar and its counts.
  """
  @spec progress_rows(ReviewProgress.t(), non_neg_integer()) :: [MessageView.row()]
  def progress_rows(%ReviewProgress{} = progress, width) do
    counts = ReviewProgress.counts(progress)
    total = counts.total || 0
    settled = counts.done + counts.failed
    bar_width = min(@bar_width, max(width - 40, 6))

    units =
      MessageView.row(
        [span(String.pad_trailing("Detecting", 11), :text)] ++
          bar(settled, total, bar_width, if(counts.failed > 0, do: :warning, else: :accent)) ++
          [
            span("  #{settled}/#{plural(total, "unit")}", :text),
            span(failed_suffix(counts.failed), :error)
          ]
      )

    verified = counts.candidates - counts.verifying

    candidates =
      MessageView.row(
        [span(String.pad_trailing("Verifying", 11), :text)] ++
          bar(verified, counts.candidates, bar_width, :success) ++
          [span("  #{verified}/#{plural(counts.candidates, "candidate")}", :text)] ++
          verdict_counts(counts)
      )

    [units, candidates]
  end

  defp failed_suffix(0), do: ""
  defp failed_suffix(failed), do: " · #{failed} failed"

  defp verdict_counts(counts) do
    [
      confirmed: {"confirmed", :success},
      uncertain: {"unverified", :warning},
      rejected: {"rejected", :muted}
    ]
    |> Enum.flat_map(fn {key, {label, tone}} ->
      if counts[key] > 0,
        do: [span(" · ", :subtle), span("#{counts[key]} #{label}", tone)],
        else: []
    end)
  end

  @doc """
  The pipeline as one row of steps: `✓ Load ── ⠋ Detect 2/4 ── ◌ Verify ── ◌ Rank`.

  `status` is the review's: `:loading` before the change is loaded, `:done`
  once every step finished, anything else while the events say where the
  review is.
  """
  @spec stepper(Review.status(), ReviewProgress.t(), non_neg_integer() | nil) ::
          [ExRatatui.Span.t()]
  def stepper(status, %ReviewProgress{} = progress, frame) do
    counts = ReviewProgress.counts(progress)

    status
    |> steps(progress, counts)
    |> Enum.map(fn {label, status, detail} ->
      tone = if status == :pending, do: :subtle, else: :text
      detail = if detail, do: [span(" " <> detail, :muted)], else: []
      [glyph_span(status, frame), span(label, tone) | detail]
    end)
    |> Enum.intersperse([span(" ── ", :subtle)])
    |> Enum.concat()
  end

  defp steps(:loading, _progress, _counts),
    do: [
      {"Load", :running, nil},
      {"Detect", :pending, nil},
      {"Verify", :pending, nil},
      {"Rank", :pending, nil}
    ]

  defp steps(:done, _progress, counts) do
    units = if counts.total, do: "#{counts.done + counts.failed}/#{counts.total}"
    verified = if counts.candidates > 0, do: "#{counts.candidates}/#{counts.candidates}"

    [
      {"Load", :done, nil},
      {"Detect", :done, units},
      {"Verify", :done, verified},
      {"Rank", :done, nil}
    ]
  end

  defp steps(_status, progress, counts) do
    phase = ReviewProgress.phase(progress)
    units = if counts.total, do: "#{counts.done + counts.failed}/#{counts.total}"
    verified = "#{counts.candidates - counts.verifying}/#{counts.candidates}"

    detect = if phase in [:starting, :detecting], do: :running, else: :done

    verify =
      cond do
        counts.verifying > 0 -> :running
        phase == :ranking -> :done
        true -> :pending
      end

    rank = if phase == :ranking, do: :running, else: :pending

    [
      {"Load", :done, nil},
      {"Detect", detect, units},
      {"Verify", verify, if(counts.candidates > 0, do: verified)},
      {"Rank", rank, nil}
    ]
  end

  defp lists(review, rect, frame) do
    cond do
      rect.height <= 0 ->
        []

      rect.width >= @columns_width ->
        left_width = div(rect.width * 2, 5)
        left = %{rect | width: left_width}
        rule = %{rect | x: rect.x + left_width, width: 1}
        right = %{rect | x: rect.x + left_width + 2, width: max(rect.width - left_width - 2, 1)}

        [
          {paragraph(unit_rows(review.progress, left.width, left.height, frame)), left},
          {paragraph(List.duplicate(muted_row("│"), rect.height)), rule},
          {paragraph(candidate_rows(review.progress, right.width, right.height, frame)), right}
        ]

      true ->
        half = max(div(rect.height, 2), 1)
        units = unit_rows(review.progress, rect.width, half, frame)

        candidates =
          candidate_rows(review.progress, rect.width, rect.height - length(units), frame)

        [{paragraph(units ++ candidates), rect}]
    end
  end

  @doc false
  @spec unit_rows(ReviewProgress.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          [MessageView.row()]
  def unit_rows(%ReviewProgress{units: []}, _width, _height, _frame), do: []

  def unit_rows(%ReviewProgress{} = progress, width, height, frame) do
    counts = ReviewProgress.counts(progress)
    queued = max((counts.total || 0) - length(progress.units), 0)
    budget = max(height - 2, 1)

    # A long list keeps the units that need attention (running or failed)
    # and the latest finished ones, and counts the rest.
    listed =
      if length(progress.units) <= budget do
        progress.units
      else
        {busy, done} = Enum.split_with(progress.units, &(elem(&1, 1) != :done))
        Enum.take(busy, budget - 1) ++ Enum.take(done, -max(budget - 1 - length(busy), 0))
      end

    {hidden_done, hidden_busy} =
      Enum.split_with(progress.units -- listed, &(elem(&1, 1) == :done))

    rows =
      Enum.map(listed, fn {id, status} -> unit_row(id, status, frame) end) ++
        hidden_row(hidden_busy, "running or failed") ++
        hidden_row(hidden_done, "finished") ++
        if(queued > 0, do: [muted_row("  ◌ #{queued} queued")], else: [])

    [heading("Units", width) | rows]
    |> Enum.take(max(height, 0))
    |> Enum.map(&fit(&1, width))
  end

  defp hidden_row([], _label), do: []
  defp hidden_row(units, label), do: [muted_row("  … #{length(units)} more #{label}")]

  defp unit_row(id, status, frame) do
    {glyph_status, tone} =
      case status do
        :running -> {:running, :text}
        :done -> {:done, :muted}
        {:failed, _reason} -> {:failed, :error}
      end

    failure =
      case status do
        {:failed, reason} -> [span("  " <> first_line(failure_text(reason)), :error)]
        _other -> []
      end

    MessageView.row(
      [span("  ", :text), glyph_span(glyph_status, frame)] ++ unit_label(id, tone) ++ failure
    )
  end

  # Unit ids are `change` or `path#part`; the part number is secondary.
  defp unit_label("change", tone), do: [span("change overview", tone)]

  defp unit_label(id, tone) do
    case String.split(id, "#", parts: 2) do
      [path, part] -> [span(path, tone), span(" #" <> part, :subtle)]
      [path] -> [span(path, tone)]
    end
  end

  defp failure_text(reason), do: "failed: " <> Tackle.Review.Delegation.format_error(reason)

  @doc false
  @spec candidate_rows(
          ReviewProgress.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [MessageView.row()]
  def candidate_rows(%ReviewProgress{candidates: []}, width, height, _frame) do
    [heading("Candidates", width), muted_row("  none yet")]
    |> Enum.take(max(height, 0))
    |> Enum.map(&fit(&1, width))
  end

  def candidate_rows(%ReviewProgress{} = progress, width, height, frame) do
    [heading("Candidates", width) | candidate_feed(progress, max(height - 2, 1), frame)]
    |> Enum.take(max(height, 0))
    |> Enum.map(&fit(&1, width))
  end

  @doc """
  The latest `count` candidates with their verdicts, oldest first, after a
  row counting the earlier ones. Rows are not clipped.
  """
  @spec candidate_feed(ReviewProgress.t(), pos_integer(), non_neg_integer() | nil) ::
          [MessageView.row()]
  def candidate_feed(%ReviewProgress{} = progress, count, frame) do
    shown = Enum.take(progress.candidates, -count)
    earlier = length(progress.candidates) - length(shown) + progress.omitted

    if(earlier > 0, do: [muted_row("  … #{earlier} earlier")], else: []) ++
      Enum.map(shown, &candidate_row(&1, frame))
  end

  defp candidate_row(%{finding: %{title: _title} = finding, verdict: verdict}, frame) do
    title_style =
      case verdict do
        :rejected -> %{Theme.style(:muted) | modifiers: [:crossed_out]}
        :uncertain -> Theme.style(:muted)
        _other -> Theme.style(:text)
      end

    MessageView.row(
      [span("  ", :text), verdict_span(verdict, frame), severity_badge(finding.severity)] ++
        [span(" " <> finding.title, title_style)] ++
        [span("  " <> ReviewOutput.location(finding.location), :subtle)]
    )
  end

  defp candidate_row(%{fingerprint: fingerprint, verdict: verdict}, frame),
    do:
      MessageView.row([
        span("  ", :text),
        verdict_span(verdict, frame),
        span(fingerprint, :muted)
      ])

  defp verdict_span(nil, frame), do: glyph_span(:running, frame)
  defp verdict_span(:confirmed, frame), do: glyph_span(:done, frame)
  defp verdict_span(:rejected, frame), do: glyph_span(:failed, frame)
  defp verdict_span(:uncertain, _frame), do: span("? ", :warning)

  # -- summary page -------------------------------------------------------------

  @doc """
  The summary page for a review that ended: outcome, funnel, files, cost,
  and notes, each as a headed section, every row clipped to `width`.

  The outcome and the files describe the findings on screen. The funnel
  and the cost describe the last run, which after `r` is the re-review of
  the touched files only; their headings say so.
  """
  @spec summary_rows(Review.t(), non_neg_integer()) :: [MessageView.row()]
  def summary_rows(%Review{} = review, width) do
    run = if review.mode == :rereview, do: " · last re-review", else: ""

    [
      outcome_section(review, width),
      funnel_section(review.summary, "Funnel" <> run, width),
      files_section(review, width),
      cost_section(review.summary, "Cost" <> run, width),
      notes_section(review.notes, width)
    ]
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([blank()])
    |> Enum.concat()
    |> Enum.map(&fit(&1, width))
  end

  defp outcome_section(%Review{status: status, error: error}, width)
       when status in [:failed, :cancelled] do
    tone = if status == :failed, do: :error, else: :warning
    text = error || "The review failed."
    [heading("Outcome", width), MessageView.row([span("  ✗ ", tone), span(text, tone)])]
  end

  defp outcome_section(%Review{} = review, width) do
    blocking = length(review.blocking)
    optional = length(review.optional)

    {glyph, text, tone} =
      cond do
        blocking > 0 ->
          {"✗", "#{blocking} blocking · #{optional} optional findings", :error}

        optional > 0 ->
          {"●", "#{plural(optional, "optional finding")}, nothing blocking", :warning}

        match?(%{units: 0}, review.summary) ->
          {"✓", "Nothing to review in this change", :success}

        true ->
          {"✓", "No findings", :success}
      end

    verb = if review.mode == :rereview, do: "last run re-reviewed", else: "reviewed"

    reviewed =
      case review.summary do
        %{units: units} = summary when units > 0 ->
          files = summary |> Map.get(:files, []) |> length()
          profile = Map.get(summary, :profile)
          profile = if profile, do: " · #{profile} profile", else: ""

          [
            muted_row(
              "    #{verb} #{plural(files, "file")} in #{plural(units, "unit")}#{profile}"
            )
          ]

        _other ->
          []
      end

    [
      heading("Outcome", width),
      MessageView.row([span("  #{glyph} ", tone), span(text, bold(tone))])
    ] ++
      reviewed
  end

  defp funnel_section(%{units: units} = summary, title, width) when units > 0 do
    shown = Map.get(summary, :blocking, 0) + Map.get(summary, :optional, 0)

    stages = [
      {"detected", Map.get(summary, :detected, 0), :accent_soft},
      {"candidates", Map.get(summary, :candidates, 0), :accent_soft},
      {"confirmed", Map.get(summary, :confirmed, 0), :success},
      {"unverified", Map.get(summary, :uncertain, 0), :warning},
      {"rejected", Map.get(summary, :rejected, 0), :muted},
      {"shown", shown, :accent}
    ]

    top = stages |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    bar_width = min(@bar_width, max(width - 24, 4))

    rows =
      Enum.map(stages, fn {label, value, tone} ->
        MessageView.row(
          [span("  " <> String.pad_trailing(label, 12), :muted)] ++
            bar(value, top, bar_width, tone) ++ [span("  #{value}", :text)]
        )
      end)

    [heading(title, width) | rows]
  end

  defp funnel_section(_summary, _title, _width), do: []

  defp files_section(%Review{change: %Change{diff: diff}} = review, width) do
    findings = Review.findings(review)
    by_path = Enum.group_by(findings, & &1.location.path)

    name_width =
      diff.files |> Enum.map(&MessageView.display_width(&1.path)) |> Enum.max(fn -> 0 end)

    name_width = min(name_width, max(div(width, 2), 12))
    skipped = review.summary |> summary_skipped() |> Map.new(&{&1.path, &1.reason})

    rows =
      Enum.map(diff.files, fn file ->
        path = file.path |> clip(name_width) |> String.pad_trailing(name_width)

        MessageView.row(
          [
            span("  " <> path, :text),
            span("  +#{file.additions}", :success),
            span(" −#{file.deletions}", :error)
          ] ++
            file_marks(
              Map.get(by_path, file.path, []),
              Map.get(skipped, file.path),
              reviewed?(review)
            )
        )
      end)

    case rows do
      [] -> []
      rows -> [heading("Files · #{length(rows)}", width) | rows]
    end
  end

  defp files_section(_review, _width), do: []

  # Whether the files on screen were reviewed: a review that finished, or a
  # re-review running over one that did. A failed or cancelled review may
  # never have looked at them.
  defp reviewed?(%Review{status: status, summary: summary}),
    do: is_map(summary) and status not in [:failed, :cancelled]

  defp summary_skipped(%{skipped: skipped}) when is_list(skipped), do: skipped
  defp summary_skipped(_summary), do: []

  # A file is marked clean only by a review that finished; a failed or
  # cancelled one may never have looked at it.
  defp file_marks(_findings, reason, _finished?) when not is_nil(reason),
    do: [span("  skipped: " <> String.replace(to_string(reason), "_", " "), :subtle)]

  defp file_marks([], _reason, true), do: [span("  ✓", :success)]
  defp file_marks([], _reason, false), do: []

  defp file_marks(findings, _reason, _finished?) do
    counts = Enum.frequencies_by(findings, & &1.severity)

    for severity <- severities(), count = Map.get(counts, severity), count != nil do
      span("  #{severity_label(severity)} #{count}", severity_tone(severity))
    end
  end

  defp cost_section(nil, _title, _width), do: []

  defp cost_section(summary, title, width) do
    case ReviewOutput.stage_costs(summary) do
      [] ->
        []

      costs ->
        rows =
          Enum.map(costs, fn {label, text} ->
            tone = if label == "total", do: :text, else: :muted

            MessageView.row([
              span("  " <> String.pad_trailing(label, 10), tone),
              span(text, tone)
            ])
          end)

        [heading(title, width) | rows]
    end
  end

  defp notes_section([], _width), do: []

  defp notes_section(notes, width),
    do: [heading("Notes", width, :warning) | Enum.map(notes, &muted_row("  • " <> &1))]

  # -- helpers ------------------------------------------------------------------

  defp paragraph(rows), do: %Paragraph{text: rows, style: Theme.style(:text)}

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()
end
