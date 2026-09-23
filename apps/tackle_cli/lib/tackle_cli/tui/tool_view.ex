defmodule Tackle.CLI.TUI.ToolView do
  @moduledoc """
  Built-in, render-only tool cards.

  Cards are borderless: a quiet dot for completed calls (not an emoji check),
  colored activity/failure markers, and a prominent command/path. Preview rows
  use a two-cell hanging indent. Completed calls omit redundant status text;
  running, requested and failed calls stay explicit. Successful reads collapse
  to their path; successful Bash output shows at most two clipped tail lines.
  Full retained output stays in details. Failed edits show the error instead of
  a replacement preview (details retain the submitted arguments as source).
  Subagents show their profile, assignment, explicit status, and locally observed
  elapsed time while the turn is live. Full arguments and findings stay in details.
  Unknown tools retain a generic source fallback.

  Edit previews compare the submitted replacement strings, never files on disk.
  They are not authoritative file diffs; line numbers are relative to each
  replacement. `similar` matches the lines in Rust and marks the tokens that
  changed inside an otherwise similar line, so a one-word change stays legible
  instead of reading as a whole-line rewrite. Rows keep the terminal background
  and neutral code text, with soft-colored `+`/`-` markers and a compact number
  gutter. Only changed tokens receive a tint. The preview keeps a line of context
  around each change and elides longer unchanged runs; details print every
  submitted line. A replacement too large to match falls back to a bounded
  before/after window. Execution outcome and preview provenance remain
  separate.
  """

  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.{MessageView, Theme}

  @preview_rows 6
  @preview_context 1
  @header_rows 2

  @doc "A compact, source-independent title for a tool call."
  def title(name, arguments, status) do
    target = target(name, arguments)
    "#{marker(status)} #{name}" <> if(target == "", do: "", else: "  " <> target)
  end

  @doc "Renders a bounded inline card or complete retained details."
  def render(entry, width, mode \\ :preview) do
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
      |> wrap_indented(width, 2, true)
      |> truncate_header(width)

    body =
      entry
      |> body_rows(args, mode, width)
      |> wrap_indented(width, 2)
      |> trim(mode, width)

    MessageView.render_lines(header ++ body)
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
        ms when is_integer(ms) and ms >= 0 -> " · " <> elapsed_text(ms)
        _ -> ""
      end

    model =
      case Map.get(entry, :model) do
        model when is_binary(model) and model != "" -> " · " <> model
        _ -> ""
      end

    [
      MessageView.row([
        MessageView.span(marker(status) <> " ", marker_style(status)),
        MessageView.span(status_text(status) <> " · ", status_style(status)),
        MessageView.span(profile, Theme.bold(Theme.style(:text))),
        MessageView.span(" · subagent" <> model <> elapsed, Theme.style(:muted))
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
        else: [MessageView.span(status_text(status) <> " · ", status_style(status))]

    heading =
      if target == "" do
        [MessageView.span(name, Theme.bold(Theme.style(:text)))]
      else
        [
          MessageView.span(target, Theme.bold(Theme.style(:text))),
          MessageView.span("  · " <> name, Theme.style(:muted))
        ]
      end

    summary =
      if name == "read" and status == :completed and is_binary(entry.tool_output) do
        text = if entry.tool_output == "", do: "  · empty", else: "  · F4 details"
        [MessageView.span(text, Theme.style(:subtle))]
      else
        []
      end

    [
      MessageView.row(
        [MessageView.span(marker(status) <> " ", marker_style(status))] ++
          state ++ heading ++ summary
      )
    ]
  end

  defp body_rows(%{tool_name: "subagent"} = entry, args, :preview, _width) do
    assignment =
      case get(args, :prompt) do
        prompt when is_binary(prompt) ->
          # Only paint is shortened; search, copy and details retain the source.
          prompt = prompt |> MessageView.sanitize() |> String.replace(~r/\s+/u, " ")

          preview =
            if String.length(prompt) > 240,
              do: String.slice(prompt, 0, 240) <> "… · F4 details",
              else: prompt

          [body_row(Theme.style(:muted), "Task: " <> preview)]

        _ ->
          [body_row(Theme.style(:subtle), "Task unavailable · F4 details")]
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

  defp body_rows(
         %{tool_name: name, tool_status: :preparing, tool_arguments: raw} = entry,
         %{"input" => raw},
         :preview,
         _width
       )
       when name in ["edit", "write"] and is_binary(raw),
       do: incoming_file_rows(entry, raw)

  defp body_rows(%{tool_name: "edit", tool_status: :failed} = entry, _args, :preview, _width),
    do: output_rows(entry, :preview)

  defp body_rows(%{tool_name: "edit", tool_status: :failed} = entry, args, :details, _width),
    do: generic_rows(entry, args, :details)

  defp body_rows(entry, args, mode, _width) do
    case entry.tool_name do
      "edit" -> edit_rows(entry, args, mode)
      "write" -> write_rows(entry, args, mode)
      _ -> generic_rows(entry, args, mode)
    end
  end

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
    content_width = if width > 3, do: width - 2, else: max(width, 1)

    lines =
      output
      |> MessageView.sanitize()
      |> String.split("\n", trim: false)
      |> Enum.reject(&(String.trim(&1) == ""))

    tail = Enum.take(lines, -2)
    clipped? = Enum.any?(tail, &(MessageView.display_width(&1) > content_width))

    hint =
      if Enum.count_until(lines, 3) == 3 or clipped?,
        do: [body_row(Theme.style(:subtle), "… F4 details" |> clip_width(content_width))],
        else: []

    hint ++ Enum.map(tail, &body_row(Theme.style(:muted), clip_width(&1, content_width)))
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
  defp incoming_file_rows(%{tool_name: "write"}, raw) do
    incoming_text_rows("Content incoming · partial", partial_field(raw, "content"))
  end

  defp incoming_file_rows(%{tool_name: "edit"}, raw) do
    text = partial_field(raw, "newText") || partial_field(raw, "oldText")
    incoming_text_rows("Replacement incoming · partial", text)
  end

  defp incoming_text_rows(label, text) do
    heading = [context_row(label <> " · F4 details")]

    if is_binary(text) do
      heading ++
        (text
         |> String.split("\n", trim: false)
         |> Enum.take(@preview_rows - 1)
         |> Enum.map(&body_row(Theme.style(:text), clip_line(&1, :preview))))
    else
      heading
    end
  end

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

  defp write_rows(entry, args, mode) do
    case get(args, :content) do
      content when is_binary(content) ->
        lines = String.split(content, "\n", trim: false)
        shown = if mode == :preview, do: Enum.take(lines, @preview_rows), else: lines

        header =
          [
            body_row(
              Theme.style(:subtle),
              "Content preview · #{length(lines)} lines · prior file not compared"
            )
          ]

        rows =
          header ++
            Enum.map(shown, fn line ->
              body_row(Theme.style(:text), line)
            end)

        rows ++ result_rows(entry, mode)

      _ ->
        generic_rows(entry, args, mode)
    end
  end

  defp edit_rows(entry, args, mode) do
    edits = get(args, :edits)

    if is_list(edits) and edits != [] do
      # Bound work as well as paint for a large batch; the details retain all edits.
      shown = if mode == :preview, do: Enum.take(edits, 2), else: edits

      rows =
        if mode == :details,
          do: [context_row("Replacement preview · not a verified file diff")],
          else: []

      rows =
        rows ++
          (shown
           |> Enum.with_index(1)
           |> Enum.flat_map(fn {edit, index} -> replacement(edit, index, mode) end))

      rows ++ result_rows(entry, mode)
    else
      generic_rows(entry, args, mode)
    end
  end

  defp result_rows(entry, :preview) do
    if entry.tool_status == :failed, do: output_rows(entry, :preview), else: []
  end

  defp result_rows(entry, :details), do: output_rows(entry, :details)

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
            [{:hidden, "… #{length(lines) - 4} lines hidden · F4 details"}] ++
            Enum.map(Enum.take(lines, -2), &{:line, &1})
      end

    Enum.map(shown, fn
      {:hidden, text} ->
        body_row(Theme.style(:subtle), text)

      {:line, line} ->
        body_row(text_style, clip_line(line, mode))
    end)
  end

  defp replacement(edit, index, mode) when is_map(edit) do
    old = get(edit, :oldText)
    new = get(edit, :newText)

    if is_binary(old) and is_binary(new) do
      {added, removed, rows} = diff_rows(old, new, mode)
      [replacement_heading(index, mode, added, removed) | Enum.map(rows, &diff_row/1)]
    else
      [warn_row("Replacement #{index}: invalid preview data")]
    end
  end

  defp replacement(_edit, index, _mode),
    do: [warn_row("Replacement #{index}: invalid preview data")]

  # `similar` matches the lines and marks the changed tokens in Rust; the card
  # owns the palette, wrapping and the row budget. A positive context keeps that
  # many unchanged lines around each change and elides longer runs; 0 prints
  # every submitted line. A positive row budget returns only a head/tail window.
  defp diff_rows(old, new, :preview),
    do: diff_rows(old, new, @preview_context, @preview_rows)

  defp diff_rows(old, new, :details), do: diff_rows(old, new, 0, 0)

  defp diff_rows(old, new, context, max_rows) do
    {:ok, {added, removed}, rows} = Native.diff_rows(old, new, context, max_rows)
    {added, removed, rows}
  end

  defp replacement_heading(index, mode, added, removed) do
    label = if mode == :preview, do: "Replacement preview #{index}", else: "replacement #{index}"
    lines = if mode == :preview, do: "local lines", else: "relative lines"

    MessageView.row([
      MessageView.span(label <> " · ", Theme.style(:muted)),
      MessageView.span("+#{added}", Theme.style(:diff_add)),
      MessageView.span(" "),
      MessageView.span("-#{removed}", Theme.style(:diff_del)),
      MessageView.span(" · " <> lines, Theme.style(:subtle))
    ])
  end

  # Keep the gutter quiet and the code neutral. Only changed tokens are tinted;
  # markers retain meaning without relying on color or full-width backgrounds.
  defp diff_row({tag, number, spans}) do
    style = if tag == :ctx, do: Theme.style(:diff_context), else: Theme.style(:text)

    MessageView.row([
      MessageView.span(String.pad_leading(to_string(number), 3) <> " ", Theme.style(:subtle)),
      MessageView.span(sign(tag) <> " ", diff_style(tag))
      | Enum.map(spans, &content_span(&1, tag, style))
    ])
  end

  defp diff_row({:elision, count}), do: context_row("… #{count} lines hidden · F4 details")

  defp content_span({text, true}, tag, _style), do: MessageView.span(text, inline_style(tag))
  defp content_span({text, false}, _tag, style), do: MessageView.span(text, style)

  defp sign(:del), do: "-"
  defp sign(:ins), do: "+"
  defp sign(:ctx), do: " "

  defp diff_style(:del), do: Theme.style(:diff_del)
  defp diff_style(:ins), do: Theme.style(:diff_add)
  defp diff_style(:ctx), do: Theme.style(:diff_context)

  defp inline_style(:del), do: Theme.style(:diff_del_inline)
  defp inline_style(:ins), do: Theme.style(:diff_add_inline)
  defp inline_style(:ctx), do: Theme.style(:diff_context)

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
    hint = body_row(style, "… #{hidden} lines hidden · F4 details")

    hint = hd(wrap_indented([hint], width, 2))

    Enum.take(rows, head) ++ [hint] ++ Enum.take(rows, -tail)
  end

  defp trim(rows, :preview, _width), do: rows

  # Wrap each logical row inside its gutter. The first header line starts at
  # the edge; its continuations and every body row align two cells in.
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

  defp truncate_header(rows, width) when length(rows) > @header_rows do
    hint = MessageView.row("  … · F4 details", Theme.style(:subtle))
    [hd(rows), hd(MessageView.wrap_rows([hint], width))]
  end

  defp truncate_header(rows, _width), do: rows

  defp clip_line(line, :preview) when is_binary(line) do
    if String.length(line) > 500,
      do: String.slice(line, 0, 240) <> " … " <> String.slice(line, -240, 240),
      else: line
  end

  defp clip_line(line, :details), do: line

  defp marker(:preparing), do: "◐"
  defp marker(:running), do: "●"
  defp marker(:failed), do: "✗"
  defp marker(:completed), do: "·"
  defp marker(_), do: "›"

  defp marker_style(:failed), do: Theme.style(:error)
  defp marker_style(:preparing), do: Theme.style(:accent_soft)
  defp marker_style(:running), do: Theme.style(:accent_soft)
  defp marker_style(:completed), do: Theme.style(:subtle)
  defp marker_style(_), do: Theme.style(:muted)

  defp elapsed_text(ms) do
    seconds = div(ms, 1_000)
    if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp status_text(:preparing), do: "preparing"
  defp status_text(:completed), do: "completed"
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
