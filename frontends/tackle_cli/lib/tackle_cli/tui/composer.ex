defmodule Tackle.CLI.TUI.Composer do
  @moduledoc """
  Draft editing and submission for the native multiline composer.

  The composer is the one place a prompt is produced, so this module owns every
  way text gets into or out of it: native key handling, newline insertion,
  bracketed paste, and submission. Each edit ends in `Viewport.update_draft/1`
  and `Viewport.relayout/1` so the growing input reserves exactly the rows it
  needs without re-measuring the transcript.

  Submission is deliberately conservative. A failed submit keeps the exact draft
  in the composer so the user can retry or edit, and a submit while a turn is
  active keeps the draft as well: there is no queue, so the draft is labeled as
  belonging to the next turn instead of being delivered to the running one.
  """

  alias ExRatatui.Command
  alias ExRatatui.Event.Key
  alias Tackle.CLI.TUI.{State, Tree, Viewport}
  alias Tackle.CLI.TUI.State.{Metrics, Stream}

  @doc """
  Applies a bracketed paste as one edit.

  Line endings are normalized before the single native edit so pasted drafts
  contain no stray carriage returns regardless of the crate's behavior.
  """
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%State{} = state, content) do
    content = content |> String.replace("\r\n", "\n") |> String.replace("\r", "")
    :ok = Tackle.CLI.Widgets.Input.insert_str(state.input, content)
    state |> Viewport.update_draft() |> Viewport.relayout()
  end

  @doc "Inserts a literal newline without submitting."
  @spec insert_newline(State.t()) :: {:noreply, State.t()}
  def insert_newline(%State{} = state) do
    :ok = Tackle.CLI.Widgets.Input.insert_str(state.input, "\n")
    {:noreply, state |> Viewport.update_draft() |> Viewport.relayout()}
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
    :ok = Tackle.CLI.Widgets.Input.handle_key(state.input, code, modifiers, max(width - 2, 1))
    {:noreply, state |> Viewport.update_draft() |> Viewport.relayout()}
  end

  def key(%State{} = state, _key), do: {:noreply, state, render?: false}

  @doc """
  Submits the trimmed draft as the next turn, or runs a shell command.

  `/tree` opens the conversation-tree picker instead of sending a prompt. Does
  nothing while a turn is active (the draft is kept and labeled) or when the
  draft is empty. A rejected submit reports the failure in the status row and
  leaves the draft untouched.
  """
  @spec submit(State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def submit(%State{} = state) do
    raw_draft = Tackle.CLI.Widgets.Input.get_value(state.input)

    cond do
      state.active_turn != nil or state.pending_operation != nil ->
        {:noreply, %{state | notice: "Busy · draft kept for the next turn (not queued)"}}

      String.trim(raw_draft) == "/tree" ->
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
      :ok = Tackle.CLI.Widgets.Input.set_value(opened.input, "")
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

    :ok = Tackle.CLI.Widgets.Input.set_value(state.input, "")

    state = %{
      state
      | pending_operation: %{ref: ref, kind: :submit, raw_draft: raw_draft},
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
end
