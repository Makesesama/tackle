defmodule Tackle.CLI.TUI.ReviewCallView do
  @moduledoc """
  Draws a `review_changes` tool call in the transcript, from the live
  `Tackle.CLI.TUI.ReviewCall` model and the call's result.

  While the review runs, the card shows the pipeline stepper, a progress
  bar for the units and one for the verified candidates, and the latest
  candidates with their verdicts, the same pieces the `/review` overlay
  uses (`Tackle.CLI.TUI.ReviewDashboard`). Once it finished, the card
  shows the outcome with the review's size and the findings, one row
  each: a severity badge, the title, and the location. Details add the
  full progress above the result text.

  Transcript cards do not animate, so running steps show a still `●`.
  """

  alias Tackle.CLI.TUI.{MessageView, ReviewCall, ReviewDashboard, ReviewProgress}

  import Tackle.CLI.TUI.ReviewRows

  @typedoc "A tool call status as `Tackle.CLI.TUI.ToolView` knows it."
  @type status :: :preparing | :requested | :running | :completed | :failed

  @doc """
  What the card's header names as reviewed: the loaded change, the
  result's target, or the call's arguments.
  """
  @spec target(ReviewCall.t() | nil, String.t() | nil, map()) :: String.t()
  def target(model, output, args) do
    cond do
      ReviewCall.loaded?(model) -> model.target
      result = ReviewCall.parse_result(output) -> result.target
      true -> requested_target(args)
    end
  end

  defp requested_target(args) do
    cond do
      is_binary(get(args, :range)) and get(args, :range) != "" -> get(args, :range)
      get(args, :staged) == true -> "staged changes"
      true -> "branch changes"
    end
  end

  @doc """
  The card's preview rows within `width` cells and `budget` rows, or `nil`
  when the card has nothing of its own to show (a call still being
  written, a failure, or a result this shell cannot read), so the generic
  card applies.
  """
  @spec preview(ReviewCall.t() | nil, status(), String.t() | nil, pos_integer(), pos_integer()) ::
          [MessageView.row()] | nil
  def preview(model, status, output, width, budget)

  # A `:requested` call never started, or is an orphan in a resumed
  # session; only a running one is loading.
  def preview(model, :running, _output, width, budget) do
    rows =
      if ReviewCall.loaded?(model),
        do: live_rows(model, width, budget),
        else: [MessageView.row([glyph_span(:running, nil), span("Loading the change…", :muted)])]

    rows |> Enum.take(budget) |> Enum.map(&fit(&1, width))
  end

  def preview(model, :completed, output, width, budget) do
    case ReviewCall.parse_result(output) do
      nil ->
        nil

      result ->
        result |> settled_rows(model, budget) |> Enum.take(budget) |> Enum.map(&fit(&1, width))
    end
  end

  def preview(_model, _status, _output, _width, _budget), do: nil

  @doc "The full progress for the details view, or no rows before the change loaded."
  @spec details(ReviewCall.t() | nil, pos_integer()) :: [MessageView.row()]
  def details(model, width) do
    if ReviewCall.loaded?(model) do
      progress = model.progress
      candidates = length(progress.candidates)

      ([stepper_row(model), loaded_row(model)] ++
         progress_rows(model, width) ++
         if(candidates > 0,
           do: ReviewDashboard.candidate_feed(progress, candidates, nil),
           else: []
         ))
      |> Enum.map(&fit(&1, width))
    else
      []
    end
  end

  # -- running ------------------------------------------------------------------

  defp live_rows(model, width, budget) do
    head = [stepper_row(model) | progress_rows(model, width)]
    room = budget - length(head)

    feed =
      if room > 0 and model.progress.candidates != [],
        do: ReviewDashboard.candidate_feed(model.progress, room, nil) |> Enum.take(-room),
        else: []

    Enum.take(head, budget) ++ feed
  end

  defp stepper_row(model) do
    status = if model.summary, do: :done, else: :running
    MessageView.row(ReviewDashboard.stepper(status, model.progress, nil))
  end

  defp progress_rows(%ReviewCall{progress: %ReviewProgress{total: nil}}, _width), do: []

  defp progress_rows(%ReviewCall{progress: progress}, width),
    do: ReviewDashboard.progress_rows(progress, width)

  defp loaded_row(model) do
    MessageView.row(
      [span("#{model.target}  ", :muted)] ++
        diff_spans(model) ++
        if(model.profile, do: [span("  #{model.profile} profile", :subtle)], else: [])
    )
  end

  # -- settled ------------------------------------------------------------------

  defp settled_rows(result, model, budget) do
    notes = notes_rows(result.notes)
    room = max(budget - 1 - length(notes), 1)
    findings = result.findings
    shown = if length(findings) > room, do: Enum.take(findings, room - 1), else: findings
    hidden = length(findings) - length(shown)

    more =
      if hidden > 0,
        do: [muted_row("… #{plural(hidden, "more finding")} · details show all")],
        else: []

    [outcome_row(result, model) | Enum.map(shown, &finding_row/1)] ++ more ++ notes
  end

  defp outcome_row(result, model) do
    {glyph, text, tone} =
      cond do
        result.blocking > 0 ->
          {"✗", "#{result.blocking} blocking · #{result.optional} optional", :error}

        result.optional > 0 ->
          {"●", "#{plural(result.optional, "optional finding")}", :warning}

        incomplete?(result) ->
          {"●", "No findings, but the review was incomplete", :warning}

        is_nil(result.files) ->
          {"✓", "Nothing to review", :success}

        true ->
          {"✓", "No findings", :success}
      end

    MessageView.row(
      [span(glyph <> " ", tone), span(text, bold(tone))] ++ stats_spans(result, model)
    )
  end

  defp stats_spans(%{files: nil}, _model), do: []

  defp stats_spans(result, model) do
    files = [span("  " <> plural(result.files, "file") <> " reviewed", :muted)]

    diff =
      if ReviewCall.loaded?(model),
        do: [
          span(" ·", :muted),
          span(" +#{model.additions || 0}", :success),
          span(" −#{model.deletions || 0}", :error)
        ],
        else: []

    verified =
      case model do
        %ReviewCall{summary: %{candidates: candidates} = summary} when candidates > 0 ->
          [
            span(
              " · #{plural(candidates, "candidate")}, #{summary[:rejected] || 0} rejected",
              :muted
            )
          ]

        _other ->
          []
      end

    files ++ diff ++ verified
  end

  defp finding_row(finding) do
    title_tone = if finding.group == :blocking, do: :text, else: :muted
    unverified = if finding.unverified?, do: [span(" ?", :warning)], else: []

    MessageView.row(
      [severity_badge(finding.severity), span(" " <> finding.title, title_tone)] ++
        unverified ++ [span("  " <> finding.location, :subtle)]
    )
  end

  # The tool notes units it could not review and findings it could not
  # verify (`Tackle.Tools.Review`); a clean outcome is then not a clean bill.
  defp incomplete?(%{notes: notes}),
    do: Enum.any?(notes, &(&1 =~ ~r/^Unit .* was not reviewed|could not be verified/u))

  # The first note in full; the rest are counted, and kept in details.
  defp notes_rows([]), do: []

  defp notes_rows([note | rest]) do
    more =
      if rest == [], do: [], else: [span("  +#{plural(length(rest), "more note")}", :subtle)]

    [MessageView.row([span("! ", :warning), span(note, :muted) | more])]
  end

  # -- helpers ------------------------------------------------------------------

  defp diff_spans(%ReviewCall{files: files, additions: additions, deletions: deletions})
       when is_integer(files) do
    [
      span(plural(files, "file"), :muted),
      span(" +#{additions || 0}", :success),
      span(" −#{deletions || 0}", :error)
    ]
  end

  defp diff_spans(_model), do: []

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_map, _key), do: nil
end
