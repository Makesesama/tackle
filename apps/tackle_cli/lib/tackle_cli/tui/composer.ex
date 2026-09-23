defmodule Tackle.CLI.TUI.Composer do
  @moduledoc """
  Draft editing and submission for the native multiline composer.

  The composer is the one place a prompt is produced, so this module owns every
  way text gets into or out of it: native key handling, newline insertion,
  bracketed paste, submission, and prompt history. Each edit ends in
  `Viewport.update_draft/1` and `Viewport.relayout/1` so the growing input
  reserves exactly the rows it needs without re-measuring the transcript.

  History recall reuses the same native load path: the recalled prompt is set
  as the draft and the row count is left to `Viewport`. Up recalls the newest
  prompt even while writing a draft; Down walks back toward that draft while
  browsing, or moves the cursor otherwise. Ctrl+P/Ctrl+N offer the same history
  navigation. Any edit ends recall, keeping the loaded text as the new draft.

  A failed submit restores the exact draft so the user can retry or edit.
  Submissions during an active turn are queued for the next safe boundary.
  """

  alias ExRatatui.Command
  alias ExRatatui.Event.Key
  alias Tackle.CLI.TUI.{History, Layout, State, Tree, Viewport}
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
    content = image_path_prompt(content) || content
    :ok = Input.insert_str(state.input, content)
    state |> settle_history() |> Viewport.update_draft() |> Viewport.relayout()
  end

  # Some terminals paste images as file paths rather than clipboard bytes.
  # Only reinterpret a single existing, supported image path; arbitrary text
  # and multi-line pastes must keep their usual editing behavior.
  defp image_path_prompt(content) do
    path = String.trim(content)

    if path != "" and not String.contains?(path, ["\n", "\r"]) and File.regular?(path) do
      case File.stat(path) do
        {:ok, %{size: size}} when size <= 5 * 1024 * 1024 ->
          case File.read(path) do
            {:ok, bytes} ->
              case Tackle.CLI.ImageClipboard.image_extension(bytes) do
                {:ok, _extension} ->
                  " Please use the read tool to inspect this image: #{Path.expand(path)} "

                _ ->
                  nil
              end

            _ ->
              nil
          end

        _ ->
          nil
      end
    end
  end

  @doc "Pastes an image from the OS clipboard, or text when no image is available."
  @spec paste_clipboard(State.t()) :: {:noreply, State.t()}
  def paste_clipboard(%State{} = state) do
    case state.clipboard_image_reader.() do
      {:ok, bytes} ->
        case Tackle.CLI.ImageClipboard.save(bytes) do
          {:ok, path} ->
            {:noreply,
             paste(
               %{state | image_paths: [path | state.image_paths]},
               " Please use the read tool to inspect this image: #{path} "
             )}

          {:error, reason} ->
            image_error(state, reason)
        end

      {:error, :no_image_in_clipboard} ->
        paste_clipboard_text(state)

      {:error, reason} ->
        image_error(state, reason)

      other ->
        image_error(state, {:invalid_clipboard_result, other})
    end
  end

  defp paste_clipboard_text(state) do
    case state.clipboard_text_reader.() do
      {:ok, text} when is_binary(text) -> {:noreply, paste(state, text)}
      {:error, reason} -> image_error(state, reason)
      other -> image_error(state, {:invalid_clipboard_result, other})
    end
  end

  defp image_error(state, reason) do
    {:noreply, %{state | notice: "Image paste failed: #{inspect(reason)} · draft kept"}}
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
    {width, height} = state.size

    :ok =
      Input.handle_key(state.input, code, modifiers, Layout.composer_content_width(width, height))

    {:noreply, state |> settle_history() |> Viewport.update_draft() |> Viewport.relayout()}
  end

  def key(%State{} = state, _key), do: {:noreply, state, render?: false}

  @doc "Recalls the next older prompt, saving the current draft for Down to restore."
  @spec previous(State.t(), Key.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def previous(%State{} = state, _key), do: recall_previous(state)

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

  The current draft is captured and handed back by `history_next/1`. Does
  nothing, without a render, on an empty history.
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
        notice: nil
    }

    state =
      if state.active_turn == nil do
        %{
          state
          | pending_prompt: prompt,
            stream: Stream.reset(state.stream),
            metrics: Metrics.reset(state.metrics),
            tool_activity: [],
            activity: "starting",
            error: nil,
            outcome: nil
        }
      else
        state
      end

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

  @doc "Clears the draft and ends history browsing without affecting the active turn."
  @spec clear(State.t()) :: {:noreply, State.t()}
  def clear(%State{} = state) do
    :ok = Input.set_value(state.input, "")
    {:noreply, state |> settle_history() |> Viewport.update_draft() |> Viewport.relayout()}
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
