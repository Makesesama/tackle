defmodule Tackle.CLI.TUI.TextSelection do
  @moduledoc """
  Mouse selection of painted transcript cells, separate from Browse entry focus.

  Copy uses rendered text (including visible gutters and wrapping), not hidden
  source. Endpoints are document rows and terminal columns; native hit testing
  keeps wide and combining graphemes intact. Changed layout/content at or before
  the selection clears it rather than copying a different passage.
  """

  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.{Browser, Conversation, Dashboard, State, Util, Viewport}

  @type t :: %__MODULE__{}
  defstruct [
    :anchor,
    :focus,
    :last_click,
    :pointer,
    :token,
    clicks: 1,
    dragging?: false,
    moved?: false
  ]

  @doc "Returns an ordered, half-open document cell range."
  @spec range(t() | nil) ::
          {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}} | nil
  def range(nil), do: nil
  def range(%{clicks: 1, moved?: false, anchor: {point, _}}), do: {point, point}
  def range(%{anchor: {a, b}, focus: {c, d}}), do: {min(a, c), max(b, d)}

  @doc "Whether a nonempty text range is selected."
  @spec selected?(State.t()) :: boolean()
  def selected?(state) do
    case range(state.conversation.text_selection) do
      nil -> false
      {a, b} -> a != b
    end
  end

  @doc "Clears text selection without changing keyboard focus or the draft."
  @spec clear(State.t()) :: State.t()
  def clear(state), do: put(state, nil)

  @doc "Whether transcript selection can receive input on this surface."
  @spec enabled?(State.t()) :: boolean()
  def enabled?(state),
    do: state.overlay == nil and not Browser.page?(state) and not Dashboard.show?(state)

  @doc "Handles a left-button gesture; unrelated surfaces never receive it."
  @spec mouse(ExRatatui.Event.Mouse.t(), State.t(), integer()) :: State.t()
  def mouse(mouse, state, now \\ System.monotonic_time(:millisecond)) do
    if enabled?(state), do: gesture(mouse, state, now), else: clear(state)
  end

  defp gesture(%{kind: "down", x: x, y: y}, state, now) do
    c = state.conversation

    if Conversation.contains?(c, x, y) and
         y - c.rect.y + c.scroll_offset < c.content_height do
      point = point(c, x, y)
      previous = c.text_selection

      clicks =
        case previous do
          %{last_click: {^point, time}, clicks: clicks} when now - time <= 400 ->
            rem(clicks, 3) + 1

          _ ->
            1
        end

      bounds = bounds(c, point, clicks)

      selection = %__MODULE__{
        anchor: bounds,
        focus: bounds,
        clicks: clicks,
        last_click: {point, now},
        pointer: {x, y},
        dragging?: true,
        token: make_ref()
      }

      Process.send_after(self(), {:text_selection_tick, selection.token}, 75)

      c = %{c | follow?: false, text_selection: selection}
      %{state | conversation: c, notice: nil} |> Viewport.relayout()
    else
      clear(state)
    end
  end

  defp gesture(%{kind: kind, x: x, y: y}, state, _now) when kind in ["drag", "up"] do
    case state.conversation.text_selection do
      %{dragging?: true} = selection ->
        state = if kind == "drag", do: edge_scroll(state, y), else: state
        c = state.conversation
        # Adding the reading row can shrink the viewport after mouse-down.
        # An unchanged physical release must still be an empty click.
        stationary? = kind == "up" and not selection.moved? and selection.pointer == {x, y}

        focus =
          if stationary?, do: selection.focus, else: bounds(c, point(c, x, y), selection.clicks)

        selection = %{
          selection
          | focus: focus,
            pointer: {x, y},
            dragging?: kind != "up",
            moved?: selection.moved? or focus != selection.anchor
        }

        state = put(state, selection)
        if kind == "up", do: copy(state), else: state

      _ ->
        state
    end
  end

  defp gesture(_mouse, state, _now), do: state

  @doc "Extends an active drag after wheel movement."
  @spec after_scroll(State.t()) :: State.t()
  def after_scroll(state) do
    case state.conversation.text_selection do
      %{dragging?: true, pointer: {x, y}} = selection ->
        focus = bounds(state.conversation, point(state.conversation, x, y), selection.clicks)

        put(state, %{
          selection
          | focus: focus,
            moved?: selection.moved? or focus != selection.anchor
        })

      _ ->
        state
    end
  end

  @doc "Continues edge scrolling while the button is held; stale timers are ignored."
  @spec tick(State.t(), reference()) :: State.t()
  def tick(state, token) do
    case state.conversation.text_selection do
      %{dragging?: true, token: ^token, pointer: {_, y}, moved?: moved?} ->
        if enabled?(state) do
          Process.send_after(self(), {:text_selection_tick, token}, 75)
          if moved?, do: state |> edge_scroll(y) |> after_scroll(), else: state
        else
          clear(state)
        end

      _ ->
        state
    end
  end

  @doc "Copies a nonempty selection through the host's clipboard writer."
  @spec copy(State.t()) :: State.t()
  def copy(state) do
    case range(state.conversation.text_selection) do
      nil ->
        state

      {same, same} ->
        state

      range ->
        try do
          case Native.conversation_selection_text(state.conversation.native, range) do
            "" ->
              state

            text when is_binary(text) ->
              %{state | notice: Util.copy_notice(state, text, "Copied selection")}

            {:error, reason} ->
              %{state | notice: "Copy failed: #{reason}"}
          end
        rescue
          error -> %{state | notice: "Copy failed: #{Exception.message(error)}"}
        end
    end
  end

  @doc "Retains selection only when the selected prefix still has identical layout."
  @spec reconcile(Conversation.t(), Conversation.t()) :: t() | nil
  def reconcile(old, new) do
    case range(old.text_selection) do
      nil ->
        nil

      {_start, {last_row, _}} = range ->
        same? =
          old.width == new.width and last_row < new.content_height and
            (Conversation.same_prefix?(old, new, last_row) or
               same_text?(old, new, range))

        if same?, do: old.text_selection, else: nil
    end
  end

  # Resource identity is the cheap path for settled history. A live message
  # rebuilds its entire resource even when only rows below selection changed.
  defp same_text?(old, new, {start, finish}) when start != finish do
    case Native.conversation_selection_text(old.native, {start, finish}) do
      text when is_binary(text) ->
        text == Native.conversation_selection_text(new.native, {start, finish})

      _ ->
        false
    end
  end

  defp same_text?(_old, _new, _range), do: false

  defp edge_scroll(state, y) do
    rect = state.conversation.rect

    cond do
      y <= rect.y -> Viewport.scroll(state, -Conversation.mouse_scroll_rows())
      y >= rect.y + rect.height - 1 -> Viewport.scroll(state, Conversation.mouse_scroll_rows())
      true -> state
    end
  end

  defp point(c, x, y) do
    row = c.scroll_offset + Util.clamp(y - c.rect.y, 0, max(c.rect.height - 1, 0))
    {min(row, max(c.content_height - 1, 0)), Util.clamp(x - c.rect.x, 0, c.width - 1)}
  end

  defp bounds(c, {row, col}, clicks) do
    cells = Native.conversation_row(c.native, row)

    {x, width, _text} =
      Enum.find(cells, {col, 1, " "}, fn {x, w, _} -> col >= x and col < x + w end)

    case clicks do
      3 ->
        {{row, 0}, {row, c.width}}

      2 ->
        index = Enum.find_index(cells, fn {cx, _, _} -> cx == x end) || 0
        class = cells |> Enum.at(index, {0, 1, " "}) |> elem(2) |> word_class()

        left =
          cells
          |> Enum.take(index)
          |> Enum.reverse()
          |> Enum.take_while(&(word_class(elem(&1, 2)) == class))

        right = cells |> Enum.drop(index) |> Enum.take_while(&(word_class(elem(&1, 2)) == class))
        {start, _, _} = List.last(left) || {x, width, ""}
        {finish, w, _} = List.last(right) || {x, width, ""}
        {{row, start}, {row, finish + w}}

      _ ->
        {{row, x}, {row, x + width}}
    end
  end

  defp word_class(text) do
    cond do
      String.trim(text) == "" -> :space
      Regex.match?(~r/^[\p{L}\p{N}\p{M}_]+$/u, text) -> :word
      true -> :punctuation
    end
  end

  defp put(state, selection),
    do: %{state | conversation: %{state.conversation | text_selection: selection}}
end
