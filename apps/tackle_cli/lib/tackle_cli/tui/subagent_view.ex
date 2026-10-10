defmodule Tackle.CLI.TUI.SubagentView do
  @moduledoc """
  A read-only, full-screen conversation for one delegated subagent.

  Enter on a subagent card in the transcript (or on a task in the active-task
  sidebar) opens the child's whole history: its assignment, reasoning, prose,
  and every tool call, rendered by the same `Conversation` model as the main
  transcript. There is no composer, because a child never takes direct input;
  to stop a child that goes wrong, close the view and tell the parent agent.

  The view keeps its own conversation model, scroll position, and reasoning
  toggle, and follows the child live: `after_event/1` re-renders it whenever
  the parent's event projection changed the observed transcript (see
  `Tackle.CLI.TUI.SubagentTranscript`). `←`/`→` step through the other
  subagents observed in this session.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Clear
  alias ExRatatui.Widgets.Block.Title

  alias Tackle.CLI.TUI.{
    Conversation,
    MessageView,
    State,
    SubagentTranscript,
    Theme,
    ToolView,
    Util
  }

  @typedoc "Open view: the observed run and its own transcript model."
  @type t :: %{
          run_id: String.t(),
          conversation: Conversation.t(),
          source: map() | nil,
          thinking_expanded?: boolean(),
          notice: String.t() | nil
        }

  # -- finding a run -------------------------------------------------------

  @doc """
  Returns the observed run behind a subagent card, or nil.

  Cards resolve through their tool call id. A card whose child was never
  observed by this frontend (for example after resume) has no run.
  """
  @spec run_for_entry(State.t(), MessageView.t() | nil) :: String.t() | nil
  def run_for_entry(%State{} = state, %MessageView{kind: :tool, tool_name: "subagent", id: id})
      when is_binary(id) do
    case id do
      "tool:" <> call_id -> run_for_call(state, call_id)
      _other -> nil
    end
  end

  def run_for_entry(_state, _entry), do: nil

  @doc "Returns the observed run behind an active-task sidebar entry, or nil."
  @spec run_for_task(State.t(), map() | nil) :: String.t() | nil
  def run_for_task(%State{} = state, %{} = task) do
    run_id = Map.get(task, :run_id)

    if is_binary(run_id) and Map.has_key?(state.subagents, run_id),
      do: run_id,
      else: run_for_call(state, Map.get(task, :id))
  end

  def run_for_task(_state, _task), do: nil

  defp run_for_call(_state, nil), do: nil

  defp run_for_call(%State{} = state, call_id) do
    Enum.find_value(state.subagents, fn {run_id, tracked} ->
      if Map.get(tracked, :tool_call_id) == call_id, do: run_id
    end)
  end

  # -- lifecycle -----------------------------------------------------------

  @doc "Opens the view on an observed run, following its newest output."
  @spec open(State.t(), String.t()) :: {:noreply, State.t()}
  def open(%State{} = state, run_id) when is_binary(run_id) do
    view = %{
      run_id: run_id,
      conversation: Conversation.new(content_rect(state)),
      source: nil,
      thinking_expanded?: state.thinking_expanded?,
      notice: nil
    }

    {:noreply, %{state | overlay: {:subagent_view, render(state, view)}}}
  end

  @doc """
  Brings an open view up to date after a runtime event.

  Only replies that will paint are synced, so coalesced streaming frames keep
  their single paint; the next flush catches the view up.
  """
  @spec after_event(term()) :: term()
  def after_event({:noreply, %State{} = state}), do: {:noreply, sync(state)}

  def after_event({:noreply, %State{} = state, opts} = reply) do
    if Keyword.get(opts, :render?, true), do: {:noreply, sync(state), opts}, else: reply
  end

  def after_event(reply), do: reply

  @doc "Re-renders an open view when its observed transcript changed."
  @spec sync(State.t()) :: State.t()
  def sync(%State{overlay: {:subagent_view, view}} = state) do
    # Equal terms short-circuit on identity, so an unchanged run costs one compare.
    if source(state, view) == view.source,
      do: state,
      else: %{state | overlay: {:subagent_view, render(state, view)}}
  end

  def sync(%State{} = state), do: state

  @doc "Re-measures the view for the current terminal size."
  @spec resize(State.t()) :: State.t()
  def resize(%State{overlay: {:subagent_view, view}} = state) do
    conversation = Conversation.resize(view.conversation, content_rect(state))
    %{state | overlay: {:subagent_view, %{view | conversation: conversation}}}
  end

  @doc "Scrolls the view by a mouse-wheel row delta."
  @spec scroll(State.t(), integer()) :: State.t()
  def scroll(%State{overlay: {:subagent_view, view}} = state, delta) when is_integer(delta) do
    put_view(state, %{
      view
      | conversation: Conversation.scroll(view.conversation, delta),
        notice: nil
    })
  end

  @doc "Handles one resolved view intent."
  @spec handle(atom() | tuple(), State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def handle(:close, %State{} = state), do: {:noreply, %{state | overlay: nil}}

  def handle({:scroll, code}, %State{overlay: {:subagent_view, view}} = state) do
    conversation = view.conversation
    page = Conversation.page_size(conversation)

    scrolled =
      case code do
        "up" -> Conversation.scroll(conversation, -1)
        "down" -> Conversation.scroll(conversation, 1)
        "page_up" -> Conversation.scroll(conversation, -page)
        "page_down" -> Conversation.scroll(conversation, page)
        "home" -> Conversation.scroll_to(conversation, :start)
        "end" -> Conversation.scroll_to(conversation, :end)
      end

    if scrolled.scroll_offset == conversation.scroll_offset and
         scrolled.follow? == conversation.follow? do
      {:noreply, state, render?: false}
    else
      {:noreply, put_view(state, %{view | conversation: scrolled, notice: nil})}
    end
  end

  def handle(:toggle_thinking, %State{overlay: {:subagent_view, view}} = state) do
    view = %{view | thinking_expanded?: not view.thinking_expanded?, notice: nil}
    {:noreply, %{state | overlay: {:subagent_view, render(state, view)}}}
  end

  def handle({:adjacent, direction}, %State{overlay: {:subagent_view, view}} = state) do
    runs = runs(state)
    index = Enum.find_index(runs, &(&1 == view.run_id)) || 0
    delta = if direction == "left", do: -1, else: 1
    target = Enum.at(runs, Util.clamp(index + delta, 0, max(length(runs) - 1, 0)))

    if is_nil(target) or target == view.run_id,
      do: {:noreply, state, render?: false},
      else: open(state, target)
  end

  def handle(:copy_transcript, %State{overlay: {:subagent_view, view}} = state) do
    notice =
      case Conversation.text(view.conversation) do
        "" -> "Nothing to copy"
        text -> Util.copy_notice(state, text, "Copied subagent transcript")
      end

    {:noreply, put_view(state, %{view | notice: notice})}
  end

  def handle(:ignore, %State{} = state), do: {:noreply, state, render?: false}

  # -- rendering -----------------------------------------------------------

  @doc "Paints the view over the whole screen: chrome, then the conversation."
  @spec widgets(State.t()) :: [{struct(), Rect.t()}]
  def widgets(%State{overlay: {:subagent_view, view}, size: {width, height}} = state) do
    screen = %Rect{x: 0, y: 0, width: width, height: height}
    tracked = tracked(state, view.run_id)

    block = %{
      Theme.panel_block(title(tracked), :accent)
      | titles: [%Title{content: hints(view), position: :bottom, style: Theme.style(:subtle)}]
    }

    [{%Clear{}, screen}, {block, screen}] ++
      if view.conversation.rect.width > 0 and view.conversation.rect.height > 0,
        do: [{Conversation.widget(view.conversation), view.conversation.rect}],
        else: []
  end

  defp title(tracked) do
    profile = Map.get(tracked, :profile) || argument(tracked, "profile") || "subagent"
    model = Map.get(tracked, :model)
    status = status_label(tracked)
    parts = ["Subagent", profile, model, status] |> Enum.reject(&(&1 in [nil, ""]))
    " " <> (parts |> Enum.map(&MessageView.sanitize(to_string(&1))) |> Enum.join(" · ")) <> " "
  end

  defp hints(%{notice: nil}),
    do: " ↑/↓ PgUp/PgDn scroll · ←/→ subagent · Ctrl+T thinking · Y copy · Esc back "

  defp hints(%{notice: notice}), do: " #{notice} · Esc back "

  defp status_label(tracked) do
    elapsed = elapsed(Map.get(tracked, :elapsed_ms))

    case Map.get(tracked, :status) do
      :running -> Enum.join(Enum.reject(["running", elapsed], &is_nil/1), " ")
      :completed -> "completed"
      :cancelled -> "cancelled"
      :timeout -> "timed out"
      nil -> nil
      _failed -> "failed"
    end
  end

  defp elapsed(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1_000)
    if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp elapsed(_ms), do: nil

  defp render(%State{} = state, view) do
    source = source(state, view)
    conversation = Conversation.refresh(view.conversation, source)
    %{view | conversation: conversation, source: source}
  end

  # The view state is the slice of shell state `MessageView` reads for a live
  # turn: the child's projected timeline is its only content, so the settled,
  # pending, and queue sections stay empty.
  defp source(%State{} = state, view) do
    tracked = tracked(state, view.run_id)
    transcript = Map.get(tracked, :transcript) || SubagentTranscript.new()

    # Timeouts and crashes can end a child without settling its open calls.
    transcript =
      if Map.get(tracked, :status) in [nil, :running],
        do: transcript,
        else: SubagentTranscript.interrupt_open_tools(transcript)

    %{
      agent_state: %{messages: []},
      pending_prompt: nil,
      queued_prompts: [],
      compactions: [],
      stream: %{timeline: with_assignment(transcript.timeline, tracked)},
      thinking_expanded?: view.thinking_expanded?,
      prose_width: state.prose_width,
      error: error_text(tracked, transcript)
    }
  end

  # The assignment arrives as the child's first user message. Until then (or
  # when that event was missed) show the prompt the parent sent, so the view
  # never opens on an empty or misleading welcome screen.
  defp with_assignment(timeline, tracked) do
    if Enum.any?(timeline, &(&1[:kind] == :user)) do
      timeline
    else
      prompt = argument(tracked, "prompt") || "(assignment not observed)"
      [%{kind: :user, content: prompt, id: "subagent:assignment"} | timeline]
    end
  end

  defp error_text(tracked, transcript) do
    cond do
      is_binary(transcript.error) ->
        transcript.error

      Map.get(tracked, :status) == :cancelled ->
        "Subagent was cancelled"

      Map.get(tracked, :status) == :timeout ->
        "Subagent timed out"

      Map.get(tracked, :status) in [:error, :runtime_error, :rejected, :failed] ->
        "Subagent failed"

      true ->
        nil
    end
  end

  # Progress can arrive before `subagent_started`; the parent's card already
  # holds the arguments then.
  defp tracked(%State{} = state, run_id) do
    tracked = Map.get(state.subagents, run_id, %{})

    case Map.get(tracked, :arguments) do
      nil ->
        call_id = Map.get(tracked, :tool_call_id)

        tool =
          Enum.find(state.tool_activity, &(is_binary(call_id) and Map.get(&1, :id) == call_id))

        Map.put(tracked, :arguments, tool && Map.get(tool, :arguments))

      _arguments ->
        tracked
    end
  end

  defp argument(tracked, key) do
    args = ToolView.arguments(Map.get(tracked, :arguments))

    case Map.get(args, key) || Map.get(args, String.to_existing_atom(key)) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  # Runs this frontend observed, oldest first, for `←`/`→` browsing.
  defp runs(%State{} = state) do
    state.subagents
    |> Enum.sort_by(fn {run_id, tracked} -> {Map.get(tracked, :started_at_ms, 0), run_id} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp put_view(state, view), do: %{state | overlay: {:subagent_view, view}}

  defp content_rect(%State{size: {width, height}}) do
    %Rect{x: 1, y: 1, width: max(width - 2, 0), height: max(height - 2, 0)}
  end
end
