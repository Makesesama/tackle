defmodule Tackle.CLI.TUI.Inspector do
  @moduledoc """
  The scrollable tool-output inspector.

  An inspector freezes one transcript entry's rendered detail into a flat row
  list, measures it, and then scrolls that list inside a popup viewport. It
  keeps the *complete* retained source, so the inline card can stay a bounded
  head/tail preview while the inspector and the copy actions expose everything
  the tool actually produced.

  The inspector also knows which tool cards are adjacent, so `←`/`→` browse the
  tool calls in the transcript without leaving the popup. Copying reports
  through a notice in the popup title, and a resize re-measures the content
  against the new terminal width while clamping the scroll offset.
  """

  alias ExRatatui.Widgets.{Popup, WidgetList}
  alias Tackle.CLI.TUI.{Conversation, MessageView, State, Theme, ToolView, Util}

  @doc "Builds a fresh inspector overlay entry for one transcript entry."
  @spec build(State.t(), MessageView.t()) :: map()
  def build(%State{} = state, entry) do
    {content_width, viewport_height} = metrics(state)
    items = MessageView.inspect_items(entry, content_width)

    %{
      entry: entry,
      name: MessageView.sanitize(entry.tool_name || entry.label || "entry"),
      items: items,
      content_height: content_height(items),
      viewport_height: viewport_height,
      scroll_offset: 0,
      notice: nil
    }
  end

  @doc "Handles one resolved inspector intent."
  @spec handle(atom() | tuple(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(intent, %State{} = state), do: dispatch(intent, state)

  @doc """
  Scrolls the inspector by a code or a row delta.

  Codes come from the key table (`"up"`, `"page_down"`, `"home"`, ...); an
  integer is a mouse-wheel delta. Any movement clears the copy notice so the
  title returns to the position readout.
  """
  @spec scroll(State.t(), String.t() | integer()) :: State.t()
  def scroll(%State{overlay: {:inspector, inspector}} = state, code) do
    max_offset = max(inspector.content_height - inspector.viewport_height, 0)
    page = max(inspector.viewport_height - 1, 1)

    delta =
      case code do
        "up" -> -1
        "down" -> 1
        "page_up" -> -page
        "page_down" -> page
        "home" -> -max_offset
        "end" -> max_offset
        rows when is_integer(rows) -> rows
      end

    offset = inspector.scroll_offset |> Kernel.+(delta) |> max(0) |> min(max_offset)
    %{state | overlay: {:inspector, %{inspector | scroll_offset: offset, notice: nil}}}
  end

  @doc "Re-measures the inspector for the current terminal size."
  @spec resize(State.t()) :: State.t()
  def resize(%State{overlay: {:inspector, inspector}} = state) do
    {content_width, viewport_height} = metrics(state)
    items = MessageView.inspect_items(inspector.entry, content_width)
    max_offset = max(content_height(items) - viewport_height, 0)

    overlay =
      {:inspector,
       %{
         inspector
         | items: items,
           content_height: content_height(items),
           viewport_height: viewport_height,
           scroll_offset: min(inspector.scroll_offset, max_offset)
       }}

    %{state | overlay: overlay}
  end

  @doc "Renders the open inspector as a popup."
  @spec popup(State.t()) :: Popup.t()
  def popup(%State{overlay: {:inspector, inspector}}) do
    {visible_items, visible_offset} =
      Conversation.slice(inspector.items, inspector.scroll_offset, inspector.viewport_height)

    title =
      case inspector.notice do
        nil ->
          " #{inspector.name} · #{position(inspector)} · ←/→ tool · Y output · A args · Esc "

        notice ->
          " #{notice} · Esc close "
      end

    %Popup{
      content: %WidgetList{items: visible_items, scroll_offset: visible_offset},
      block: Theme.panel_block(title, :cyan),
      percent_width: 90,
      percent_height: 80
    }
  end

  defp dispatch(:close, state), do: {:noreply, %{state | overlay: nil}}
  defp dispatch({:scroll, code}, state), do: {:noreply, scroll(state, code)}
  defp dispatch(:copy_source, state), do: copy_source(state)
  defp dispatch({:adjacent, code}, state), do: {:noreply, adjacent(state, code)}

  defp dispatch(:copy_arguments, %State{overlay: {:inspector, inspector}} = state) do
    args = ToolView.arguments(inspector.entry.tool_arguments)
    notice = Util.copy_notice(state, JSON.encode!(args), "Copied tool arguments")
    {:noreply, %{state | overlay: {:inspector, %{inspector | notice: notice}}}}
  end

  defp dispatch(:ignore, state), do: {:noreply, state, render?: false}

  defp copy_source(%State{overlay: {:inspector, inspector}} = state) do
    notice =
      Util.copy_notice(state, MessageView.full_text(inspector.entry), "Copied full output")

    {:noreply, %{state | overlay: {:inspector, %{inspector | notice: notice}}}}
  end

  # Tool cards are found in transcript order rather than in a stored list, so
  # the inspector follows the conversation when streaming adds new calls.
  defp adjacent(%State{overlay: {:inspector, inspector}} = state, direction) do
    tools = Conversation.entries(state.conversation) |> Enum.filter(&(&1.kind == :tool))
    index = Enum.find_index(tools, &(&1.id == inspector.entry.id)) || 0
    delta = if direction == "left", do: -1, else: 1

    case Enum.at(tools, Util.clamp(index + delta, 0, max(length(tools) - 1, 0))) do
      nil -> state
      entry -> %{state | overlay: {:inspector, build(state, entry)}}
    end
  end

  defp metrics(%State{} = state) do
    {width, height} = state.size
    {max(div(width * 90, 100) - 2, 1), max(div(height * 80, 100) - 2, 1)}
  end

  defp content_height(items) do
    Enum.reduce(items, 0, fn {_widget, item_height}, total -> total + item_height end)
  end

  defp position(%{content_height: content_height, viewport_height: viewport_height} = inspector) do
    max_offset = max(content_height - viewport_height, 0)

    if max_offset == 0 do
      "all"
    else
      "#{round(inspector.scroll_offset / max_offset * 100)}%"
    end
  end
end
