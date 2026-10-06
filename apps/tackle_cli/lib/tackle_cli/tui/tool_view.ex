defmodule Tackle.CLI.TUI.ToolView do
  @moduledoc """
  Built-in, render-only tool cards.

  Cards are borderless: completed calls have no marker, while activity/failure
  markers accompany a prominent path or subdued command. Preview rows use a four-cell
  hanging indent. Completed calls omit redundant status text;
  running, requested and failed calls stay explicit. Successful reads collapse
  to a tool/path header; successful Bash output shows at most two clipped tail
  lines.
  Full retained output stays in details. Failed edits/writes show the error instead of
  submitted changes (details retain the submitted arguments as source).
  Subagents show their profile, assignment, live status, and locally observed
  elapsed time when available. Completed subagents show just the elapsed seconds
  instead of a completion label. Full arguments and findings stay in details.
  Unknown tools retain a generic source fallback.

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
  alias Tackle.CLI.TUI.{Highlight, MessageView, Theme, ToolGroups}

  @preview_rows 6
  @file_preview_rows 16
  @preview_replacements 2
  @preview_context 1
  @header_rows 2

  @doc "A compact, source-independent title for a tool call."
  def title(name, arguments, _status) do
    target = target(name, arguments)
    name <> if(target == "", do: "", else: "  " <> target)
  end

  @doc "Renders a bounded inline card or retained details; `:code_rows` budgets edit/write preview rows."
  @spec render(MessageView.t(), pos_integer(), :preview | :details, keyword()) ::
          [MessageView.widget_item()]
  def render(entry, width, mode \\ :preview, opts \\ [])

  def render(%{tool_group: members} = entry, width, mode, _opts)
      when is_list(members) and members != [],
      do: group_render(entry, members, width, mode)

  def render(entry, width, mode, opts) do
    args = arguments(entry.tool_arguments)

    header_args =
      if mode == :preview and entry.tool_status == :preparing and
           entry.tool_name in ["edit", "write"] and is_binary(entry.tool_arguments) do
        Map.put(args, "path", partial_field(entry.tool_arguments, "path"))
      else
        args
      end

    header =
      entry
      |> header_rows(header_args, width)
      |> wrap_indented(width, 4, true)
      |> Enum.take(@header_rows)

    body =
      if mode == :preview do
        file_preview(entry, args, width, Keyword.get(opts, :code_rows, @file_preview_rows)) ||
          compact_body(entry, args, mode, width)
      else
        compact_body(entry, args, mode, width)
      end

    MessageView.render_lines(header ++ body)
  end

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
        "subagent" -> get(args, :profile)
        "bash" -> get(args, :command)
        name when name in ["read", "edit", "write"] -> get(args, :path)
        _ -> get(args, :path) || get(args, :command)
      end

    if is_binary(value), do: value, else: ""
  end

  defp header_rows(%{tool_name: "subagent"} = entry, args, _width) do
    profile = target("subagent", args)
    profile = if profile == "", do: "unknown profile", else: profile
    status = entry.tool_status

    elapsed =
      case entry.tool_elapsed_ms do
        ms when is_integer(ms) and ms >= 0 and status != :completed -> "  " <> elapsed_text(ms)
        _ -> ""
      end

    completed_time =
      case {status, entry.tool_elapsed_ms} do
        {:completed, ms} when is_integer(ms) and ms >= 0 -> "  #{div(ms, 1_000)}s"
        _ -> ""
      end

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
        MessageView.span(model <> elapsed <> completed_time, Theme.style(:muted))
      ])
    ]
  end

  defp header_rows(entry, args, _width) do
    name = entry.tool_name || "unknown"
    target = target(name, args)
    status = entry.tool_status

    state =
      if status == :completed,
        do: [],
        else: [MessageView.span(status_text(status) <> "  ", status_style(status))]

    heading =
      if target == "" do
        [MessageView.span(name, Theme.bold(Theme.style(:text)))]
      else
        [
          MessageView.span(name <> "  ", Theme.style(:muted)),
          MessageView.span(target, target_style(name))
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
        [MessageView.span(marker(status), marker_style(status))] ++
          state ++ heading ++ summary
      )
    ]
  end

  # Commands are often paragraphs long; reserve bold emphasis for file targets.
  defp target_style(name) when name in ["bash", "elixir_eval"], do: Theme.style(:muted)
  defp target_style(_name), do: Theme.bold(Theme.style(:text))

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

  defp body_rows(%{tool_name: "read", tool_status: :completed}, _args, :preview, _width),
    do: []

  defp body_rows(%{tool_name: "bash", tool_status: status} = entry, _args, :preview, width)
       when status in [:running, :completed],
       do: bash_preview(entry.tool_output, width)

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

  # Successful shell output is a two-line tail, not a wrapped wall of logs.
  # Clip only paint; the inspector, search and copy keep the original output.
  defp bash_preview(nil, _width), do: []

  defp bash_preview(output, width) do
    content_width = if width > 5, do: width - 4, else: max(width, 1)

    lines =
      output
      |> MessageView.sanitize()
      |> String.split("\n", trim: false)
      |> Enum.reject(&(String.trim(&1) == ""))

    tail = Enum.take(lines, -2)
    Enum.map(tail, &body_row(Theme.style(:muted), clip_width(&1, content_width)))
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
  defp marker(:failed), do: "✗ "
  defp marker(_), do: "  "

  defp marker_style(:failed), do: Theme.style(:error)
  defp marker_style(:preparing), do: Theme.style(:accent_soft)
  defp marker_style(:running), do: Theme.style(:accent_soft)
  defp marker_style(:completed), do: Theme.style(:subtle)
  defp marker_style(_), do: Theme.style(:muted)

  defp elapsed_text(ms) do
    seconds = div(ms, 1_000)
    if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp subagent_status(:completed), do: ""
  defp subagent_status(status), do: status_text(status) <> "  "

  defp status_text(:preparing), do: "preparing"
  defp status_text(:running), do: "running"
  defp status_text(:failed), do: "failed"
  defp status_text(_), do: "requested"

  defp status_style(:preparing), do: Theme.style(:accent_soft)
  defp status_style(:failed), do: Theme.style(:error)
  defp status_style(:running), do: Theme.style(:accent_soft)
  defp status_style(_), do: Theme.style(:subtle)

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp encode(value) do
    JSON.encode!(value)
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] -> inspect(value)
  end
end
