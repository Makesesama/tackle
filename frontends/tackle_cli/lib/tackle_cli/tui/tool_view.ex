defmodule Tackle.CLI.TUI.ToolView do
  @moduledoc """
  Built-in, render-only tool cards.

  A card is a full-width band: a `surface_raised` header with the tool name,
  target, and status, then `surface` body rows marked by a status-colored rail.
  Commands and paths are the landmarks, not serialized argument maps. Unknown
  tools retain a generic source fallback.

  Edit previews compare the submitted replacement strings, never files on disk.
  They are not authoritative file diffs; line numbers are relative to each
  replacement. Added and removed rows carry both a `+`/`-` marker and a tinted
  background, so the change survives even where the terminal does not paint
  backgrounds. Execution outcome and preview provenance remain separate.
  """

  alias ExRatatui.Style
  alias Tackle.CLI.TUI.{MessageView, Theme}

  @preview_rows 6
  @header_rows 2
  @diff_bytes 32_000
  @diff_lines 400
  @rail "▌"

  @doc "A compact, source-independent title for a tool call."
  def title(name, arguments, status) do
    target = target(name, arguments)
    "#{marker(status)} #{name}" <> if(target == "", do: "", else: "  " <> target)
  end

  @doc "Renders a bounded inline card or complete retained details."
  def render(entry, width, mode \\ :preview) do
    args = arguments(entry.tool_arguments)
    surface = Theme.style(:surface)

    header =
      entry
      |> header_rows(args, width)
      |> MessageView.wrap_rows(width)
      |> Enum.take(@header_rows)

    body =
      entry
      |> body_rows(args, mode)
      |> MessageView.wrap_rows(width)
      |> trim(mode, surface)

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
        "bash" -> get(args, :command)
        name when name in ["read", "edit", "write"] -> get(args, :path)
        _ -> get(args, :path) || get(args, :command)
      end

    if is_binary(value), do: value, else: ""
  end

  defp header_rows(entry, args, width) do
    surface = Theme.style(:surface_raised)
    name = entry.tool_name || "unknown"
    target = target(name, args)
    status = entry.tool_status

    left =
      [
        MessageView.span(marker(status) <> " ", Theme.merge(surface, marker_style(status))),
        MessageView.span(name, Theme.merge(surface, Theme.bold(Theme.style(:text))))
      ] ++
        if target == "",
          do: [],
          else: [MessageView.span("  " <> target, Theme.merge(surface, Theme.style(:muted)))]

    right = [MessageView.span(status_text(status), Theme.merge(surface, status_style(status)))]

    [MessageView.row(pad_between(left, right, width), surface)]
  end

  defp body_rows(entry, args, mode) do
    case entry.tool_name do
      "edit" -> edit_rows(entry, args, mode)
      "write" -> write_rows(entry, args, mode)
      _ -> generic_rows(entry, args, mode)
    end
  end

  defp generic_rows(entry, args, mode) do
    surface = Theme.style(:surface)
    rail = rail_style(surface, entry.tool_status)
    muted = Theme.merge(surface, Theme.style(:muted))

    argument_rows =
      cond do
        mode == :details -> [body_row(rail, muted, "Arguments: " <> encode(args))]
        entry.tool_name in ["read", "bash"] -> []
        map_size(args) == 0 -> []
        true -> [body_row(rail, muted, String.slice(encode(args), 0, 240))]
      end

    argument_rows ++ output_rows(entry, mode)
  end

  defp write_rows(entry, args, mode) do
    case get(args, :content) do
      content when is_binary(content) ->
        surface = Theme.style(:surface)
        rail = rail_style(surface, entry.tool_status)
        lines = String.split(content, "\n", trim: false)
        shown = if mode == :preview, do: Enum.take(lines, @preview_rows), else: lines

        header =
          [
            body_row(
              rail,
              Theme.merge(surface, Theme.style(:subtle)),
              "Content preview · #{length(lines)} lines · prior file not compared"
            )
          ]

        rows =
          header ++
            Enum.map(shown, fn line ->
              body_row(rail, Theme.merge(surface, Theme.style(:text)), line)
            end)

        rows ++ result_rows(entry, mode)

      _ ->
        generic_rows(entry, args, mode)
    end
  end

  defp edit_rows(entry, args, mode) do
    edits = get(args, :edits)

    if is_list(edits) and edits != [] do
      surface = Theme.style(:surface)
      rail = rail_style(surface, entry.tool_status)

      label =
        if mode == :details,
          do: "Replacement preview · not a verified file diff",
          else: "Replacement preview"

      # Bound work as well as paint for a large batch; the details retain all edits.
      shown = if mode == :preview, do: Enum.take(edits, 2), else: edits

      rows = [
        body_row(rail, Theme.merge(surface, Theme.style(:subtle)), label)
      ]

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
    surface = Theme.style(:surface)
    rail = rail_style(surface, entry.tool_status)

    text_style =
      if entry.tool_status == :failed,
        do: Theme.merge(surface, Theme.style(:error)),
        else: Theme.merge(surface, Theme.style(:muted))

    lines = String.split(entry.tool_output, "\n", trim: false)

    shown =
      cond do
        mode == :details ->
          Enum.map(lines, &{:line, &1})

        length(lines) <= 4 ->
          Enum.map(lines, &{:line, &1})

        true ->
          Enum.map(Enum.take(lines, 2), &{:line, &1}) ++
            [{:hidden, "… #{length(lines) - 4} lines hidden · F4 details"}] ++
            Enum.map(Enum.take(lines, -2), &{:line, &1})
      end

    Enum.map(shown, fn
      {:hidden, text} ->
        body_row(rail, Theme.merge(surface, Theme.style(:subtle)), text)

      {:line, line} ->
        body_row(rail, text_style, clip_line(line, mode))
    end)
  end

  defp replacement(edit, index, mode) when is_map(edit) do
    old = get(edit, :oldText)
    new = get(edit, :newText)

    if is_binary(old) and is_binary(new) do
      before = String.split(old, "\n", trim: false)
      after_lines = String.split(new, "\n", trim: false)

      operations =
        if byte_size(old) + byte_size(new) <= @diff_bytes and
             length(before) + length(after_lines) <= @diff_lines do
          List.myers_difference(before, after_lines)
        else
          # Avoid quadratic matching on huge replacements. Still show honest
          # before/after data, with complete source available in details.
          [del: before, ins: after_lines]
        end

      added = operations |> Keyword.get_values(:ins) |> List.flatten() |> length()
      removed = operations |> Keyword.get_values(:del) |> List.flatten() |> length()

      label =
        if mode == :details,
          do: "@@ replacement #{index} · +#{added} -#{removed} · relative lines @@",
          else: "@@ #{index} · +#{added} -#{removed} · local lines @@"

      [context_row(label) | diff_rows(operations, mode)]
    else
      [warn_row("Replacement #{index}: invalid preview data")]
    end
  end

  defp replacement(_edit, index, _mode),
    do: [warn_row("Replacement #{index}: invalid preview data")]

  defp diff_rows(operations, mode) do
    {rows, _old_line, _new_line} =
      Enum.reduce(operations, {[], 1, 1}, fn {kind, lines}, {rows, old_line, new_line} ->
        count = length(lines)
        shown = if mode == :preview, do: Enum.take(lines, @preview_rows), else: lines

        rendered =
          shown
          |> Enum.with_index()
          |> Enum.map(fn {line, offset} ->
            diff_row_for(kind, line, offset, old_line, new_line)
          end)

        rendered =
          if length(shown) < count,
            do: rendered ++ [context_row("… #{count - length(shown)} lines hidden · F4 details")],
            else: rendered

        {rows ++ rendered, old_line + if(kind == :ins, do: 0, else: count),
         new_line + if(kind == :del, do: 0, else: count)}
      end)

    rows
  end

  defp diff_row_for(:del, line, offset, old_line, _new_line) do
    diff_row("-", old_line + offset, line, Theme.style(:diff_del))
  end

  defp diff_row_for(:ins, line, offset, _old_line, new_line) do
    diff_row("+", new_line + offset, line, Theme.style(:diff_add))
  end

  defp diff_row_for(:eq, line, offset, _old_line, new_line) do
    diff_row(" ", new_line + offset, line, Theme.style(:diff_context))
  end

  defp diff_row(sign, number, line, style) do
    marker_style = Theme.merge(style, %Style{modifiers: [:bold]})
    number_style = Theme.merge(style, Theme.style(:subtle))

    MessageView.row(
      [
        MessageView.span(@rail <> " ", marker_style),
        MessageView.span(String.pad_leading(to_string(number), 3) <> " │ ", number_style),
        MessageView.span(sign <> "  ", marker_style),
        MessageView.span(line, style)
      ],
      style
    )
  end

  defp context_row(text) do
    surface = Theme.style(:surface)
    style = Theme.merge(surface, Theme.style(:subtle))
    body_row(style, style, text)
  end

  defp warn_row(text) do
    surface = Theme.style(:surface)
    style = Theme.merge(surface, Theme.style(:warning))
    body_row(style, style, text)
  end

  defp body_row(rail, text_style, text) do
    MessageView.row(
      [MessageView.span(@rail <> " ", rail), MessageView.span(text, text_style)],
      text_style
    )
  end

  # Cap wrapped rows, not only source lines. Keep both ends for diagnostics.
  defp trim(rows, :details, _surface), do: rows

  defp trim(rows, :preview, surface) when length(rows) > @preview_rows do
    hidden = length(rows) - @preview_rows + 1
    head = div(@preview_rows - 1, 2)
    tail = @preview_rows - 1 - head
    style = Theme.merge(surface, Theme.style(:subtle))
    hint = body_row(style, style, "… #{hidden} lines hidden · F4 details")

    Enum.take(rows, head) ++ [hint] ++ Enum.take(rows, -tail)
  end

  defp trim(rows, :preview, _surface), do: rows

  defp pad_between(left, right, width) do
    gap = width - spans_width(left) - spans_width(right)

    if gap >= 1 do
      left ++ [MessageView.span(String.duplicate(" ", gap), %Style{})] ++ right
    else
      left ++ [MessageView.span(" ", %Style{})] ++ right
    end
  end

  defp spans_width(spans) do
    Enum.reduce(spans, 0, fn span, total -> total + MessageView.display_width(span.content) end)
  end

  defp clip_line(line, :preview) when is_binary(line) do
    if String.length(line) > 500,
      do: String.slice(line, 0, 240) <> " … " <> String.slice(line, -240, 240),
      else: line
  end

  defp clip_line(line, :details), do: line

  # A completed card uses a quiet rail so the color signal is reserved for
  # work in flight and failures; diff rows keep their own sign colors.
  defp rail_style(surface, :running), do: Theme.merge(surface, Theme.style(:accent_soft))
  defp rail_style(surface, :failed), do: Theme.merge(surface, Theme.style(:error))
  defp rail_style(surface, _status), do: Theme.merge(surface, Theme.style(:subtle))

  defp marker(:running), do: "●"
  defp marker(:failed), do: "✗"
  defp marker(:completed), do: "✓"
  defp marker(_), do: "›"

  defp marker_style(:failed), do: Theme.style(:error)
  defp marker_style(:running), do: Theme.style(:accent_soft)
  defp marker_style(:completed), do: Theme.style(:success)
  defp marker_style(_), do: Theme.style(:muted)

  defp status_text(:running), do: "running"
  defp status_text(:failed), do: "failed"
  defp status_text(:completed), do: "completed"
  defp status_text(_), do: "requested"

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
