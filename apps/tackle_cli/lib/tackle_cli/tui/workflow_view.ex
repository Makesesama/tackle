defmodule Tackle.CLI.TUI.WorkflowView do
  @moduledoc """
  Draws a `Tackle.CLI.TUI.WorkflowProgress` model as a vertical flow chart.

  Stages read top to bottom, joined by `│`. A standalone run is one node row;
  overlapping runs and `tackle.parallel` batches open a branch (`┬`) with one
  row per item (`├`/`└`). A `tackle.classify` call is one `◆` node with its
  label (or `classify`) and, once answered, each question's answer:

      ✓ scout  12s  Map the code paths
      │
      ┬ parallel  1/3 done · limit 2
      ├ ✓ reviewer  20s  Review PR #12
      ├ ● reviewer  14s  Review PR #13 · read lib/foo.ex
      └ ○ 1 queued
      │
      ◆ review gate  1s  verdict revise 82% · tests no 75%
      │
      ● worker  4s  Fix the findings
      ▸ phase two

  Every row is clipped to the given width, so the chart never wraps. The
  preview fits a row budget: older stages collapse into one `⋯ N earlier steps`
  row and a large batch lists its running and failed items while counting the
  finished and queued ones. Details draw every stage, item, and kept log line.
  `chain/1` is the one-line form for a settled card:
  `✓ scout → ✓ reviewer ×3 → ◆ gate revise`.
  """

  alias Tackle.CLI.TUI.{MessageView, Theme, WorkflowProgress}

  # Items a batch lists in the preview before counting the rest.
  @preview_items 4

  @doc """
  Chart rows for `model`, each at most `width` cells.

  `budget` bounds the rows in `:preview` mode; `:details` draws everything.
  """
  @spec rows(WorkflowProgress.t(), pos_integer(), :preview | :details, pos_integer()) ::
          [MessageView.row()]
  def rows(model, width, mode, budget \\ 12)

  def rows(model, width, :details, _budget) do
    blocks = Enum.map(model.stages, &stage_rows(&1, model, :details))
    logs = Enum.map(model.logs, &log_row/1)

    (omitted_rows(model.omitted) ++ join(blocks) ++ logs)
    |> Enum.map(&fit(&1, width))
  end

  def rows(model, width, :preview, budget) do
    logs = model.logs |> Enum.take(-1) |> Enum.map(&log_row/1)
    blocks = Enum.map(model.stages, &stage_rows(&1, model, :preview))
    {shown, hidden} = fit_blocks(blocks, max(budget - length(logs), 1))

    (omitted_rows(model.omitted + hidden) ++ join(shown) ++ logs)
    |> Enum.take(budget)
    |> Enum.map(&fit(&1, width))
  end

  @doc "A one-line summary of the stages, such as `✓ scout → ✓ reviewer ×3 → ✗ worker`."
  @spec chain(WorkflowProgress.t()) :: String.t()
  def chain(model) do
    omitted = if model.omitted > 0, do: ["⋯"], else: []

    links =
      Enum.map(model.stages, fn
        %{kind: :decision, id: id} ->
          decision_link(model.decisions[id])

        stage ->
          run_link(stage, model)
      end)

    Enum.join(omitted ++ links, " → ")
  end

  defp run_link(stage, model) do
    runs = stage |> stage_runs(model) |> Enum.reject(&is_nil/1)
    failed = failed_items(stage)
    profiles = runs |> Enum.map(&profile/1) |> Enum.uniq()
    count = length(runs) + failed

    name =
      case profiles do
        [one] -> one
        [] -> "item"
        many -> Enum.join(many, "+")
      end

    glyph(stage_status(runs, failed)) <>
      " " <> name <> if(count > 1, do: " ×#{count}", else: "")
  end

  # A settled decision with one answer names it, so the chain shows which way
  # the workflow went.
  defp decision_link(nil), do: "◆ classify"

  defp decision_link(decision) do
    answer =
      case decision do
        %{status: :completed, answers: answers} when map_size(answers) == 1 ->
          [{name, answer}] = Map.to_list(answers)
          answer_value(answer, question(decision, name))

        _other ->
          nil
      end

    glyph = if decision.status == :completed, do: "◆", else: glyph(decision.status)

    MessageView.sanitize(
      glyph <> " " <> decision_name(decision) <> if(answer, do: " " <> answer, else: "")
    )
  end

  # Stages ------------------------------------------------------------------------

  defp stage_rows(%{kind: :decision, id: id}, model, _mode),
    do: [decision_node(model.decisions[id])]

  defp stage_rows(%{kind: :runs, runs: [id]}, model, _mode), do: [run_node(model.runs[id])]

  defp stage_rows(%{kind: :runs, runs: ids}, model, mode) do
    runs = Enum.map(ids, &model.runs[&1])
    head = branch_head("concurrent", runs, 0, nil)
    [head | branch(Enum.map(runs, &{:run, &1}), 0, mode)]
  end

  defp stage_rows(%{kind: :parallel} = stage, model, mode) do
    sorted = Enum.sort_by(stage.items, &elem(&1, 0))

    items =
      Enum.map(sorted, fn
        {_index, {:run, id}} -> {:run, model.runs[id]}
        {index, {:failed, status, _text}} -> {:failed, index, status}
      end)

    runs = for {:run, run} <- items, do: run
    queued = max((stage.count || 0) - map_size(stage.items), 0)
    head = branch_head("parallel", runs, failed_items(stage), stage)
    [head | branch(items, queued, mode)]
  end

  defp branch_head(label, runs, failed, stage) do
    done = Enum.count(runs, &match?(%{status: :completed}, &1))
    total = (stage && stage.count) || length(runs) + failed
    failed = failed + Enum.count(runs, &match?(%{status: :failed}, &1))

    details =
      ["#{done}/#{total} done"] ++
        if(failed > 0, do: ["#{failed} failed"], else: []) ++
        if(stage && stage.limit, do: ["limit #{stage.limit}"], else: [])

    MessageView.row([
      span("┬ ", :muted),
      span(label, :subtle),
      span("  " <> Enum.join(details, " · "), :muted)
    ])
  end

  # Preview lists what needs attention — running and failed items — and counts
  # the finished ones, so a hundred-item batch stays a handful of rows.
  defp branch(items, queued, :details), do: connect(Enum.map(items, &item_row/1), queued)

  defp branch(items, queued, :preview) do
    {listed, done} =
      if length(items) > @preview_items do
        {attention, finished} = Enum.split_with(items, &attention?/1)
        {Enum.take(attention, @preview_items), length(finished)}
      else
        {items, 0}
      end

    hidden = length(items) - length(listed) - done
    done_row = if done > 0, do: [summary_row("✓", :subtle, "#{done} done")], else: []
    more_row = if hidden > 0, do: [summary_row("+", :muted, "#{hidden} more")], else: []

    connect(Enum.map(listed, &item_row/1) ++ more_row ++ done_row, queued)
  end

  defp attention?({:run, %{status: status}}), do: status in [:running, :failed]
  defp attention?({:failed, _index, _status}), do: true
  defp attention?(_item), do: false

  defp connect(rows, queued) do
    rows = rows ++ if(queued > 0, do: [summary_row("○", :muted, "#{queued} queued")], else: [])
    last = length(rows) - 1

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      %{row | spans: [span(if(index == last, do: "└ ", else: "├ "), :muted) | row.spans]}
    end)
  end

  defp item_row({:run, run}), do: run_node(run)

  defp item_row({:failed, index, status}),
    do:
      MessageView.row([
        span("✗ ", :error),
        span("item #{index}", :error),
        span("  " <> status, :muted)
      ])

  defp summary_row(glyph, style, text),
    do: MessageView.row([span(glyph <> " ", style), span(text, :muted)])

  defp run_node(nil), do: MessageView.row([span("○ ", :muted), span("run", :muted)])

  defp run_node(run) do
    status = run.status

    [
      span(glyph(status) <> " ", glyph_style(status)),
      span(profile(run), Theme.bold(Theme.style(:text))),
      span("  " <> elapsed(run.elapsed_ms) <> outcome(run), :muted)
    ]
    |> Kernel.++(prompt_spans(run))
    |> Kernel.++(activity_spans(run))
    |> MessageView.row()
  end

  defp decision_node(nil), do: MessageView.row([span("◆ ", :muted), span("classify", :muted)])

  defp decision_node(decision) do
    status = decision.status
    glyph = if status == :completed, do: "◆", else: glyph(status)

    [
      span(glyph <> " ", glyph_style(status)),
      span(decision_name(decision), Theme.bold(Theme.style(:text))),
      span("  " <> elapsed(decision.elapsed_ms) <> outcome(decision), :muted)
    ]
    |> Kernel.++(decision_spans(decision))
    |> MessageView.row()
  end

  # Asking (or cut short): what is asked. Answered: each answer. Failed: why.
  defp decision_spans(%{status: status, questions: [_ | _] = questions})
       when status in [:running, :ended],
       do: [span("  " <> Enum.map_join(questions, ", ", &question_name/1), :subtle)]

  defp decision_spans(%{status: :completed, answers: answers} = decision)
       when is_map(answers) and map_size(answers) > 0 do
    text =
      answers
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(" · ", fn {name, answer} ->
        case answer_value(answer, question(decision, name)) do
          nil -> to_string(name)
          value -> "#{name} #{value}"
        end
      end)

    [span("  " <> text, :accent_soft)]
  end

  defp decision_spans(%{status: :failed, text: text}) when is_binary(text) and text != "",
    do: [span("  " <> first_line(text), :muted)]

  defp decision_spans(_decision), do: []

  defp decision_name(%{label: label}) when is_binary(label) and label != "",
    do: first_line(label)

  defp decision_name(_decision), do: "classify"

  defp question(%{questions: questions}, name) when is_list(questions),
    do: Enum.find(questions, &(field(&1, :name) == name))

  defp question(_decision, _name), do: nil

  defp question_name(question), do: to_string(field(question, :name) || "?")

  # One answer as text: the choice, yes/no, or the score's level, each with its
  # probability when the model reported one.
  defp answer_value(answer, question) when is_map(answer) do
    case field(answer, :type) do
      "choice" ->
        with_percent(text_value(field(answer, :choice)), field(answer, :probability))

      "noul" ->
        case field(answer, :noul) do
          p when is_number(p) and p >= 0.5 -> with_percent("yes", p)
          p when is_number(p) -> with_percent("no", 1 - p)
          _other -> nil
        end

      "score" ->
        score_value(field(answer, :score), field(question, :options))

      _other ->
        nil
    end
  end

  defp answer_value(_answer, _question), do: nil

  # Scores are 1-based; a whole score names its level, a weighted one shows
  # where it falls on the scale.
  defp score_value(score, levels) when is_number(score) and is_list(levels) and levels != [] do
    index = round(score)

    if score == index and index in 1..length(levels),
      do: text_value(Enum.at(levels, index - 1)) || format_number(score),
      else: "#{format_number(score)}/#{length(levels)}"
  end

  defp score_value(score, _levels) when is_number(score), do: format_number(score)
  defp score_value(_score, _levels), do: nil

  defp with_percent(nil, _probability), do: nil

  # Adapters should report probabilities in 0..1; clamp so a stray value never
  # reads as "120%".
  defp with_percent(value, probability) when is_number(probability),
    do: "#{value} #{round(min(max(probability, 0), 1) * 100)}%"

  defp with_percent(value, _probability), do: value

  defp text_value(value) when is_binary(value), do: first_line(value)
  defp text_value(value) when is_number(value), do: format_number(value)
  defp text_value(_value), do: nil

  defp format_number(number) when is_integer(number), do: Integer.to_string(number)

  defp format_number(number),
    do: :erlang.float_to_binary(number * 1.0, decimals: 1) |> String.trim_trailing(".0")

  defp first_line(text), do: text |> String.split("\n", trim: true) |> List.first("")

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_other, _key), do: nil

  defp prompt_spans(%{prompt: prompt}) when is_binary(prompt) and prompt != "" do
    case prompt |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) do
      [first | _rest] when first != "" -> [span("  " <> first, :subtle)]
      _blank -> []
    end
  end

  defp prompt_spans(_run), do: []

  # The narrator's line, while fresh, stands in for the raw activity.
  defp activity_spans(%{status: :running, narration: narration})
       when is_binary(narration) and narration != "",
       do: [span(" · " <> narration, :accent_soft)]

  defp activity_spans(%{status: :running, now: now}) when is_binary(now) and now != "",
    do: [span(" · " <> now, :accent_soft)]

  defp activity_spans(_run), do: []

  defp log_row(message) do
    text = message |> String.split("\n", trim: true) |> List.first("")
    MessageView.row([span("▸ ", :muted), span(text, :muted)])
  end

  defp omitted_rows(0), do: []

  defp omitted_rows(count),
    do: [MessageView.row([span("⋯ #{count} earlier #{plural(count, "step")}", :muted)])]

  # Layout ------------------------------------------------------------------------

  # Stages are joined by a connector row; the newest stages win the budget, and
  # one row is kept for the omission notice whenever something is hidden.
  defp join(blocks), do: blocks |> Enum.intersperse([connector()]) |> Enum.concat()

  defp connector, do: MessageView.row([span("│", :muted)])

  defp fit_blocks(blocks, budget) do
    total = blocks |> join() |> length()

    if total <= budget do
      {blocks, 0}
    else
      {shown, _used} =
        blocks
        |> Enum.reverse()
        |> Enum.reduce_while({[], 1}, fn block, {shown, used} ->
          cost = length(block) + if(shown == [], do: 0, else: 1)

          if used + cost <= budget,
            do: {:cont, {[block | shown], used + cost}},
            else: {:halt, {shown, used}}
        end)

      # A single oversized stage still shows its head rather than nothing.
      shown = if shown == [], do: [Enum.take(List.last(blocks), budget - 1)], else: shown
      {shown, length(blocks) - length(shown)}
    end
  end

  # Clips a row's spans to `width` display cells, ending with `…` when cut.
  defp fit(%{spans: spans} = row, width) do
    if spans |> Enum.map(&MessageView.display_width(&1.content)) |> Enum.sum() <= width do
      row
    else
      {kept, _used} =
        Enum.reduce_while(spans, {[], 0}, fn span, {kept, used} ->
          room = width - 1 - used
          size = MessageView.display_width(span.content)

          if size <= room,
            do: {:cont, {[span | kept], used + size}},
            else:
              {:halt, {[%{span | content: take_width(span.content, room) <> "…"} | kept], width}}
        end)

      %{row | spans: Enum.reverse(kept)}
    end
  end

  defp take_width(text, room) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, used} ->
      next = used + MessageView.display_width(grapheme)
      if next <= room, do: {:cont, {[grapheme | kept], next}}, else: {:halt, {kept, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  # Helpers -----------------------------------------------------------------------

  defp stage_runs(%{kind: :runs, runs: ids}, model), do: Enum.map(ids, &model.runs[&1])
  defp stage_runs(%{kind: :decision}, _model), do: []

  defp stage_runs(%{items: items}, model),
    do: for({_index, {:run, id}} <- Enum.sort(items), do: model.runs[id])

  defp failed_items(%{kind: :parallel, items: items}),
    do: Enum.count(items, &match?({_index, {:failed, _, _}}, &1))

  defp failed_items(_stage), do: 0

  defp stage_status(runs, failed) do
    statuses = Enum.map(runs, & &1.status)

    cond do
      :running in statuses -> :running
      failed > 0 or :failed in statuses -> :failed
      :ended in statuses -> :ended
      true -> :completed
    end
  end

  defp profile(run), do: MessageView.sanitize(Map.get(run, :profile) || "run")

  defp outcome(%{status: :failed, outcome: outcome}) when is_atom(outcome) and outcome != nil,
    do: "  " <> Atom.to_string(outcome)

  defp outcome(%{status: :ended}), do: "  ended"
  defp outcome(_run), do: ""

  defp glyph(:completed), do: "✓"
  defp glyph(:failed), do: "✗"
  defp glyph(:running), do: "●"
  defp glyph(_ended), do: "◌"

  defp glyph_style(:completed), do: Theme.style(:success)
  defp glyph_style(:failed), do: Theme.style(:error)
  defp glyph_style(:running), do: Theme.style(:accent_soft)
  defp glyph_style(_ended), do: Theme.style(:muted)

  defp elapsed(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1_000)
    if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp elapsed(_ms), do: "0s"

  defp span(text, style) when is_atom(style),
    do: MessageView.span(MessageView.sanitize(text), Theme.style(style))

  defp span(text, %_{} = style), do: MessageView.span(MessageView.sanitize(text), style)

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
