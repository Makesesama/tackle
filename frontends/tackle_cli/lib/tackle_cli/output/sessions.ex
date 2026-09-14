defmodule Tackle.CLI.Output.Sessions do
  @moduledoc "Renders durable session summaries for terminal and machine use."

  alias Tackle.CLI.Output

  @updated_width 12
  @status_width 11
  @messages_width 4
  @session_width 36
  @minimum_title_width 12
  @table_breakpoint 83
  @full_table_breakpoint 98

  @doc "Renders one page of durable sessions using the configured format."
  @spec render(%{sessions: [map()], next_cursor: String.t() | nil}, String.t() | nil, Output.t()) ::
          Owl.Data.t()
  def render(%{sessions: sessions, next_cursor: next_cursor}, _query, %Output{format: :json}) do
    JSON.encode!(%{
      "next_cursor" => next_cursor,
      "sessions" => Enum.map(sessions, &json_session/1)
    })
  end

  def render(%{sessions: sessions}, _query, %Output{format: :plain}) do
    render_plain(sessions)
  end

  def render(
        %{sessions: sessions, next_cursor: next_cursor},
        query,
        %Output{format: :human} = output
      ) do
    render_human(sessions, next_cursor, query, output)
  end

  defp render_human([], _next_cursor, query, output) do
    message =
      case query do
        query when is_binary(query) and query != "" -> "No sessions found for #{inspect(query)}."
        _other -> "No sessions yet."
      end

    Output.style(output, :muted, message)
  end

  defp render_human(sessions, next_cursor, _query, %Output{width: width} = output)
       when width < @table_breakpoint do
    rows = Enum.map(sessions, &render_stacked_session(&1, output))
    with_more_hint(rows, next_cursor, length(sessions), output)
  end

  defp render_human(sessions, next_cursor, _query, %Output{} = output) do
    columns = columns(output)
    header = render_row(header_values(), columns, output, :header)
    divider = Output.style(output, :muted, String.duplicate("─", row_width(columns)))
    rows = Enum.map(sessions, &render_session(&1, columns, output))

    [header, divider | rows]
    |> Enum.intersperse("\n")
    |> with_more_hint(next_cursor, length(sessions), output)
  end

  defp with_more_hint(rows, nil, _count, _output), do: rows

  defp with_more_hint(rows, _next_cursor, count, output) do
    hint =
      Output.style(
        output,
        :muted,
        "Showing the #{count} most recent matches. Use --limit N to show more."
      )

    [rows, "\n", hint]
  end

  defp render_plain(sessions) do
    rows =
      Enum.map(sessions, fn session ->
        [
          timestamp(session.updated_at),
          value(session.status),
          value(session.message_count),
          single_line(title(session)),
          value(session.session_id)
        ]
        |> Enum.map_join("\t", &plain_field/1)
      end)

    Enum.join(
      [["updated", "status", "messages", "title", "session"] |> Enum.join("\t") | rows],
      "\n"
    )
  end

  defp columns(%Output{width: width}) when width >= @full_table_breakpoint do
    fixed = @updated_width + @status_width + @messages_width + @session_width + 8
    title_width = max(width - fixed, @minimum_title_width)

    [
      updated: @updated_width,
      status: @status_width,
      messages: @messages_width,
      title: title_width,
      session: @session_width
    ]
  end

  defp columns(%Output{width: width}) do
    fixed = @status_width + @session_width + 4
    title_width = max(width - fixed, @minimum_title_width)
    [status: @status_width, title: title_width, session: @session_width]
  end

  defp header_values do
    %{
      updated: "UPDATED",
      status: "STATUS",
      messages: "MSGS",
      title: "TITLE",
      session: "SESSION"
    }
  end

  defp render_session(session, columns, output) do
    values = %{
      updated: relative_time(session.updated_at),
      status: value(session.status),
      messages: value(session.message_count),
      title: single_line(title(session)),
      session: value(session.session_id)
    }

    render_row(values, columns, output, :session)
  end

  defp render_stacked_session(session, output) do
    title_width = max(output.width, 1)
    title = session |> title() |> single_line() |> Owl.Data.truncate(title_width)

    metadata =
      [
        value(session.status),
        relative_time(session.updated_at),
        "#{value(session.message_count)} msgs"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" · ")

    [
      Output.style(output, :heading, title),
      "\n  ",
      style_status(output, value(session.status), metadata),
      "\n  ",
      Output.style(output, :muted, value(session.session_id))
    ]
  end

  defp render_row(values, columns, output, kind) do
    columns
    |> Enum.map(fn {name, width} ->
      value = values[name]

      value =
        if kind == :header,
          do: Output.style(output, :heading, value),
          else: style_value(output, name, value)

      align(value, width, name == :messages)
    end)
    |> Enum.intersperse("  ")
  end

  defp style_value(output, :status, status), do: style_status(output, status, status)
  defp style_value(output, :updated, value), do: Output.style(output, :muted, value)
  defp style_value(output, :session, value), do: Output.style(output, :muted, value)
  defp style_value(_output, _name, value), do: value

  defp style_status(output, status, data) when status in ["interrupted", "corrupt"],
    do: Output.style(output, :danger, data)

  defp style_status(output, "active", data), do: Output.style(output, :accent, data)
  defp style_status(output, "recovered", data), do: Output.style(output, :warning, data)
  defp style_status(output, _status, data), do: Output.style(output, :success, data)

  defp align(value, width, right?) do
    value = Owl.Data.truncate(value, width)
    padding = String.duplicate(" ", max(width - Owl.Data.length(value), 0))
    if right?, do: [padding, value], else: [value, padding]
  end

  defp row_width(columns) do
    columns
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
    |> Kernel.+(max(length(columns) - 1, 0) * 2)
  end

  defp title(session), do: session.title || session.preview || "(untitled)"

  defp single_line(value) do
    value
    |> value()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp plain_field(value), do: String.replace(value(value), ["\t", "\n", "\r"], " ")

  defp json_session(session) do
    %{
      "created_at" => session.created_at,
      "cwd" => session.cwd,
      "last_indexed_seq" => session.last_indexed_seq,
      "message_count" => session.message_count,
      "model" => session.model,
      "parent_session_id" => session.parent_session_id,
      "preview" => session.preview,
      "session_id" => session.session_id,
      "status" => value(session.status),
      "tags" => session.tags || [],
      "title" => session.title,
      "updated_at" => session.updated_at
    }
  end

  defp relative_time(nil), do: "unknown"

  defp relative_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        relative_time(DateTime.diff(DateTime.utc_now(), datetime, :second), value)

      {:error, _reason} ->
        value
    end
  end

  defp relative_time(value), do: value(value)

  defp relative_time(seconds, _fallback) when seconds < 0, do: "now"
  defp relative_time(seconds, _fallback) when seconds < 60, do: "#{seconds}s ago"
  defp relative_time(seconds, _fallback) when seconds < 3_600, do: "#{div(seconds, 60)}m ago"
  defp relative_time(seconds, _fallback) when seconds < 86_400, do: "#{div(seconds, 3_600)}h ago"

  defp relative_time(seconds, _fallback) when seconds < 604_800,
    do: "#{div(seconds, 86_400)}d ago"

  defp relative_time(seconds, _fallback) when seconds < 2_592_000,
    do: "#{div(seconds, 604_800)}w ago"

  defp relative_time(_seconds, fallback), do: String.slice(fallback, 0, 10)

  defp timestamp(nil), do: ""
  defp timestamp(value), do: value(value)

  defp value(nil), do: ""
  defp value(value) when is_binary(value), do: value
  defp value(value), do: to_string(value)
end
