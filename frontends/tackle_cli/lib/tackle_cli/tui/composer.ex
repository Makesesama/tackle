defmodule Tackle.CLI.TUI.Composer do
  @moduledoc """
  Draft editing and submission for the native multiline composer.

  The composer is the one place a prompt is produced, so this module owns every
  way text gets into or out of it: native key handling, newline insertion,
  bracketed paste, submission, and prompt history. Each edit ends in
  `Viewport.update_draft/1` and `Viewport.relayout/1` so the growing input
  reserves exactly the rows it needs without re-measuring the transcript.

  History recall reuses the same native load path: the recalled prompt is set
  as the draft and the row count is left to `Viewport`. Plain Up/Down
  (`previous/2` and `next/2`) only recall when the draft is empty or a prompt is
  already showing, so arrow keys still move the cursor inside a draft that is
  being written; Ctrl+P/Ctrl+N (`history_previous/1` and `history_next/1`) always
  recall. Any edit ends recall, keeping the loaded text as the new draft.

  Submission is deliberately conservative. A failed submit keeps the exact draft
  in the composer so the user can retry or edit, and a submit while a turn is
  active keeps the draft as well: there is no queue, so the draft is labeled as
  belonging to the next turn instead of being delivered to the running one.
  """

  alias ExRatatui.Command
  alias ExRatatui.Event.Key
  alias Tackle.CLI.TUI.{History, State, Tree, Viewport}
  alias Tackle.CLI.TUI.State.{Metrics, Stream}
  alias Tackle.CLI.Widgets.Input

  @doc """
  Applies a bracketed paste as one edit.

  Line endings are normalized before the single native edit so pasted drafts
  contain no stray carriage returns regardless of the crate's behavior.
  """
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%State{} = state, content) do
    content = content |> String.replace("\r\n", "\n") |> String.replace("\r", "")
    :ok = Input.insert_str(state.input, content)
    state |> settle_history() |> Viewport.update_draft() |> Viewport.relayout()
  end

  @doc "Inserts a literal newline without submitting."
  @spec insert_newline(State.t()) :: {:noreply, State.t()}
  def insert_newline(%State{} = state) do
    :ok = Input.insert_str(state.input, "\n")
    {:noreply, state |> settle_history() |> Viewport.update_draft() |> Viewport.relayout()}
  end

  @doc """
  Hands a chord to the native input widget.

  The widget owns text editing, so unknown modified chords are ignored by the
  crate rather than by this module. A chord without a code is not an edit.
  """
  @spec key(State.t(), Key.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def key(%State{} = state, %Key{code: code, modifiers: modifiers}) when is_binary(code) do
    {width, _height} = state.size
    :ok = Input.handle_key(state.input, code, modifiers, max(width - 2, 1))
    {:noreply, state |> settle_history() |> Viewport.update_draft() |> Viewport.relayout()}
  end

  def key(%State{} = state, _key), do: {:noreply, state, render?: false}

  @doc """
  Handles a plain Up arrow.

  Up recalls the previous prompt when the draft is empty or a prompt is already
  showing. With a non-empty draft it moves the cursor instead, so a multi-line
  prompt being written is not hijacked by history; `history_previous/1` is the
  chord that always recalls.
  """
  @spec previous(State.t(), Key.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def previous(%State{} = state, key) do
    if state.draft_empty? or History.browsing?(state.history) do
      recall_previous(state)
    else
      key(state, key)
    end
  end

  @doc """
  Handles a plain Down arrow.

  Down steps toward the newest prompt while one is showing, or restores the
  draft captured when browsing began; with no prompt showing it moves the cursor.
  """
  @spec next(State.t(), Key.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def next(%State{} = state, key) do
    case History.next(state.history) do
      :none -> key(state, key)
      {history, text} -> {:noreply, load(state, history, text)}
    end
  end

  @doc """
  Recalls the previous (older) prompt, whatever the draft holds.

  This is the explicit history chord, so it does not defer to the cursor like
  the Up arrow does; the current draft is captured and handed back by
  `history_next/1`. Does nothing, without a render, on an empty history.
  """
  @spec history_previous(State.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def history_previous(%State{} = state), do: recall_previous(state)

  @doc """
  Recalls the next (newer) prompt, or restores the draft past the newest entry.

  Does nothing when no prompt is showing, so the chord is inert rather than
  clobbering the draft.
  """
  @spec history_next(State.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def history_next(%State{} = state) do
    case History.next(state.history) do
      :none -> {:noreply, state, render?: false}
      {history, text} -> {:noreply, load(state, history, text)}
    end
  end

  defp recall_previous(%State{} = state) do
    case History.previous(state.history, draft(state)) do
      :none -> {:noreply, state, render?: false}
      {history, text} -> {:noreply, load(state, history, text)}
    end
  end

  @doc """
  Submits the trimmed draft as the next turn, queues it at a safe boundary, or
  runs a shell command.

  `/tree` opens the conversation-tree picker instead of sending a prompt. An
  empty draft does nothing. A rejected submit reports the failure in the status
  row and restores the draft.
  """
  @spec submit(State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def submit(%State{} = state) do
    raw_draft = Input.get_value(state.input)

    cond do
      state.pending_operation != nil ->
        {:noreply, %{state | notice: "Busy · submission pending; draft kept"}}

      String.trim(raw_draft) == "/tree" and state.active_turn == nil ->
        {:noreply, open_tree(state)}

      state.draft_empty? ->
        {:noreply, state, render?: false}

      true ->
        submit_turn(state, raw_draft)
    end
  end

  defp open_tree(%State{} = state) do
    {:noreply, opened} = Tree.open(state)

    if match?({:tree, _}, opened.overlay) do
      :ok = Input.set_value(opened.input, "")
      opened |> Viewport.update_draft() |> Viewport.relayout()
    else
      # The picker did not open (no tree, empty tree); keep the draft intact.
      opened
    end
  end

  defp submit_turn(%State{} = state, raw_draft) do
    prompt = String.trim(raw_draft)
    ref = make_ref()
    agent_ref = state.agent_ref

    :ok = Input.set_value(state.input, "")

    state = %{
      state
      | pending_operation: %{ref: ref, kind: :submit, raw_draft: raw_draft},
        history: History.record(state.history, prompt),
        pending_prompt: prompt,
        stream: Stream.reset(state.stream),
        metrics: Metrics.reset(state.metrics),
        tool_activity: [],
        activity: "starting",
        error: nil,
        outcome: nil,
        notice: nil
    }

    state =
      state
      |> Viewport.update_draft()
      |> Viewport.scroll_to(:end)
      |> Viewport.refresh([:pending, :turn, :error])

    command =
      Command.async(
        fn -> Tackle.submit(agent_ref, prompt) end,
        &{:tui_operation_result, ref, :submit, &1}
      )

    {:noreply, state, commands: [command]}
  end

  defp draft(%State{} = state), do: Input.get_value(state.input)

  defp load(%State{} = state, history, text) do
    :ok = Input.set_value(state.input, text)
    %{state | history: history} |> Viewport.update_draft() |> Viewport.relayout()
  end

  # Editing, pasting, or inserting a newline turns a recalled prompt into a
  # normal draft, so the next Up captures it again instead of jumping positions.
  defp settle_history(%State{} = state),
    do: %{state | history: History.leave_browsing(state.history)}
end
