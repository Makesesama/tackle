defmodule Tackle.CLI.TUI.ToolView do
  @moduledoc """
  Built-in, render-only tool cards.

  Cards are borderless: completed calls have no marker, while activity/failure
  markers accompany a prominent path or subdued command. Preview rows use a four-cell
  hanging indent. Completed calls omit redundant status text;
  running, requested and failed calls stay explicit. Successful reads collapse
  to a tool/path header.

  Bash cards read like a shell prompt: the directory of a leading `cd <dir> &&`
  in a subtle tone, an accent `$`, and the command painted in theme tones
  (`Tackle.CLI.TUI.BashView`); multi-line commands show their first line and
  a `+N lines` count, and a command past three rows ends in `…`. Output runs
  along a `│` rail, dedented as a block: successful calls show a two-line tail
  with a count of the lines above, failures keep both ends. A footer that is
  always present closes the card with `└`: `✓` and the locally observed time,
  or on failure the exit code lifted out of the output.
  Full retained output stays in details. Failed edits/writes show the error instead of
  submitted changes (details retain the submitted arguments as source).
  Subagents show their profile, assignment, live status, and locally observed
  elapsed time when available. Completed subagents show just the elapsed seconds
  instead of a completion label. Canonical delegated findings render in full as
  Markdown with highlighted code, inline and in details; assignment previews
  stay bounded and full arguments stay in details.
  Workflows (`run_workflow`) retain the static script outline until progress
  arrives, then render a live vertical graph of delegated runs and fan-out.
  Details show the full graph followed by numbered script and result.
  Reviews (`review_changes`) name what they review in the header, show the
  pipeline, progress bars, and live candidates while running, and the
  outcome with one row per finding once settled
  (`Tackle.CLI.TUI.ReviewCallView`); details add the full progress above
  the result text.
  Unknown tools retain a generic source fallback.

  Bash calls the session's command watchdog (`Tackle.Watchdog`) is watching
  show `◉` instead of the running dot; a call it stopped shows `⊘ stopped`
  in the warning tone instead of `✗ failed`. The stop is recognized from the
  watchdog's message in the error, so it survives a resume.

  Edit previews compare the submitted replacement strings, never files on disk.
  They are not authoritative file diffs; line numbers are relative to each
  replacement. `similar` matches the lines in Rust and marks the tokens that
  changed inside an otherwise similar line, so a one-word change stays legible
  instead of reading as a whole-line rewrite. Rows paint a full-width add/delete
  fill behind syntax-highlighted code — Lumis, the same tree-sitter highlighter
  as the web app, with plain text as the fallback — while context rows keep the
  terminal background. Soft-colored `+`/`-` markers and a number gutter as wide
  as the largest line number sit in front — opaque and more saturated on light
  backgrounds so numbers stay readable against the pastel fill. Only changed
  tokens receive the stronger inline tint, one step more saturated than the
  fill so intraline emphasis survives on it; token colors yield to it. The preview keeps a line of context
  around each change and elides longer unchanged runs; details print every
  submitted line. A replacement too large to match falls back to a bounded
  before/after window. Execution outcome and preview provenance remain
  separate. Edit/write cards have a separate visual code-row budget (16 by
  default, up to 20 based on transcript height). Summaries and omission notices
  sit outside it. Whole hunks that fit are preferred; oversized hunks show a
  contiguous prefix, not arbitrary head/tail fragments. At most two replacements
  are matched inline, with an explicit omitted-replacement count.

  Activity groups collapse consecutive exploring calls (reads, listings,
  searches) into one card, as in Codex's TUI: a bold `Exploring`/`Explored`
  header with one summary row per call (`Read a.ex, b.ex`, `List packages`,
  `Search query in path`), failed calls marked inline. Details expand every
  member back into its full card, including absorbed collapsed reasoning, so
  no command, output, or thinking is lost.
  """

  alias ExRatatui.Style
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.{BashView, Highlight, MessageView, ReviewCallView, Theme, ToolGroups}
  alias Tackle.CLI.TUI.{WorkflowProgress, WorkflowView}
  alias Tackle.CLI.WorkflowScript

  @preview_rows 6
  @file_preview_rows 16
  # A workflow preview is a glance at the plan, not the whole program.
  @workflow_preview_rows 10
  # A live chart may use a little more: it is the card's main content.
  @workflow_graph_rows 12
  # A review card: the pipeline and progress, then candidates or findings.
  @review_rows 10
  # Lumis picks the grammar from the extension.
  @workflow_path "workflow.lua"
  @preview_replacements 2
  @preview_context 1
  @header_rows 2
  # Commands get one more row than other titles: they are the card's content.
  @bash_header_rows 3

  @doc "A compact, source-independent title for a tool call."
  def title(name, arguments, _status) do
    target = target(name, arguments)
    name <> if(target == "", do: "", else: "  " <> target)
  end

  @doc "Renders an inline card or retained details; delegated findings are unabridged, other previews bounded."
  @spec render(MessageView.t(), pos_integer(), :preview | :details, keyword()) ::
          [MessageView.widget_item()]
  def render(entry, width, mode \\ :preview, opts \\ [])

  def render(%{tool_group: members} = entry, width, mode, _opts)
      when is_list(members) and members != [],
      do: group_render(entry, members, width, mode)

  def render(entry, width, mode, opts) do
    output = markdown_output(entry)

    paint_entry =
      if output,
        do: %{entry | tool_output: nil, subagent_output: nil, subagent_work: nil},
        else: entry

    args = arguments(entry.tool_arguments)

    header_args =
      if mode == :preview and entry.tool_status == :preparing and
           entry.tool_name in ["edit", "write"] and is_binary(entry.tool_arguments) do
        Map.put(args, "path", partial_field(entry.tool_arguments, "path"))
      else
        args
      end

    header =
      if entry.tool_name == "bash" do
        bash_header(entry, args, width)
      else
        entry
        |> header_rows(header_args, width)
        |> wrap_indented(width, 4, true)
        |> Enum.take(@header_rows)
      end

    body =
      cond do
        entry.tool_name == "bash" ->
          bash_body(paint_entry, args, mode, width)

        mode == :preview ->
          file_preview(
            paint_entry,
            args,
            width,
            Keyword.get(opts, :code_rows, @file_preview_rows)
          ) ||
            compact_body(paint_entry, args, mode, width)

        true ->
          compact_body(paint_entry, args, mode, width)
      end

    result =
      if output && Keyword.get(opts, :render_result?, true),
        do: Tackle.CLI.Widgets.Conversation.markdown_items(output, width, result_style(entry)),
        else: []

    MessageView.render_lines(header ++ body) ++ result
  end

  @doc "Returns canonical delegated findings for full Markdown rendering, never live activity."
  @spec markdown_output(MessageView.t()) :: String.t() | nil
  def markdown_output(%{tool_name: name, tool_status: status, tool_output: output} = entry)
      when name in ["subagent", "subagent_wait", "subagent_status"] and
             status in [:completed, :failed] and is_binary(output) do
    args = arguments(entry.tool_arguments)

    cond do
      name == "subagent" and get(args, :background) == true ->
        nil

      name == "subagent_status" and
          output == "Subagent #{get(args, :run_id)} is still running." ->
        nil

      name in ["subagent_wait", "subagent_status"] and is_binary(get(args, :run_id)) ->
        String.replace_prefix(output, "Subagent #{get(args, :run_id)} completed:\n\n", "")

      true ->
        output
    end
  end

  def markdown_output(_entry), do: nil

  @doc false
  def result_style(%{tool_status: :failed}), do: Theme.style(:error)
  def result_style(_entry), do: Theme.style(:text)

  @doc false
  @spec preview_code_rows(integer()) :: pos_integer()
  def preview_code_rows(height), do: height |> Kernel.-(4) |> max(1) |> min(20)

  ## Activity groups

  # Details expand every member back into its full card, separated by a blank
  # row; the preview keeps one summary row per classified call.
  defp group_render(_entry, members, width, :details) do
    members
    |> Enum.map(&MessageView.inspect_items(&1, width))
    |> Enum.intersperse(MessageView.render_lines([MessageView.row("")]))
    |> List.flatten()
  end

  defp group_render(entry, members, width, :preview) do
    header = wrap_indented(group_header_rows(entry), width, 4, true)
    body = wrap_indented(group_body_rows(members), width, 4)

    MessageView.render_lines(trim(header ++ body, :preview, width))
  end

  defp group_header_rows(entry) do
    status = entry.tool_status
    title = if status == :running, do: "Exploring", else: "Explored"

    spans = [
      MessageView.span(group_marker(status), group_marker_style(status)),
      MessageView.span(title, Theme.bold(Theme.style(:text)))
    ]

    spans =
      case {status, entry.tool_elapsed_ms} do
        {:completed, ms} when is_integer(ms) and ms >= 0 ->
          spans ++ [MessageView.span("  ·  " <> elapsed_text(ms), Theme.style(:muted))]

        _ ->
          spans
      end

    [MessageView.row(spans)]
  end

  defp group_body_rows(members) do
    Enum.flat_map(ToolGroups.rows(members), fn row ->
      case row.error do
        nil -> [group_row(row)]
        error -> [group_row(row), group_error_row(error)]
      end
    end)
  end

  defp group_error_row(error) do
    MessageView.row([
      MessageView.span("└ ", Theme.style(:subtle)),
      MessageView.span(error, Theme.style(:error))
    ])
  end

  defp group_row(%{kind: :read, names: names, failed?: failed?}) do
    group_failure_row(
      [
        MessageView.span("Read  ", Theme.style(:accent_soft)),
        MessageView.span(Enum.join(names, ", "), Theme.style(:text))
      ],
      failed?
    )
  end

  defp group_row(%{kind: :list, path: nil, failed?: failed?}) do
    group_failure_row([MessageView.span("List", Theme.style(:accent_soft))], failed?)
  end

  defp group_row(%{kind: :list, path: path, failed?: failed?}) do
    group_failure_row(
      [
        MessageView.span("List  ", Theme.style(:accent_soft)),
        MessageView.span(path, Theme.style(:text))
      ],
      failed?
    )
  end

  defp group_row(%{kind: :search, query: query, path: path, failed?: failed?}) do
    spans = [
      MessageView.span("Search  ", Theme.style(:accent_soft)),
      MessageView.span(query || "", Theme.style(:text))
    ]

    spans =
      if path,
        do:
          spans ++
            [
              MessageView.span(" in ", Theme.style(:muted)),
              MessageView.span(path, Theme.style(:text))
            ],
        else: spans

    group_failure_row(spans, failed?)
  end

  defp group_failure_row(spans, false), do: MessageView.row(spans)

  defp group_failure_row(spans, true),
    do: MessageView.row(spans ++ [MessageView.span("  (failed)", Theme.style(:error))])

  defp group_marker(:running), do: "● "
  defp group_marker(_completed), do: "• "

  defp group_marker_style(:running), do: Theme.style(:accent_soft)
  defp group_marker_style(_completed), do: Theme.style(:subtle)

  defp compact_body(entry, args, mode, width) do
    entry
    |> body_rows(args, mode, width)
    |> wrap_indented(width, 4)
    |> trim(mode, width)
  end

  # File previews are budgeted once, after measuring wrapping. Metadata is
  # separate from code: counts and omission notices never evict a code row.
  defp file_preview(%{tool_status: :failed}, _args, _width, _budget), do: nil

  defp file_preview(
         %{tool_name: name, tool_status: :preparing, tool_arguments: raw},
         %{"input" => raw},
         width,
         budget
       )
       when name in ["edit", "write"] and is_binary(raw) do
    path = partial_field(raw, "path")

    {label, content} =
      if name == "write",
        do: {"Content incoming (partial)", partial_field(raw, "content")},
        else:
          {"Edit incoming (partial)",
           partial_field(raw, "newText") || partial_field(raw, "oldText")}

    text_preview(content, label, width, budget, path)
  end

  defp file_preview(%{tool_name: "write"}, args, width, budget) do
    case get(args, :content) do
      content when is_binary(content) ->
        text_preview(
          content,
          "Content preview (prior file not compared)",
          width,
          budget,
          get(args, :path)
        )

      _ ->
        nil
    end
  end

  defp file_preview(%{tool_name: "edit"}, args, width, budget) do
    case get(args, :edits) do
      edits when is_list(edits) and edits != [] ->
        edit_preview(edits, width, budget, get(args, :path))

      _ ->
        nil
    end
  end

  defp file_preview(
         %{tool_name: "run_workflow", tool_status: status} = entry,
         args,
         width,
         budget
       )
       when status in [:preparing, :requested, :running] do
    cond do
      WorkflowProgress.started?(entry.workflow_progress) ->
        entry.workflow_progress
        |> WorkflowView.rows(content_width(width), :preview, min(budget, @workflow_graph_rows))
        |> wrap_indented(width, 4)

      script = workflow_script(entry, args) ->
        label =
          if status == :preparing,
            do: "Script incoming (partial)",
            else: workflow_label(script)

        script
        |> String.trim_trailing("\n")
        |> text_preview(label, width, min(budget, @workflow_preview_rows), @workflow_path)

      true ->
        nil
    end
  end

  defp file_preview(%{tool_name: "review_changes"} = entry, _args, width, budget) do
    rows =
      ReviewCallView.preview(
        entry.review_call,
        entry.tool_status,
        entry.tool_output,
        content_width(width),
        min(budget, @review_rows)
      )

    if rows, do: wrap_indented(rows, width, 4)
  end

  defp file_preview(_entry, _args, _width, _budget), do: nil

  # Code previews are syntax-highlighted for the file's language when the
  # highlighter covers them; plain text is the fallback, never an error.
  defp text_preview(nil, label, width, _budget, _path), do: preview_note(label, width)

  defp text_preview(content, label, width, budget, path) do
    lines = String.split(content, "\n", trim: false)
    tokens = Highlight.lines(content, path)

    # Build at most the number of logical lines that could fit, not every row.
    rows =
      lines
      |> Enum.take(budget)
      |> Enum.with_index(1)
      |> Enum.map(&code_row(&1, tokens))

    {shown, count, _used} = code_prefix(rows, width, budget)
    preview_note(label, width) ++ shown ++ showing_note(count, length(lines), width)
  end

  defp code_row({line, number}, tokens) do
    case Map.get(tokens, number) do
      nil -> body_row(Theme.style(:text), line)
      runs -> MessageView.row(Enum.map(runs, &token_span/1))
    end
  end

  defp code_spans(line, number, tokens) do
    case Map.get(tokens, number) do
      nil -> [MessageView.span(line, Theme.style(:text))]
      runs -> Enum.map(runs, &token_span/1)
    end
  end

  defp token_span({text, nil}), do: MessageView.span(text, Theme.style(:text))
  defp token_span({text, style}), do: MessageView.span(text, style)

  defp edit_preview(edits, width, budget, path) do
    {rows, _remaining, shown_count} =
      edits
      |> Enum.take(@preview_replacements)
      |> Enum.with_index(1)
      |> Enum.reduce({[], budget, 0}, fn {edit, index}, {rows, remaining, count} ->
        if remaining > 0 do
          {preview, used} = replacement_preview(edit, index, width, remaining, path)
          {rows ++ preview, remaining - used, count + 1}
        else
          {rows, remaining, count}
        end
      end)

    total = length(edits)
    omitted = total - shown_count
    summary = "#{total} " <> if(total == 1, do: "replacement", else: "replacements")
    summary = if omitted > 0, do: summary <> " · #{omitted} omitted", else: summary
    preview_note(summary, width) ++ rows
  end

  defp replacement_preview(edit, index, width, budget, path) when is_map(edit) do
    old = get(edit, :oldText)
    new = get(edit, :newText)

    if is_binary(old) and is_binary(new) do
      # No native head/tail cut. Matching and oversized before/after fallback
      # already have native work bounds; only selected lines are wrapped here.
      {added, removed, source} = diff_rows(old, new, @preview_context, 0)
      number_width = gutter_width(source)
      tokens = diff_tokens(old, new, path)

      total =
        Enum.reduce(source, 0, fn
          {:elision, n}, sum -> sum + n
          _, sum -> sum + 1
        end)

      hunks = source |> Enum.chunk_by(&match?({:elision, _}, &1))

      {chosen, used, count} =
        hunks
        |> Enum.with_index()
        |> Enum.reject(fn {hunk, _} -> match?([{:elision, _} | _], hunk) end)
        |> Enum.reduce({[], 0, 0}, fn {hunk, index}, {chosen, used, count} ->
          case fitting_hunk(hunk, number_width, width, budget - used, tokens) do
            {:ok, rows, size} ->
              {chosen ++ [{index, wrap_indented(rows, width, 4)}], used + size,
               count + length(rows)}

            :too_large ->
              {chosen, used, count}
          end
        end)

      {paint, count, used} =
        if chosen == [] do
          first = Enum.find(hunks, [], fn hunk -> not match?([{:elision, _} | _], hunk) end)

          first
          |> Enum.take(budget)
          |> Enum.map(&diff_row(&1, number_width, tokens))
          |> code_prefix(width, budget)
        else
          paint =
            Enum.flat_map(chosen, fn {index, rows} ->
              notice =
                if index > 0, do: preview_note("… intervening lines omitted", width), else: []

              notice ++ rows
            end)

          {paint, count, used}
        end

      heading = wrap_indented([replacement_heading(added, removed)], width, 4) |> Enum.take(1)
      {heading ++ paint ++ showing_note(count, total, width), used}
    else
      {preview_note("Edit #{index}: invalid preview data", width), 0}
    end
  end

  defp replacement_preview(_edit, index, width, _budget, _path),
    do: {preview_note("Edit #{index}: invalid preview data", width), 0}

  # Prefer complete logical lines. Only an oversized first line needs a partial
  # visual prefix; don't split later lines just to fill the remaining space.
  defp code_prefix(rows, width, budget) do
    Enum.reduce_while(rows, {[], 0, 0}, fn row, {shown, count, used} ->
      size = wrapped_size(row, width, budget - used)

      cond do
        size <= budget - used ->
          {:cont, {shown ++ wrap_indented([row], width, 4), count + 1, used + size}}

        used == 0 ->
          bounded = bound_row(row, content_width(width) * budget)
          paint = wrap_indented([bounded], width, 4) |> Enum.take(budget)
          {:halt, {paint ++ preview_note("… line continues in details", width), 1, length(paint)}}

        true ->
          {:halt, {shown, count, used}}
      end
    end)
  end

  defp fitting_hunk(hunk, number_width, width, budget, tokens) do
    Enum.reduce_while(hunk, {:ok, [], 0}, fn source, {:ok, rows, used} ->
      row = diff_row(source, number_width, tokens)
      size = wrapped_size(row, width, budget - used)

      if size <= budget - used,
        do: {:cont, {:ok, rows ++ [row], used + size}},
        else: {:halt, :too_large}
    end)
  end

  # Match MessageView's grapheme wrapping, including a zero-width grapheme at
  # the start of a row. Stop as soon as the candidate cannot fit the budget.
  defp wrapped_size(row, width, limit) do
    {rows, _used, _occupied} =
      Enum.reduce_while(row.spans, {1, 0, false}, fn span, acc ->
        measured = measure_text(span.content, content_width(width), limit, acc)
        if elem(measured, 0) > limit, do: {:halt, measured}, else: {:cont, measured}
      end)

    rows
  end

  defp measure_text("", _width, _limit, acc), do: acc
  defp measure_text(_text, _width, limit, {rows, _, _} = acc) when rows > limit, do: acc

  defp measure_text(text, width, limit, {rows, used, occupied}) do
    {grapheme, rest} = String.next_grapheme(text)
    cells = MessageView.display_width(grapheme)

    next =
      if occupied and used + cells > width,
        do: {rows + 1, cells, true},
        else: {rows, used + cells, true}

    measure_text(rest, width, limit, next)
  end

  defp content_width(width), do: max(if(width > 5, do: width - 4, else: width), 1)

  # Limit materialization before wrapping a giant source line. Taking visual
  # rows afterwards is only a final guard for wide graphemes.
  defp bound_row(row, cells) do
    {spans, _remaining} =
      Enum.map_reduce(row.spans, cells, fn span, remaining ->
        content = String.slice(span.content, 0, max(remaining, 0))
        {%{span | content: content}, max(remaining - String.length(content), 0)}
      end)

    %{row | spans: spans}
  end

  defp showing_note(shown, total, width) when shown < total,
    do: preview_note("Showing #{shown} of #{total} lines", width)

  defp showing_note(_shown, _total, _width), do: []

  # Notices are a single clipped row even on narrow terminals, so metadata
  # cannot become a second wall of wrapped text outside the code budget.
  defp preview_note(text, width) do
    wrap_indented([context_row(clip_width(text, content_width(width)))], width, 4)
    |> Enum.take(1)
  end

  @doc "The complete arguments, including fields hidden by the compact title."
  def arguments(nil), do: %{}
  def arguments(args) when is_map(args), do: args

  def arguments(args) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"input" => args}
    end
  end

  def arguments(args), do: %{"input" => inspect(args)}

  defp target(name, raw) do
    args = arguments(raw)

    value =
      case name do
        "subagent" ->
          get(args, :profile)

        name when name in ["subagent_wait", "subagent_status"] ->
          get(args, :run_id)

        "run_workflow" ->
          WorkflowScript.saved_name(get(args, :workflow)) ||
            args |> get(:script) |> WorkflowScript.outline() |> WorkflowScript.summary()

        "bash" ->
          get(args, :command)

        name when name in ["read", "edit", "write"] ->
          get(args, :path)

        _ ->
          get(args, :path) || get(args, :command)
      end

    if is_binary(value), do: value, else: ""
  end

  defp header_rows(%{tool_name: "subagent"} = entry, args, _width) do
    profile = target("subagent", args)
    profile = if profile == "", do: "unknown profile", else: profile
    status = entry.tool_status

    model =
      case Map.get(entry, :model) do
        model when is_binary(model) and model != "" -> "  " <> model
        _ -> ""
      end

    [
      MessageView.row([
        MessageView.span(marker(status), marker_style(status)),
        MessageView.span(subagent_status(status), status_style(status)),
        MessageView.span("subagent  ", Theme.style(:muted)),
        MessageView.span(profile, Theme.bold(Theme.style(:text))),
        MessageView.span(
          model <> elapsed_suffix(status, entry.tool_elapsed_ms),
          Theme.style(:muted)
        )
      ])
    ]
  end

  defp header_rows(%{tool_name: "run_workflow"} = entry, args, _width) do
    status = entry.tool_status

    summary =
      workflow_name(entry, args) ||
        entry
        |> workflow_script(args)
        |> WorkflowScript.outline()
        |> WorkflowScript.summary()

    heading =
      if summary == "" do
        [MessageView.span("workflow", Theme.bold(Theme.style(:text)))]
      else
        [
          MessageView.span("workflow  ", Theme.style(:muted)),
          MessageView.span(summary, Theme.bold(Theme.style(:text)))
        ]
      end

    [
      MessageView.row(
        [
          MessageView.span(marker(status), marker_style(status)),
          MessageView.span(subagent_status(status), status_style(status))
        ] ++
          heading ++
          [MessageView.span(elapsed_suffix(status, entry.tool_elapsed_ms), Theme.style(:muted))]
      )
    ]
  end

  defp header_rows(%{tool_name: "review_changes"} = entry, args, _width) do
    status = entry.tool_status
    target = ReviewCallView.target(entry.review_call, entry.tool_output, args)

    profile =
      case get(args, :profile) do
        profile when is_binary(profile) and profile != "" -> "  #{profile} profile"
        _default -> ""
      end

    [
      MessageView.row([
        MessageView.span(marker(status), marker_style(status)),
        MessageView.span(subagent_status(status), status_style(status)),
        MessageView.span("review  ", Theme.style(:muted)),
        MessageView.span(target, Theme.bold(Theme.style(:text))),
        MessageView.span(
          profile <> elapsed_suffix(status, entry.tool_elapsed_ms),
          Theme.style(:muted)
        )
      ])
    ]
  end

  defp header_rows(entry, args, _width) do
    name = entry.tool_name || "unknown"
    target = target(name, args)
    status = entry.tool_status
    shown = watchdog_status(entry)

    state =
      if status == :completed,
        do: [],
        else: [MessageView.span(status_text(shown) <> "  ", status_style(shown))]

    heading =
      if target == "" do
        [MessageView.span(name, Theme.bold(Theme.style(:text)))]
      else
        [
          MessageView.span(name <> "  ", Theme.style(:muted)),
          MessageView.span(target, Theme.bold(Theme.style(:text)))
        ]
      end

    summary =
      if name == "read" and status == :completed and entry.tool_output == "" do
        [MessageView.span("  empty", Theme.style(:subtle))]
      else
        []
      end

    [
      MessageView.row(
        [MessageView.span(marker(shown), marker_style(shown))] ++
          state ++ heading ++ summary
      )
    ]
  end

  # The watchdog's view of a bash call refines the plain execution status.
  defp watchdog_status(%{tool_status: :running, tool_watched?: true}), do: :watched

  defp watchdog_status(%{tool_name: "bash", tool_status: :failed, tool_output: output}) do
    if Tackle.Watchdog.stopped?(output), do: :stopped, else: :failed
  end

  defp watchdog_status(%{tool_status: status}), do: status

  ## Bash

  # A prompt line: status (unless completed), the directory peeled from a
  # leading `cd`, an accent `$` and the command's first line painted as code.
  # Wraps align under the command, two cells in, so they never line up with
  # output; a command longer than the row budget ends in an explicit `…`.
  defp bash_header(entry, args, width) do
    rows = bash_prompt_rows(entry, args, width)

    if length(rows) > @bash_header_rows do
      {kept, [last]} = rows |> Enum.take(@bash_header_rows) |> Enum.split(-1)
      kept ++ [ellipsize(last, width)]
    else
      rows
    end
  end

  # The uncapped prompt rows; the header shows at most `@bash_header_rows`.
  defp bash_prompt_rows(entry, args, width) do
    shown = watchdog_status(entry)

    status =
      if entry.tool_status == :completed,
        do: [],
        else: [
          MessageView.span(marker(shown), marker_style(shown)),
          MessageView.span(status_text(shown) <> "  ", status_style(shown))
        ]

    {dir, command} =
      case bash_command(entry, args) do
        command when is_binary(command) -> BashView.split_cwd(command)
        nil -> {nil, ""}
      end

    cwd = if dir, do: [MessageView.span(dir <> " ", Theme.style(:subtle))], else: []
    prompt = [MessageView.span("$ ", Theme.style(:accent))]

    command_spans =
      case BashView.line_spans(command) do
        [[]] ->
          [MessageView.span("bash", Theme.style(:muted))]

        [first] ->
          first

        [first | more] ->
          count = length(more)

          first ++
            [MessageView.span("  +#{count} " <> plural(count, "line"), Theme.style(:subtle))]
      end

    wrap_indented([MessageView.row(status ++ cwd ++ prompt ++ command_spans)], width, 2, true)
  end

  # Streamed arguments are raw JSON until the call is complete.
  defp bash_command(%{tool_arguments: raw}, %{"input" => raw}) when is_binary(raw),
    do: partial_field(raw, "command")

  defp bash_command(_entry, args) do
    case get(args, :command) do
      command when is_binary(command) -> command
      _ -> nil
    end
  end

  # Make room for a trailing `…` on a row that already fits the width.
  defp ellipsize(row, width) do
    excess = MessageView.display_width(plain_text(row)) + 1 - width
    spans = row.spans |> Enum.reverse() |> drop_cells(excess) |> Enum.reverse()
    %{row | spans: spans ++ [MessageView.span("…", Theme.style(:subtle))]}
  end

  defp drop_cells(spans, excess) when excess <= 0, do: spans
  defp drop_cells([], _excess), do: []

  defp drop_cells([span | rest], excess) do
    case String.graphemes(span.content) do
      [] ->
        drop_cells(rest, excess)

      graphemes ->
        {kept, [last]} = Enum.split(graphemes, -1)
        span = %{span | content: Enum.join(kept)}
        drop_cells([span | rest], excess - MessageView.display_width(last))
    end
  end

  defp plain_text(row), do: Enum.map_join(row.spans, & &1.content)

  # The card is a bracket: the prompt opens it, output runs along a `│` rail,
  # and a footer that is always present closes it with `└`. Successful calls
  # show a two-line tail and say how much is above it; failures keep both
  # ends. Shown lines lose the indentation they share, so indented source in
  # the output does not drift away from the rail.
  defp bash_body(%{tool_status: status} = entry, _args, :preview, width)
       when status in [:running, :completed, :failed] do
    shown = watchdog_status(entry)

    {output, code} =
      if status == :failed,
        do: BashView.outcome(entry.tool_output),
        else: {entry.tool_output || "", nil}

    tone =
      case shown do
        :failed -> :error
        :stopped -> :warning
        _ -> :muted
      end

    lines = BashView.output_lines(output)
    count = length(lines)

    {head, hint, tail} =
      cond do
        status == :failed and count > 4 ->
          {Enum.take(lines, 2), "… #{count - 4} more " <> plural(count - 4, "line"),
           Enum.take(lines, -2)}

        status != :failed and count > 2 ->
          {[], "… #{count - 2} " <> plural(count - 2, "line") <> " above", Enum.take(lines, -2)}

        true ->
          {lines, nil, []}
      end

    {head, tail} = BashView.dedent(head, tail)
    line = &[MessageView.span(&1, Theme.style(tone))]
    hint = if hint, do: [[MessageView.span(hint, Theme.style(:subtle))]], else: []

    rail(Enum.map(head, line) ++ hint ++ Enum.map(tail, line), bash_footer(entry, code), width)
  end

  defp bash_body(_entry, _args, :preview, _width), do: []

  # Details print the whole submitted command, then every output line as the
  # tool returned it.
  defp bash_body(entry, args, :details, width) do
    # The header already shows a command that fits; repeat only one it cut.
    command =
      case bash_command(entry, args) do
        command when is_binary(command) ->
          lines = BashView.line_spans(command)

          if length(lines) > 1 or
               length(bash_prompt_rows(entry, args, width)) > @bash_header_rows,
             do: [context_row("Command") | Enum.map(lines, &MessageView.row/1)],
             else: []

        nil ->
          []
      end

    timeout =
      case get(args, :timeout) do
        seconds when is_number(seconds) -> [context_row("Timeout: #{seconds}s")]
        _ -> []
      end

    output =
      if is_binary(entry.tool_output),
        do: [context_row("Output") | output_rows(entry, :details)],
        else: []

    code = if entry.tool_status == :failed, do: elem(BashView.outcome(entry.tool_output), 1)
    footer = MessageView.row(bash_footer(entry, code))

    wrap_indented(command ++ timeout ++ output ++ [footer], width, 4)
  end

  # The closing row: `✓` and the time once a call succeeded, the exit code and
  # time when it failed, the running clock while it runs. A call without an
  # observed time (resumed sessions) still closes with its outcome.
  defp bash_footer(entry, code) do
    time =
      case entry.tool_elapsed_ms do
        ms when is_integer(ms) and ms >= 0 ->
          [MessageView.span(BashView.elapsed(ms, entry.tool_status), Theme.style(:subtle))]

        _ ->
          []
      end

    outcome =
      case {entry.tool_status, watchdog_status(entry)} do
        {:completed, _} ->
          [MessageView.span("✓", Theme.style(:success))]

        {:failed, _} when is_integer(code) and code != 0 ->
          [MessageView.span("exit #{code}", Theme.style(:error))]

        {:failed, shown} ->
          [MessageView.span(status_text(shown), status_style(shown))]

        {_running, shown} when time == [] ->
          [MessageView.span(status_text(shown), Theme.style(:subtle))]

        _running ->
          []
      end

    case {outcome, time} do
      {[], time} -> time
      {outcome, []} -> outcome
      {[%{content: "✓"}] = check, time} -> check ++ [MessageView.span(" ")] ++ time
      {outcome, time} -> outcome ++ [MessageView.span(" · ", Theme.style(:subtle))] ++ time
    end
  end

  # Output rows run along a `│` rail under the prompt and the footer closes it
  # with `└`, so the card's end is visible. Each row is clipped to one line.
  # Narrow terminals drop the rail rather than the content.
  defp rail(rows, footer, width) when width > 5 do
    rail =
      Enum.map(
        rows,
        &[MessageView.span("  │ ", Theme.style(:subtle)) | clip_spans(&1, width - 4)]
      )

    close = [MessageView.span("  └ ", Theme.style(:subtle)) | clip_spans(footer, width - 4)]
    Enum.map(rail ++ [close], &MessageView.row/1)
  end

  defp rail(rows, footer, width),
    do: Enum.map(rows ++ [footer], &MessageView.row(clip_spans(&1, width)))

  defp clip_spans(spans, width) do
    text = Enum.map_join(spans, & &1.content)

    if MessageView.display_width(text) <= width,
      do: spans,
      else: [%{hd(spans) | content: clip_width(text, width)}]
  end

  defp plural(1, noun), do: noun
  defp plural(_count, noun), do: noun <> "s"

  defp body_rows(%{tool_name: "subagent_wait", tool_status: status}, _args, :preview, _width)
       when status in [:requested, :running] do
    [context_row("Waiting for subagent · F4 → Enter to follow its conversation")]
  end

  defp body_rows(%{tool_name: name} = entry, _args, :preview, _width)
       when name in ["subagent_wait", "subagent_status"],
       do: output_rows(entry, :preview)

  defp body_rows(%{tool_name: "subagent"} = entry, args, :preview, _width) do
    assignment =
      case get(args, :prompt) do
        prompt when is_binary(prompt) ->
          # Only paint is shortened; search, copy and details retain the source.
          prompt = prompt |> MessageView.sanitize() |> String.replace(~r/\s+/u, " ")

          preview =
            if String.length(prompt) > 240,
              do: String.slice(prompt, 0, 240) <> "…",
              else: prompt

          [body_row(Theme.style(:muted), "Task: " <> preview)]

        _ ->
          [body_row(Theme.style(:subtle), "Task unavailable")]
      end

    assignment ++ subagent_work_rows(entry) ++ output_rows(entry, :preview)
  end

  defp body_rows(%{tool_name: "subagent"} = entry, args, :details, _width) do
    output = entry.tool_output || entry.subagent_output
    generic_rows(%{entry | tool_output: output}, args, :details)
  end

  defp body_rows(
         %{tool_name: "run_workflow", tool_status: :failed} = entry,
         args,
         :preview,
         _width
       ),
       do:
         workflow_chain_rows(entry) ++
           output_rows(entry, :preview) ++ workflow_error_rows(entry, args)

  # A settled workflow folds its chart into one line above the result.
  defp body_rows(
         %{
           tool_name: "run_workflow",
           tool_status: :completed,
           workflow_progress: %{stages: [_ | _]}
         } =
           entry,
         _args,
         :preview,
         _width
       ),
       do: workflow_chain_rows(entry) ++ output_rows(entry, :preview)

  defp body_rows(%{tool_name: "run_workflow"} = entry, args, :preview, _width) do
    summary =
      cond do
        name = workflow_name(entry, args) -> context_row("Saved workflow · #{name}")
        script = workflow_script(entry, args) -> context_row(workflow_label(script))
        entry.tool_status == :preparing -> context_row("Script incoming")
        true -> context_row("Script unavailable")
      end

    [summary | output_rows(entry, :preview)]
  end

  defp body_rows(%{tool_name: "run_workflow"} = entry, args, :details, width) do
    case workflow_script(entry, args) do
      nil ->
        workflow_graph_rows(entry, width) ++ generic_rows(entry, args, :details)

      script ->
        workflow_graph_rows(entry, width) ++ workflow_rows(entry, script)
    end
  end

  defp body_rows(%{tool_name: "review_changes"} = entry, args, :details, width) do
    case ReviewCallView.details(entry.review_call, content_width(width)) do
      [] -> generic_rows(entry, args, :details)
      rows -> [context_row("Progress") | rows] ++ generic_rows(entry, args, :details)
    end
  end

  defp body_rows(%{tool_name: "read", tool_status: :completed}, _args, :preview, _width),
    do: []

  defp body_rows(%{tool_name: name, tool_status: :failed} = entry, _args, :preview, _width)
       when name in ["edit", "write"],
       do: output_rows(entry, :preview)

  defp body_rows(%{tool_name: "edit", tool_status: :failed} = entry, args, :details, _width),
    do: generic_rows(entry, args, :details)

  defp body_rows(entry, args, :details, _width) do
    case entry.tool_name do
      "edit" -> edit_rows(entry, args)
      "write" -> write_rows(entry, args)
      _ -> generic_rows(entry, args, :details)
    end
  end

  defp body_rows(entry, args, :preview, _width), do: generic_rows(entry, args, :preview)

  defp subagent_work_rows(%{subagent_work: work}) when is_binary(work) and work != "" do
    [body_row(Theme.style(:accent_soft), "Now: " <> MessageView.sanitize(work))]
  end

  defp subagent_work_rows(_entry), do: []

  defp workflow_name(%{tool_arguments: raw}, %{"input" => raw}) when is_binary(raw),
    do: WorkflowScript.saved_name(partial_field(raw, "workflow"))

  defp workflow_name(_entry, args), do: WorkflowScript.saved_name(get(args, :workflow))

  # Streamed input is raw JSON until the call is complete; read the script
  # from its decodable prefix like edit and write previews do.
  defp workflow_script(%{tool_arguments: raw}, %{"input" => raw}) when is_binary(raw),
    do: partial_field(raw, "script")

  defp workflow_script(_entry, args) do
    case get(args, :script) do
      script when is_binary(script) -> script
      _ -> nil
    end
  end

  defp workflow_chain_rows(%{workflow_progress: model}) do
    if WorkflowProgress.started?(model),
      do: [context_row(WorkflowView.chain(model))],
      else: []
  end

  defp workflow_graph_rows(%{workflow_progress: model}, width) do
    if WorkflowProgress.started?(model),
      do: [context_row("Progress") | WorkflowView.rows(model, content_width(width), :details)],
      else: []
  end

  # A trailing newline ends the last line; it does not start another.
  defp script_lines(script), do: script |> String.trim_trailing("\n") |> String.split("\n")

  defp workflow_label(script) do
    count = length(script_lines(script))
    "Lua workflow · #{count} " <> if(count == 1, do: "line", else: "lines")
  end

  defp workflow_rows(entry, script) do
    lines = script_lines(script)
    tokens = Highlight.lines(script, @workflow_path)
    number_width = lines |> length() |> Integer.to_string() |> String.length()

    [context_row(workflow_label(script))] ++
      Enum.map(
        Enum.with_index(lines, 1),
        &numbered_code_row(&1, tokens, number_width, Theme.style(:subtle))
      ) ++ result_rows(entry)
  end

  defp result_rows(%{tool_output: nil}), do: []

  defp result_rows(entry) do
    label = if entry.tool_status == :failed, do: "Error", else: "Result"
    [context_row(label) | output_rows(entry, :details)]
  end

  # Workflow errors name the script line they failed at; show that line so the
  # failure reads against its source without opening details.
  defp workflow_error_rows(entry, args) do
    with line when is_integer(line) <- WorkflowScript.error_line(entry.tool_output),
         script when is_binary(script) <- workflow_script(entry, args),
         source when is_binary(source) <- Enum.at(script_lines(script), line - 1) do
      tokens = Highlight.lines(script, @workflow_path)
      number_width = line |> Integer.to_string() |> String.length()
      [numbered_code_row({source, line}, tokens, number_width, Theme.style(:error))]
    else
      _ -> []
    end
  end

  defp numbered_code_row({line, number}, tokens, number_width, gutter_style) do
    gutter = String.pad_leading(Integer.to_string(number), number_width) <> "  "
    MessageView.row([MessageView.span(gutter, gutter_style) | code_spans(line, number, tokens)])
  end

  defp generic_rows(entry, args, mode) do
    muted = Theme.style(:muted)

    argument_rows =
      cond do
        mode == :details -> [body_row(muted, "Arguments: " <> encode(args))]
        entry.tool_name in ["read", "bash"] -> []
        map_size(args) == 0 -> []
        true -> [body_row(muted, String.slice(encode(args), 0, 240))]
      end

    argument_rows ++ output_rows(entry, mode)
  end

  defp clip_width(text, width) do
    if MessageView.display_width(text) <= width do
      text
    else
      {graphemes, _used} =
        text
        |> String.graphemes()
        |> Enum.reduce_while({[], 0}, &keep_grapheme(&1, &2, width))

      Enum.reverse(graphemes) |> Enum.join() |> Kernel.<>("…")
    end
  end

  defp keep_grapheme(grapheme, {kept, used}, width) do
    next = used + MessageView.display_width(grapheme)

    if next < width,
      do: {:cont, {[grapheme | kept], next}},
      else: {:halt, {kept, used}}
  end

  # During input streaming JSON is often incomplete. Extract only string values
  # we can decode; never paint the escaped JSON envelope in the inline card.
  defp partial_field(raw, key) do
    # A value may end mid-string (or mid-escape); decode only its complete
    # escaped prefix. JSON.decode handles quoted characters and Unicode escapes.
    pattern = ~r/(?<!\\)"#{key}"\s*:\s*"((?:\\.|[^"\\])*)/s

    with [_, escaped] <- Regex.run(pattern, raw),
         {:ok, value} <- JSON.decode("\"" <> escaped <> "\"") do
      value
    else
      _ -> nil
    end
  end

  defp write_rows(entry, args) do
    case get(args, :content) do
      content when is_binary(content) ->
        lines = String.split(content, "\n", trim: false)
        tokens = Highlight.lines(content, get(args, :path))

        header =
          [
            body_row(
              Theme.style(:subtle),
              "Content preview (#{length(lines)} lines; prior file not compared)"
            )
          ]

        rows = header ++ code_rows(lines, tokens)

        rows ++ output_rows(entry, :details)

      _ ->
        generic_rows(entry, args, :details)
    end
  end

  defp code_rows(lines, tokens),
    do: lines |> Enum.with_index(1) |> Enum.map(&code_row(&1, tokens))

  defp edit_rows(entry, args) do
    edits = get(args, :edits)

    if is_list(edits) and edits != [] do
      [context_row("Submitted text (not a verified file diff)")] ++
        (edits
         |> Enum.with_index(1)
         |> Enum.flat_map(fn {edit, index} -> replacement(edit, index, get(args, :path)) end)) ++
        output_rows(entry, :details)
    else
      generic_rows(entry, args, :details)
    end
  end

  defp output_rows(%{tool_output: nil}, _mode), do: []

  defp output_rows(entry, mode) do
    text_style =
      if entry.tool_status == :failed,
        do: Theme.style(:error),
        else: Theme.style(:muted)

    lines = String.split(entry.tool_output, "\n", trim: false)

    shown =
      cond do
        mode == :details ->
          Enum.map(lines, &{:line, &1})

        Enum.count_until(lines, 5) <= 4 ->
          Enum.map(lines, &{:line, &1})

        true ->
          Enum.map(Enum.take(lines, 2), &{:line, &1}) ++
            [{:hidden, "#{length(lines) - 4} lines hidden"}] ++
            Enum.map(Enum.take(lines, -2), &{:line, &1})
      end

    Enum.map(shown, fn
      {:hidden, text} ->
        body_row(Theme.style(:subtle), text)

      {:line, line} ->
        body_row(text_style, clip_line(line, mode))
    end)
  end

  defp replacement(edit, index, path) when is_map(edit) do
    old = get(edit, :oldText)
    new = get(edit, :newText)

    if is_binary(old) and is_binary(new) do
      {added, removed, rows} = diff_rows(old, new, 0, 0)
      number_width = gutter_width(rows)
      tokens = diff_tokens(old, new, path)

      [replacement_heading(added, removed) | Enum.map(rows, &diff_row(&1, number_width, tokens))]
    else
      [warn_row("Edit #{index}: invalid preview data")]
    end
  end

  defp replacement(_edit, index, _path),
    do: [warn_row("Edit #{index}: invalid preview data")]

  # `similar` matches the lines and marks the changed tokens in Rust; the card
  # owns the palette, wrapping and the row budget. A positive context keeps that
  # many unchanged lines around each change and elides longer runs; 0 prints
  # every submitted line. A positive row budget returns only a head/tail window.
  defp diff_rows(old, new, context, max_rows) do
    {:ok, {added, removed}, rows} = Native.diff_rows(old, new, context, max_rows)
    {added, removed, rows}
  end

  defp replacement_heading(added, removed) do
    MessageView.row([
      MessageView.span("+#{added}", Theme.style(:diff_add)),
      MessageView.span(" "),
      MessageView.span("-#{removed}", Theme.style(:diff_del))
    ])
  end

  # Keep the gutter quiet and the code neutral. Only changed tokens are tinted;
  # markers retain meaning without relying on color or full-width backgrounds.
  # The fill sits on the row style so the tint spans the full terminal
  # width; context rows leave the terminal background alone. The gutter is a
  # right-aligned number as wide as the largest one in the replacement.
  # Syntax highlighting paints the unemphasized code; the stronger intraline
  # tint still wins for changed tokens so the emphasis survives on the fill.
  defp diff_row({tag, number, spans}, number_width, tokens) do
    style = if tag == :ctx, do: Theme.style(:diff_context), else: Theme.style(:text)
    runs = Map.get(if(tag == :del, do: tokens.del, else: tokens.ins), number)

    MessageView.row(
      [
        MessageView.span(
          String.pad_leading(to_string(number), number_width) <> " ",
          gutter_style(tag)
        ),
        MessageView.span(sign(tag) <> " ", diff_style(tag))
        | merge_token_runs(spans, runs)
          |> Enum.map(&content_span(&1, tag, style))
      ],
      fill_style(tag)
    )
  end

  defp diff_row({:elision, count}, _number_width, _tokens),
    do: context_row("#{count} lines hidden")

  # Token styles for both sides of one replacement: removals read from the old
  # text, insertions and context from the new, matching the row numbering.
  defp diff_tokens(old, new, path),
    do: %{del: Highlight.lines(old, path), ins: Highlight.lines(new, path)}

  # Both segmentations concatenate to the same line; walk them together by
  # grapheme so a boundary in either one becomes a boundary in the result.
  # A line the highlighter could not cover keeps its diff runs unstyled.
  @doc false
  @spec merge_token_runs(
          [{String.t(), boolean()}],
          [{String.t(), Style.t() | nil}] | nil
        ) :: [{String.t(), boolean(), Style.t() | nil}]
  def merge_token_runs(diff_spans, nil),
    do: Enum.map(diff_spans, fn {text, emphasized} -> {text, emphasized, nil} end)

  def merge_token_runs(diff_spans, token_runs) do
    diff_graphemes = expand_runs(diff_spans)
    token_graphemes = expand_runs(token_runs)

    if length(diff_graphemes) == length(token_graphemes) do
      diff_graphemes
      |> Enum.zip(token_graphemes)
      |> coalesce_runs([])
    else
      merge_token_runs(diff_spans, nil)
    end
  end

  defp expand_runs(runs) do
    Enum.flat_map(runs, fn {text, meta} ->
      text |> String.graphemes() |> Enum.map(&{&1, meta})
    end)
  end

  defp coalesce_runs([], acc), do: Enum.reverse(acc)

  defp coalesce_runs([{{grapheme, emphasized}, {_same, style}} | rest], acc) do
    case acc do
      [{text, ^emphasized, ^style} | _] ->
        coalesce_runs(rest, [{text <> grapheme, emphasized, style} | tl(acc)])

      _ ->
        coalesce_runs(rest, [{grapheme, emphasized, style} | acc])
    end
  end

  defp fill_style(:ins), do: Theme.style(:diff_add_bg)
  defp fill_style(:del), do: Theme.style(:diff_del_bg)
  defp fill_style(:ctx), do: %Style{}

  defp gutter_style(:ins), do: Theme.style(:diff_add_gutter)
  defp gutter_style(:del), do: Theme.style(:diff_del_gutter)
  defp gutter_style(:ctx), do: Theme.style(:subtle)

  defp content_span({text, true, _token}, tag, _style),
    do: MessageView.span(text, inline_style(tag))

  defp content_span({text, false, nil}, _tag, style), do: MessageView.span(text, style)

  defp content_span({text, false, token}, _tag, _style), do: MessageView.span(text, token)

  defp sign(:del), do: "-"
  defp sign(:ins), do: "+"
  defp sign(:ctx), do: " "

  defp diff_style(:del), do: Theme.style(:diff_del)
  defp diff_style(:ins), do: Theme.style(:diff_add)
  defp diff_style(:ctx), do: Theme.style(:diff_context)

  defp inline_style(:del), do: Theme.style(:diff_del_inline)
  defp inline_style(:ins), do: Theme.style(:diff_add_inline)
  defp inline_style(:ctx), do: Theme.style(:diff_context)

  # Codex-style gutter width: the digit count of the largest line number,
  # at least one cell, so short replacements do not pad to a fixed width.
  defp gutter_width(rows) do
    max =
      Enum.reduce(rows, 0, fn
        {_tag, number, _spans}, max -> max(max, number)
        {:elision, _count}, max -> max
      end)

    max |> to_string() |> String.length() |> max(1)
  end

  defp context_row(text) do
    style = Theme.style(:subtle)
    body_row(style, text)
  end

  defp warn_row(text) do
    style = Theme.style(:warning)
    body_row(style, text)
  end

  defp body_row(text_style, text) do
    MessageView.row([MessageView.span(text, text_style)], text_style)
  end

  # Cap wrapped rows, not only source lines. Keep both ends for diagnostics.
  defp trim(rows, :details, _width), do: rows

  defp trim(rows, :preview, width) when length(rows) > @preview_rows do
    hidden = length(rows) - @preview_rows + 1
    head = div(@preview_rows - 1, 2)
    tail = @preview_rows - 1 - head
    style = Theme.style(:subtle)
    hint = body_row(style, "#{hidden} lines hidden")

    hint = hd(wrap_indented([hint], width, 4))

    Enum.take(rows, head) ++ [hint] ++ Enum.take(rows, -tail)
  end

  defp trim(rows, :preview, _width), do: rows

  # Wrap each logical row inside its gutter. The first header line starts at
  # the edge; its continuations and every body row align four cells in.
  defp wrap_indented(rows, width, indent, header? \\ false) do
    indent = if width > indent + 1, do: indent, else: 0

    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, index} ->
      # Header's first line starts at the edge, but its wraps stay indented.
      first_prefix = if header? and index == 0, do: 0, else: indent
      # Use the continuation's content width for all wraps; the first line
      # gets the same predictable break even without its visible gutter.
      MessageView.wrap_rows([row], max(width - indent, 1))
      |> Enum.with_index()
      |> Enum.map(fn {line, wrap_index} ->
        prefix = if wrap_index == 0, do: first_prefix, else: indent
        %{line | spans: [MessageView.span(String.duplicate(" ", prefix)) | line.spans]}
      end)
    end)
  end

  defp clip_line(line, :preview) when is_binary(line) do
    if String.length(line) > 500,
      do: String.slice(line, 0, 240) <> " … " <> String.slice(line, -240, 240),
      else: line
  end

  defp clip_line(line, :details), do: line

  defp marker(:preparing), do: "◐ "
  defp marker(:running), do: "● "
  defp marker(:watched), do: "◉ "
  defp marker(:stopped), do: "⊘ "
  defp marker(:failed), do: "✗ "
  defp marker(_), do: "  "

  defp marker_style(:failed), do: Theme.style(:error)
  defp marker_style(:preparing), do: Theme.style(:accent_soft)
  defp marker_style(:running), do: Theme.style(:accent_soft)
  defp marker_style(:watched), do: Theme.style(:accent_soft)
  defp marker_style(:stopped), do: Theme.style(:warning)
  defp marker_style(:completed), do: Theme.style(:subtle)
  defp marker_style(_), do: Theme.style(:muted)

  # Live calls show a running clock; completed ones only whole seconds.
  defp elapsed_suffix(:completed, ms) when is_integer(ms) and ms >= 0, do: "  #{div(ms, 1_000)}s"
  defp elapsed_suffix(_status, ms) when is_integer(ms) and ms >= 0, do: "  " <> elapsed_text(ms)
  defp elapsed_suffix(_status, _ms), do: ""

  defp elapsed_text(ms) do
    seconds = div(ms, 1_000)
    if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp subagent_status(:completed), do: ""
  defp subagent_status(status), do: status_text(status) <> "  "

  defp status_text(:preparing), do: "preparing"
  defp status_text(:running), do: "running"
  defp status_text(:watched), do: "running"
  defp status_text(:stopped), do: "stopped"
  defp status_text(:failed), do: "failed"
  defp status_text(_), do: "requested"

  defp status_style(:preparing), do: Theme.style(:accent_soft)
  defp status_style(:failed), do: Theme.style(:error)
  defp status_style(:running), do: Theme.style(:accent_soft)
  defp status_style(:watched), do: Theme.style(:accent_soft)
  defp status_style(:stopped), do: Theme.style(:warning)
  defp status_style(_), do: Theme.style(:subtle)

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp encode(value) do
    JSON.encode!(value)
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] -> inspect(value)
  end
end
