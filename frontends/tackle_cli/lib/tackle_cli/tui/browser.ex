defmodule Tackle.CLI.TUI.Browser do
  @moduledoc """
  The transcript browser: a focus mode rather than an overlay.

  `F4` enters Browse. Left/right or Tab switches between Transcript, Overview,
  Prompt, Context, Tools, and Events in the main pane. Typing stops without losing
  the composer draft. Transcript arrows select entries; Enter opens their inspector.
  Other pages scroll with arrows and retain a frozen snapshot until R refreshes.

  Selecting an entry scrolls it into view and re-renders only the sections that
  changed, so stepping through a long transcript does not re-measure every
  Markdown block. Copy actions report through the status row's notice, and an
  action with no selection says so rather than failing silently.
  """

  alias Tackle.CLI.Widgets.Browse, as: NativeBrowse

  alias Tackle.CLI.TUI.{
    Conversation,
    Diagnostics,
    Inspector,
    MessageView,
    Search,
    State,
    Util,
    Viewport
  }

  @pages [:transcript, :overview, :prompt, :context, :tools, :events]

  @doc "Whether Browse is displaying a non-transcript page."
  @spec page?(State.t()) :: boolean()
  def page?(state), do: state.focus == :transcript and state.browse_page != :transcript

  @doc "Renders the frozen page in the main transcript region."
  @spec widget(State.t()) :: NativeBrowse.t()
  def widget(%State{browse_page: :transcript} = state) do
    transcript = Conversation.widget(state.conversation)

    %NativeBrowse{
      state: transcript.state,
      selected: transcript.selected,
      scroll_offset: transcript.scroll_offset,
      page: 0
    }
  end

  def widget(state) do
    page = state.browse_content

    %NativeBrowse{
      state: page.native,
      scroll_offset: page.offset,
      page: Enum.find_index(@pages, &(&1 == state.browse_page))
    }
  end

  @doc "Re-measures a frozen page when the main pane changes size."
  @spec resize(State.t()) :: State.t()
  def resize(state) do
    if page?(state) and state.browse_content != nil and
         state.browse_content.rect != state.conversation.rect,
       do: measure(state, state.browse_content),
       else: state
  end

  defp measure(state, page) do
    rect = state.conversation.rect
    {native, total} = NativeBrowse.document(page.text, max(rect.width, 1))

    page =
      Map.merge(page, %{
        rect: rect,
        native: native,
        height: rect.height,
        total: total,
        offset: NativeBrowse.scroll(page.offset, total, rect.height, 0)
      })

    %{state | browse_content: page}
  end

  defp select_page(state, page) do
    state = %{state | browse_page: page, browse_content: nil, notice: nil} |> Viewport.relayout()

    if page == :transcript do
      %{state | browse_content: nil}
    else
      measure(state, %{text: Diagnostics.text(state, page), offset: 0})
    end
  end

  defp adjacent(state, direction) do
    index = Enum.find_index(@pages, &(&1 == state.browse_page))
    delta = if direction == "left", do: -1, else: 1
    select_page(state, Enum.at(@pages, Integer.mod(index + delta, length(@pages))))
  end

  @doc "Scrolls the visible Browse page without moving the underlying transcript."
  @spec scroll(State.t(), integer()) :: State.t()
  def scroll(state, delta) do
    page = state.browse_content
    offset = NativeBrowse.scroll(page.offset, page.total, page.height, delta)
    %{state | browse_content: %{page | offset: offset}}
  end

  @doc """
  Toggles focus between the composer and the transcript.

  Entering the browser selects the newest transcript entry and scrolls to it.
  An empty transcript opens Overview so system information is always available.
  """
  @spec toggle_focus(State.t()) :: {:noreply, State.t()}
  def toggle_focus(%State{focus: :transcript} = state), do: leave_focus(state)

  def toggle_focus(%State{focus: :composer} = state) do
    state = %{state | focus: :transcript, browse_page: :transcript, browse_content: nil}

    case Conversation.entries(state.conversation) do
      [] ->
        {:noreply, select_page(state, :overview)}

      entries ->
        selected = List.last(entries).id
        state = %{state | focus: :transcript, selected_entry: selected, notice: nil}

        state = %{
          state
          | conversation: Conversation.scroll_into_view(state.conversation, selected)
        }

        {:noreply, Viewport.refresh(state)}
    end
  end

  @doc "Returns to the composer and clears the selection."
  @spec leave_focus(State.t()) :: {:noreply, State.t()}
  def leave_focus(%State{} = state) do
    state = %{
      state
      | focus: :composer,
        selected_entry: nil,
        browse_page: :transcript,
        browse_content: nil
    }

    {:noreply, Viewport.refresh(state)}
  end

  @doc """
  Handles one resolved transcript intent.

  Reading chords stay live in the browser: `Ctrl+F` opens search and `Ctrl+T`
  reveals or collapses reasoning without leaving focus.
  """
  @spec handle(atom() | tuple(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(:leave, state), do: leave_focus(state)
  def handle({:adjacent, direction}, state), do: {:noreply, adjacent(state, direction)}

  def handle(intent, %State{} = state) do
    if page?(state), do: page_intent(intent, state), else: dispatch(intent, state)
  end

  defp page_intent(:refresh, state), do: {:noreply, select_page(state, state.browse_page)}
  defp page_intent(:previous, state), do: {:noreply, scroll(state, -1)}
  defp page_intent(:next, state), do: {:noreply, scroll(state, 1)}

  defp page_intent(:page_up, state),
    do: {:noreply, scroll(state, -max(state.browse_content.height - 1, 1))}

  defp page_intent(:page_down, state),
    do: {:noreply, scroll(state, max(state.browse_content.height - 1, 1))}

  defp page_intent(:scroll_start, state),
    do: {:noreply, scroll(state, -state.browse_content.total)}

  defp page_intent(:scroll_end, state), do: {:noreply, scroll(state, state.browse_content.total)}

  defp page_intent(:copy_source, state) do
    notice = Util.copy_notice(state, state.browse_content.text, "Copied Browse page")
    {:noreply, %{state | notice: notice}}
  end

  defp page_intent(_intent, state), do: {:noreply, state, render?: false}

  @doc """
  Ignores a paste while the transcript owns the keyboard.

  A paste must not land in a composer whose cursor the user cannot see.
  """
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%State{} = state, _content), do: state

  @doc "Returns the highlighted entry, or nil when nothing is selected."
  @spec focused_entry(State.t()) :: MessageView.t() | nil
  def focused_entry(%State{selected_entry: nil}), do: nil

  def focused_entry(%State{} = state),
    do: Conversation.entry(state.conversation, state.selected_entry)

  defp dispatch(:previous, state), do: {:noreply, move(state, -1)}
  defp dispatch(:next, state), do: {:noreply, move(state, 1)}

  defp dispatch(:page_up, state),
    do: Viewport.scroll_reply(state, Viewport.scroll(state, -Viewport.page_size(state)))

  defp dispatch(:page_down, state),
    do: Viewport.scroll_reply(state, Viewport.scroll(state, Viewport.page_size(state)))

  defp dispatch(:refresh, state), do: {:noreply, Viewport.refresh(state)}
  defp dispatch(:scroll_start, state), do: {:noreply, Viewport.scroll_to(state, :start)}
  defp dispatch(:scroll_end, state), do: {:noreply, Viewport.scroll_to(state, :end)}
  defp dispatch(:search, state), do: Search.open(state)
  defp dispatch(:toggle_thinking, state), do: Viewport.toggle_thinking(state)

  defp dispatch(:inspect, state) do
    case focused_entry(state) do
      nil -> {:noreply, %{state | notice: "Nothing to inspect"}}
      entry -> {:noreply, %{state | overlay: {:inspector, Inspector.build(state, entry)}}}
    end
  end

  defp dispatch(:copy_source, state) do
    case focused_entry(state) do
      nil ->
        {:noreply, %{state | notice: "Nothing to copy"}}

      entry ->
        notice = Util.copy_notice(state, MessageView.source_text(entry), "Copied full source")
        {:noreply, %{state | notice: notice}}
    end
  end

  defp dispatch(:copy_transcript, state) do
    case Conversation.text(state.conversation) do
      "" ->
        {:noreply, %{state | notice: "Nothing to copy"}}

      text ->
        {:noreply, %{state | notice: Util.copy_notice(state, text, "Copied full transcript")}}
    end
  end

  defp dispatch(:ignore, state), do: {:noreply, state, render?: false}

  # The selection stops at the ends instead of wrapping, so holding the key
  # does not silently teleport from the newest entry back to the oldest.
  defp move(%State{} = state, delta) do
    entries = Conversation.entries(state.conversation)
    count = length(entries)

    if count == 0 do
      state
    else
      index = Enum.find_index(entries, &(&1.id == state.selected_entry)) || count - 1
      selected = Enum.at(entries, Util.clamp(index + delta, 0, count - 1)).id

      state
      |> Map.put(:selected_entry, selected)
      |> Map.put(:conversation, Conversation.scroll_into_view(state.conversation, selected))
      |> refresh_selection(state.selected_entry, selected)
    end
  end

  # Only the entries that changed need re-rendering, so stepping through a long
  # transcript does not re-measure every Markdown block in it.
  defp refresh_selection(state, previous, selected) do
    sections =
      [previous, selected]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Conversation.section_of(state.conversation, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if sections == [] do
      state
    else
      %{state | conversation: Conversation.refresh(state.conversation, state, sections)}
    end
  end
end
