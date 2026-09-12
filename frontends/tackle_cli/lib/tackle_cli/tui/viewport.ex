defmodule Tackle.CLI.TUI.Viewport do
  @moduledoc """
  Keeps the transcript model, the screen regions, and the draft metrics in sync.

  The conversation cache and the responsive layout are two views of the same
  terminal: the composer's wrapped row count decides how many rows the
  transcript gets, and the transcript rect decides the wrapping width for every
  Markdown block. Every surface that changes a prompt, a streaming delta, or a
  terminal size therefore has to end in this module, which is why it exists
  instead of each pane reimplementing the refresh.

  `refresh/2` accepts the sections that changed so streaming deltas only
  rebuild the section they affect; `relayout/1` re-derives the regions after a
  draft edit without touching the cached content. `scroll_reply/2` is the
  shared reply shape for scroll intents: it suppresses a render when the
  scrolled state is indistinguishable from the current one, so a scroll that
  hits an edge does not repaint the frame.
  """

  alias Tackle.CLI.TUI.{Conversation, Layout, State}
  alias Tackle.CLI.Widgets.Input

  @doc "Creates the empty transcript model for a terminal size."
  @spec new_conversation(integer(), integer()) :: Conversation.t()
  def new_conversation(width, height) do
    regions = Layout.regions(width, height, 1, false)
    Conversation.new(regions.transcript)
  end

  @doc """
  Rebuilds the transcript and re-derives the regions.

  When no sections are given every section is rebuilt. Passing a subset keeps a
  streaming update proportional to the section it changed. Either way the
  layout is recomputed so a composer that grew or shrank reserves the right
  number of rows.
  """
  @spec refresh(State.t()) :: State.t()
  @spec refresh(State.t(), [Conversation.section()]) :: State.t()
  def refresh(state, sections \\ nil)

  def refresh(%State{} = state, nil) do
    %{state | conversation: Conversation.refresh(state.conversation, state)}
    |> relayout()
    |> reselect_missing_entry()
  end

  def refresh(%State{} = state, sections) do
    %{state | conversation: Conversation.refresh(state.conversation, state, sections)}
    |> relayout()
    |> reselect_missing_entry()
  end

  @doc """
  Re-derives the regions for the current draft and resizes the transcript.

  The conversation cache is kept when the transcript rect did not change, so a
  keystroke that leaves the layout alone does not re-measure Markdown.
  """
  @spec relayout(State.t()) :: State.t()
  def relayout(%State{} = state) do
    {width, height} = state.size
    regions = Layout.regions(width, height, state.draft_lines, reading?(state.conversation))

    conversation =
      if regions.transcript == state.conversation.rect do
        state.conversation
      else
        Conversation.resize(state.conversation, regions.transcript)
      end

    %{state | conversation: conversation}
  end

  @doc """
  Applies a terminal resize to the whole viewport.

  The caller sets `state.size` first so an overlay can be resized against the
  new dimensions before the transcript is rebuilt.
  """
  @spec resize(State.t()) :: State.t()
  def resize(%State{} = state) do
    state = update_draft(state)
    {width, height} = state.size
    regions = Layout.regions(width, height, state.draft_lines, reading?(state.conversation))

    state = %{state | conversation: Conversation.resize(state.conversation, regions.transcript)}
    refresh(state)
  end

  @doc "Whether the transcript is showing the reading-back affordance."
  @spec reading?(Conversation.t()) :: boolean()
  def reading?(conversation), do: conversation.new_output? or not conversation.follow?

  @doc "Recomputes the composer's wrapped row count and emptiness."
  @spec update_draft(State.t()) :: State.t()
  def update_draft(%State{} = state) do
    value = Input.get_value(state.input)

    {width, _height} = state.size

    %{
      state
      | draft_lines: Input.rows(state.input, max(width - 2, 1)),
        draft_empty?: String.trim(value) == ""
    }
  end

  @doc "Reveals or collapses supplied reasoning in the transcript."
  @spec toggle_thinking(State.t()) :: {:noreply, State.t()}
  def toggle_thinking(%State{} = state) do
    state = %{state | thinking_expanded?: not state.thinking_expanded?}
    {:noreply, refresh(state, [:settled, :turn])}
  end

  @doc "Scrolls the transcript by a row delta."
  @spec scroll(State.t(), integer()) :: State.t()
  def scroll(%State{} = state, delta) do
    %{state | conversation: Conversation.scroll(state.conversation, delta)}
    |> relayout()
  end

  @doc "Scrolls the transcript to its oldest or newest row."
  @spec scroll_to(State.t(), :start | :end) :: State.t()
  def scroll_to(%State{} = state, location) do
    %{state | conversation: Conversation.scroll_to(state.conversation, location)}
    |> relayout()
  end

  @doc "Returns the number of rows moved by one page action."
  @spec page_size(State.t()) :: pos_integer()
  def page_size(%State{} = state), do: Conversation.page_size(state.conversation)

  @doc """
  Replies to a scroll intent, suppressing a render when nothing moved.

  A scroll clamped at an edge produces a state identical to the current one;
  comparing the offset and follow flag keeps that keystroke from repainting.
  """
  @spec scroll_reply(State.t(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def scroll_reply(state, scrolled_state) do
    if scrolled_state.conversation.scroll_offset == state.conversation.scroll_offset and
         scrolled_state.conversation.follow? == state.conversation.follow? do
      {:noreply, state, render?: false}
    else
      {:noreply, scrolled_state}
    end
  end

  # Streaming entries are replaced by settled ones when a turn finishes, so a
  # selection can name an id that no longer exists. Re-anchor to the newest entry
  # rather than leaving the browser standing on nothing, and re-render just that
  # section so the highlight follows the state.
  defp reselect_missing_entry(%State{focus: :transcript, selected_entry: id} = state) do
    entries = Conversation.entries(state.conversation)

    if entries == [] or Enum.any?(entries, &(&1.id == id)) do
      state
    else
      selected = List.last(entries).id
      state = %{state | selected_entry: selected}

      sections =
        [Conversation.section_of(state.conversation, selected)] |> Enum.reject(&is_nil/1)

      %{state | conversation: Conversation.refresh(state.conversation, state, sections)}
    end
  end

  defp reselect_missing_entry(state), do: state
end
