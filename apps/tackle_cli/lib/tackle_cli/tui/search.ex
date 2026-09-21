defmodule Tackle.CLI.TUI.Search do
  @moduledoc """
  Transcript search over complete retained message and tool source.

  Search is a modal single-line input. Typing re-runs the query against
  `Conversation.search/2`, keeps the highlighted match index when the query is
  unchanged, and reveals the matched entry in the transcript. `Enter` and the
  arrow keys step through matches without wrapping past the ends.

  The query is never sent to the agent: search is a reading tool over source the
  shell already retains, including tool output hidden behind the inline
  preview. The parent TUI owns the key table and passes already-resolved
  intents here.
  """

  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Popup, TextInput}
  alias Tackle.CLI.TUI.{Conversation, State, Theme, Util}

  @doc "Opens an empty search overlay and focuses its input."
  @spec open(State.t()) :: {:noreply, State.t()}
  def open(%State{} = state) do
    state = %{
      state
      | overlay: {:search, %{input: ExRatatui.text_input_new(), query: "", matches: [], index: 0}}
    }

    {:noreply, refresh(state)}
  end

  @doc "Handles one resolved search intent."
  @spec handle(atom() | tuple(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(intent, %State{} = state), do: dispatch(intent, state)

  @doc "Appends pasted text to the search input and re-runs the query."
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%State{overlay: {:search, search}} = state, content) do
    :ok = ExRatatui.text_input_insert_str(search.input, content)
    refresh(state)
  end

  @doc "Re-reads the input, re-runs the query, and reveals the current match."
  @spec refresh(State.t()) :: State.t()
  def refresh(%State{overlay: {:search, search}} = state) do
    query = ExRatatui.text_input_get_value(search.input)
    matches = Conversation.search(state.conversation, query)

    index =
      if query == search.query,
        do: Util.clamp(search.index, 0, max(length(matches) - 1, 0)),
        else: 0

    search = %{search | query: query, matches: matches, index: index}
    state = %{state | overlay: {:search, search}}

    case Enum.at(matches, index) do
      nil -> state
      match -> %{state | conversation: Conversation.scroll_to_entry(state.conversation, match.id)}
    end
  end

  @doc "Renders the open search input as a popup."
  @spec popup(State.t()) :: Popup.t()
  def popup(%State{overlay: {:search, search}}) do
    title =
      case search.matches do
        [] when search.query == "" ->
          " Search · type to search · Esc close "

        [] ->
          " Search · no matches · Esc close "

        matches ->
          " Search · #{search.index + 1}/#{length(matches)} · Enter next · ↑ previous · Esc close "
      end

    %Popup{
      content: %TextInput{
        state: search.input,
        placeholder: "Search retained transcript and tool output",
        placeholder_style: %Style{fg: :dark_gray}
      },
      block: Theme.panel_block(title, :cyan),
      percent_width: 80,
      percent_height: 20
    }
  end

  defp dispatch(:close, state), do: {:noreply, %{state | overlay: nil}}
  defp dispatch(:next, state), do: {:noreply, next_match(state, 1)}
  defp dispatch(:previous, state), do: {:noreply, next_match(state, -1)}

  defp dispatch({:input, code}, %State{overlay: {:search, search}} = state) do
    :ok = ExRatatui.text_input_handle_key(search.input, code)
    {:noreply, refresh(state)}
  end

  defp dispatch(:ignore, state), do: {:noreply, state, render?: false}

  defp next_match(%State{overlay: {:search, search}} = state, delta) do
    count = length(search.matches)

    if count == 0 do
      state
    else
      index = Integer.mod(search.index + delta, count)
      search = %{search | index: index}
      state = %{state | overlay: {:search, search}}
      match = Enum.at(search.matches, index)
      %{state | conversation: Conversation.scroll_to_entry(state.conversation, match.id)}
    end
  end
end
