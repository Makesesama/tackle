defmodule Tackle.CLI.TUI.Dashboard do
  @moduledoc """
  The empty-session landing surface. The transcript replaces it as soon as a
  conversation begins; small terminals retain the ordinary transcript layout.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph
  alias Tackle.CLI.TUI.{Glyph, Layout, MessageView, State, Theme, Util}
  alias Tackle.Thinking

  @recent_label_width 32

  @doc "Whether the landing surface can fit the current draft and its surrounding content."
  @spec show?(State.t()) :: boolean()
  def show?(%State{} = state) do
    {_width, height} = state.size
    # Keep the six-row mark and the recent-session shortcuts clear of the
    # composer. Larger drafts continue in the transcript layout.
    eligible?(state) and state.draft_lines <= min(8, height - 21)
  end

  @doc "Whether the dashboard can host the draft, independent of its row count."
  @spec eligible?(State.t()) :: boolean()
  def eligible?(%State{} = state) do
    {width, height} = state.size

    width >= 40 and height >= 24 and not is_nil(state.list_recent_sessions) and
      state.focus == :composer and is_nil(state.active_turn) and
      is_nil(state.pending_operation) and state.agent_state.messages == []
  end

  @doc "Content width of the bounded dashboard composer (excluding border and padding)."
  @spec content_width(State.t()) :: pos_integer()
  def content_width(%State{size: {width, height}}) do
    Layout.composer_content_width(min(width - 4, 80), height)
  end

  @doc "The dashboard widgets and their rectangles; the input is supplied by View."
  @spec widgets(State.t(), Rect.t()) :: [{struct(), Rect.t()}]
  def widgets(state, composer) do
    {width, _height} = state.size
    model = State.model_ref(state.agent_state) || "configured default"
    thinking = Thinking.from_llm_opts(state.agent_state.llm_opts)
    path = File.cwd!()

    # Keep the mark, configuration, and composer together near the center of
    # the screen, leaving the session shortcuts below the input.
    mark_y = max(composer.y - 11, 1)
    info_y = composer.y - 4

    logo =
      Enum.with_index(Glyph.rows(), fn row, offset ->
        {paragraph([row]), centered(width, Glyph.width(), mark_y + offset)}
      end)

    info = [
      text_row(path, info_y, width, :muted),
      text_row("#{model}  ·  thinking #{thinking}", info_y + 1, width, :subtle)
    ]

    sessions = Enum.take(state.recent_sessions, 5)
    start_y = composer.y + composer.height + 1

    recent =
      cond do
        state.recent_sessions_ref != nil ->
          [text_row("Loading recent sessions…", start_y + 1, width, :subtle)]

        sessions == [] ->
          [text_row("No recent sessions", start_y + 1, width, :subtle)]

        true ->
          Enum.with_index(sessions, 1)
          |> Enum.map(fn {session, index} ->
            label = session.title || session.preview || session.session_id

            label =
              label
              |> MessageView.sanitize()
              |> String.split("\n", parts: 2)
              |> hd()
              |> Util.truncate(@recent_label_width)

            text_row("Alt+#{index}  #{label}", start_y + index, width, :muted)
          end)
      end

    logo ++ info ++ [text_row("Recent sessions", start_y, width, :text)] ++ recent
  end

  @doc "Centers the composer within a bounded dashboard column."
  @spec composer_rect(State.t()) :: Rect.t()
  def composer_rect(state) do
    {width, height} = state.size
    input_width = min(width - 4, 80)

    input_height =
      min(state.draft_lines, 8) + if(Layout.composer_box?(width, height), do: 2, else: 0)

    y = max(div(height, 2) - 1, 11)

    %Rect{
      x: div(width - input_width, 2),
      y: min(y, height - input_height - 8),
      width: input_width,
      height: input_height
    }
  end

  defp text_row(text, y, width, tone) do
    text = text |> MessageView.sanitize() |> Util.truncate(max(width - 4, 1))

    {paragraph([MessageView.row([MessageView.span(text, Theme.style(tone))], %Style{})]),
     centered(width, MessageView.display_width(text), y)}
  end

  defp paragraph(rows), do: %Paragraph{text: rows}

  defp centered(width, content_width, y) do
    %Rect{
      x: max(div(width - content_width, 2), 0),
      y: y,
      width: min(content_width, width),
      height: 1
    }
  end
end
