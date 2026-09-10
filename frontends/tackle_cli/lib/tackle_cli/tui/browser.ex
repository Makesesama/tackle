defmodule Tackle.CLI.TUI.Browser do
  @moduledoc """
  The transcript browser: a focus mode rather than an overlay.

  `F4` moves the keyboard into the transcript. There is no popup, typing stops,
  and the arrows move a highlighted entry instead of the caret. From there the
  user can copy an entry's full source (`y`), copy the whole transcript (`a`),
  or open an entry in the inspector (`Enter`) without losing the draft in the
  composer.

  Selecting an entry scrolls it into view and re-renders only the sections that
  changed, so stepping through a long transcript does not re-measure every
  Markdown block. Copy actions report through the status row's notice, and an
  action with no selection says so rather than failing silently.
  """

  alias Tackle.CLI.TUI.{Conversation, Inspector, MessageView, Search, State, Util, Viewport}

  @doc """
  Toggles focus between the composer and the transcript.

  Entering the browser selects the newest entry and scrolls to it. An empty
  transcript reports that there is nothing to browse instead of entering a
  focus mode with no target.
  """
  @spec toggle_focus(State.t()) :: {:noreply, State.t()}
  def toggle_focus(%State{focus: :transcript} = state), do: leave_focus(state)

  def toggle_focus(%State{focus: :composer} = state) do
    case Conversation.entries(state.conversation) do
      [] ->
        {:noreply, %{state | notice: "No messages to browse yet"}}

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
    state = %{state | focus: :composer, selected_entry: nil}
    {:noreply, Viewport.refresh(state)}
  end

  @doc """
  Handles one resolved transcript intent.

  Reading chords stay live in the browser: `Ctrl+F` opens search and `Ctrl+T`
  reveals or collapses reasoning without leaving focus.
  """
  @spec handle(atom(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(intent, %State{} = state), do: dispatch(intent, state)

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

  defp dispatch(:leave, state), do: leave_focus(state)
  defp dispatch(:previous, state), do: {:noreply, move(state, -1)}
  defp dispatch(:next, state), do: {:noreply, move(state, 1)}

  defp dispatch(:page_up, state),
    do: Viewport.scroll_reply(state, Viewport.scroll(state, -Viewport.page_size(state)))

  defp dispatch(:page_down, state),
    do: Viewport.scroll_reply(state, Viewport.scroll(state, Viewport.page_size(state)))

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
