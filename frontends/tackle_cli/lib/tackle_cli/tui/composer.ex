defmodule Tackle.CLI.TUI.Composer do
  @moduledoc """
  Draft editing and submission for the native multiline composer.

  The composer is the one place a prompt is produced, so this module owns every
  way text gets into or out of it: native key handling, newline insertion,
  bracketed paste, and submission. Each edit ends in `Viewport.update_draft/1`
  and `Viewport.relayout/1` so the growing textarea reserves exactly the rows it
  needs without re-measuring the transcript.

  Submission is deliberately conservative. A failed submit keeps the exact draft
  in the composer so the user can retry or edit, and a submit while a turn is
  active keeps the draft as well: there is no queue, so the draft is labeled as
  belonging to the next turn instead of being delivered to the running one.
  """

  alias ExRatatui.Event.Key
  alias Tackle.CLI.TUI.{State, Util, Viewport}

  @doc """
  Applies a bracketed paste as one edit.

  Line endings are normalized before the single native edit so pasted drafts
  contain no stray carriage returns regardless of the crate's behavior.
  """
  @spec paste(State.t(), String.t()) :: State.t()
  def paste(%State{} = state, content) do
    content = content |> String.replace("\r\n", "\n") |> String.replace("\r", "")
    :ok = ExRatatui.textarea_insert_str(state.input, content)
    state |> Viewport.update_draft() |> Viewport.relayout()
  end

  @doc "Inserts a literal newline without submitting."
  @spec insert_newline(State.t()) :: {:noreply, State.t()}
  def insert_newline(%State{} = state) do
    :ok = ExRatatui.textarea_insert_str(state.input, "\n")
    {:noreply, state |> Viewport.update_draft() |> Viewport.relayout()}
  end

  @doc """
  Hands a chord to the native textarea.

  The widget owns text editing, so unknown modified chords are ignored by the
  crate rather than by this module. A chord without a code is not an edit.
  """
  @spec key(State.t(), Key.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def key(%State{} = state, %Key{code: code, modifiers: modifiers}) when is_binary(code) do
    :ok = ExRatatui.textarea_handle_key(state.input, code, modifiers)
    {:noreply, state |> Viewport.update_draft() |> Viewport.relayout()}
  end

  def key(%State{} = state, _key), do: {:noreply, state, render?: false}

  @doc """
  Submits the trimmed draft as the next turn.

  Does nothing while a turn is active (the draft is kept and labeled) or when
  the draft is empty. A rejected submit reports the failure in the status row
  and leaves the draft untouched.
  """
  @spec submit(State.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def submit(%State{} = state) do
    cond do
      state.active_turn ->
        {:noreply, %{state | notice: "Busy · draft kept for the next turn (not queued)"}}

      state.draft_empty? ->
        {:noreply, state, render?: false}

      true ->
        prompt = state.input |> ExRatatui.textarea_get_value() |> String.trim()

        case Tackle.submit(state.agent_ref, prompt) do
          {:ok, turn_id} ->
            :ok = ExRatatui.textarea_set_value(state.input, "")

            state = %{
              state
              | active_turn: %{id: turn_id},
                pending_prompt: prompt,
                streaming_thinking: "",
                streaming_response: "",
                live_usage: nil,
                live_context_usage: nil,
                tool_activity: [],
                activity: "starting",
                error: nil,
                outcome: nil,
                notice: nil,
                draft_lines: 1,
                draft_empty?: true
            }

            state = Viewport.scroll_to(state, :end)

            {:noreply, Viewport.refresh(state, [:pending, :tools, :thinking, :response, :error])}

          {:error, reason} ->
            # The exact draft stays in the composer so the user can retry or edit.
            {:noreply, Viewport.refresh(%{state | error: Util.format_reason(reason)}, [:error])}
        end
    end
  end
end
