defmodule Tackle.CLI.TUI do
  @moduledoc """
  Interactive terminal frontend for a scoped Tackle agent.

  The shell is transcript-first: a compact header, a border-light transcript
  that owns the flexible middle of the screen, a native multiline composer that
  grows with the draft, and optional reading, status, and hint rows.

  Two kinds of surface sit above the composer:

    * **Menus** are modal search-first lists that always route keys before the
      composer: the model (`F1`), the reasoning level (`F2`), and settings
      (`F3`), plus the output inspector and transcript search. Menus hold
      configuration; settings includes the persistent subagent-sidebar
      visibility preference.
    * **The `@` file-mention popup** floats above the composer while the caret
      is on an `@token`. It never takes over editing: typing keeps refining the
      query, `↑`/`↓` (or Ctrl+P/N) move the selection, Enter or Tab insert the
      selected file's full workspace-relative path in place of the token, and
      Esc dismisses it for that token. The workspace index is built once,
      asynchronously, with a bounded walk.
    * **The `/` command popup** floats above the composer while the caret is
      inside the leading `/name` fragment, listing the registered commands
      with their descriptions. Typing refines the query, `↑`/`↓` (or
      Ctrl+P/N) move the selection, Tab completes the selected name into the
      draft, Enter runs the selected command, and Esc dismisses it for that
      fragment. One registry backs both the popup and submission, so what the
      popup offers is exactly what a submitted `/name` runs.
    * **The transcript browser** (`F4`) is a focus mode rather than an overlay.
      There is no popup, the composer stops accepting text, and the arrows move
      a highlighted entry so it can be copied (`y`, `a`) or inspected (`Enter`).
      Esc or `F4` returns to the prompt.
      Left/right or Tab switches to Overview, Prompt, Context, Tools and Events
      within the same native Browse widget; R refreshes these frozen pages.
    * **Usage** (`F6`) is a modal chronological chart over settled durable
      token usage, switchable between the current session and all sessions.
    * **Review** (`/review`) runs a code review of the current change in the
      background and shows its progress, then its findings, in a full-screen
      overlay with feedback and fix actions; `/findings` reopens it.

  The TUI owns presentation and input state while the root harness continues to
  own the scope and agent loop. It addresses the root agent through a
  `Tackle.Runtime.AgentRef` and detects crashes through the PID-free monitoring
  operation, so it never retains a runtime PID. Events are correlated by
  session id and active turn id; stale events cannot mutate the current turn.

  While a turn is active the composer keeps accepting drafts; Enter queues
  them for the next safe boundary. Esc leaves the transcript browser, closes
  overlays, clears a composer-made selection, clears a non-empty draft, then
  requests cancellation on a subsequent
  press, and never exits while idle; Ctrl+C is
  the distinct quit action and asks for confirmation when a draft or active turn
  would be lost.

  `Alt+P` and `Alt+N` step the transcript selection up and down without
  leaving the composer, and `Alt+W` copies the selected message; they reuse the
  browser's selection, so the highlighted entry is the one the browser acts on.

  `/new` starts a new session behind a yes/no confirmation. The frontend asks
  the harness for a fresh root scope, subscribes to its root agent, and stops
  the previous scope, so the shell, its configuration menus, and the terminal
  stay up. `/archive` does the same and then archives the previous session.
  Resuming a session whose provider cache has likely expired asks first (see
  `Tackle.CLI.TUI.ResumeConfirm`).

  This module is the coordinator: it owns the ExRatatui callbacks, the key
  table routing, and the process lifecycle. Each surface has its own module
  that takes and returns `Tackle.CLI.TUI.State`:

  | module | owns |
  | --- | --- |
  | `Tackle.CLI.TUI.State` | the state struct, mounting, and session reset |
  | `Tackle.CLI.TUI.Viewport` | transcript/layout synchronization and scrolling |
  | `Tackle.CLI.TUI.RuntimeEvents` | projecting harness events into state |
  | `Tackle.CLI.TUI.Composer` | draft editing and submission |
  | `Tackle.CLI.TUI.ExternalEditor` | editing the draft in `$VISUAL`/`$EDITOR` |
  | `Tackle.CLI.TUI.Diagnostics` | read-only diagnostic pages |
  | `Tackle.CLI.TUI.Observations` | bounded, correlated local event history |
  | `Tackle.CLI.TUI.Browser` | transcript focus, selection, and copy |
  | `Tackle.CLI.TUI.Workflows` | `/workflows`: run, edit, and create saved Lua workflows |
  | `Tackle.CLI.TUI.Review` | `/review` and `/findings`: background code review and feedback |
  | `Tackle.CLI.TUI.Menu` | model, reasoning, and settings pickers |
  | `Tackle.CLI.TUI.Tree` | the `/tree` conversation picker and navigation |
  | `Tackle.CLI.TUI.FileSearch` | the `@` file-mention popup and workspace index |
  | `Tackle.CLI.TUI.SlashCommands` | the `/` command registry, popup, and dispatch |
  | `Tackle.CLI.TUI.UsageChart` | durable usage loading, bucketing, and chart popup |
  | `Tackle.CLI.TUI.Search` | transcript search |
  | `Tackle.CLI.TUI.Inspector` | the scrollable tool-output inspector |
  | `Tackle.CLI.TUI.Session` | root scope ownership and teardown |
  | `Tackle.CLI.TUI.TerminalTitle` | terminal window title synchronization |
  | `Tackle.CLI.TUI.Herdr` | agent state and resume reports to a Herdr pane |
  | `Tackle.CLI.TUI.Notifications` | completion notifications while unfocused |
  | `Tackle.CLI.TUI.View` | the scene and ordinary widgets |
  | `Tackle.CLI.TUI.StatusView` | status row, metrics, and hints |
  """

  use ExRatatui.App

  alias ExRatatui.Command
  alias ExRatatui.Event.{FocusGained, FocusLost, Key, Mouse, Paste, Resize}
  alias Tackle.CLI.TUI.TextSelection
  alias ExRatatui.Subscription
  alias Tackle.CLI.Keybinds
  alias Tackle.CLI.Widgets.Input

  alias Tackle.CLI.TUI.{
    Browser,
    Compaction,
    Composer,
    Conversation,
    ExternalEditor,
    FileSearch,
    Help,
    Herdr,
    Inspector,
    Menu,
    Workflows,
    Resume,
    ResumeConfirm,
    Review,
    RuntimeEvents,
    RecentSessions,
    Search,
    Session,
    SlashCommands,
    State,
    SubagentView,
    Subagents,
    TerminalBackground,
    TerminalTitle,
    Tree,
    UsageChart,
    Util,
    View,
    Viewport
  }

  @doc """
  Runs the shell until the user quits.

  Returns the session the shell was attached to when it exited, so the caller
  can offer to resume it. That session is the one the shell last displayed,
  which is not necessarily the one it was started with.
  """
  @spec start(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def start(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :test_mode) do
      start_with_quiet_console(opts)
    else
      Tackle.CLI.TUI.Logging.with_quiet_console(fn -> start_with_quiet_console(opts) end)
    end
  end

  defp start_with_quiet_console(opts) do
    opts =
      opts
      |> Keyword.put_new(:mouse_capture, true)
      # Focus reporting drives the completion notifications: a turn that
      # finishes while the window is unfocused asks for the user's attention.
      |> Keyword.put_new(:focus_events, true)

    caller = self()
    result_ref = make_ref()

    {_runner, monitor_ref} =
      spawn_monitor(fn -> run_app(caller, result_ref, opts) end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, _runner, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def mount(opts) do
    # Ask the terminal for its background before the first frame renders;
    # test terminals have no controlling terminal to ask.
    if not Keyword.has_key?(opts, :test_mode) do
      TerminalBackground.detect_and_remember()
    end

    # Test terminals have no graphics protocol. A caller may inject one for
    # deterministic scene tests without probing the real controlling TTY.
    protocol =
      if Keyword.has_key?(opts, :test_mode),
        do: Keyword.get(opts, :header_protocol),
        else: detect_graphics_protocol()

    image =
      if protocol in [:kitty, :sixel, :iterm2] do
        case ExRatatui.Image.new(Tackle.CLI.TUI.Glyph.png(), protocol: :auto, resize: :scale) do
          {:ok, widget} -> widget
          {:error, _reason} -> nil
        end
      end

    opts = Keyword.put(opts, :header_image, image)

    case State.new(opts) do
      {:ok, state} ->
        {state, commands} = RecentSessions.load(state)
        state = %{state | herdr: Herdr.start(opts)}

        {:ok, refresh_status(state),
         commands: commands,
         probe_image_protocol: not is_nil(image) and not Keyword.has_key?(opts, :test_mode)}

      error ->
        error
    end
  end

  defp detect_graphics_protocol do
    case ExRatatui.Image.probe_terminal() do
      {:ok, %{protocol: protocol}} when protocol in [:kitty, :sixel, :iterm2] -> protocol
      _ -> nil
    end
  end

  @impl true
  def render(%State{full_repaint?: true}, frame), do: ExternalEditor.blank(frame)
  def render(state, frame), do: View.scene(state, frame)

  @doc false
  @spec scene(State.t(), ExRatatui.Frame.t()) :: [{struct(), ExRatatui.Layout.Rect.t()}]
  def scene(state, frame), do: View.scene(state, frame)

  # -- input routing -------------------------------------------------------

  @impl true
  def handle_event(%Key{kind: "release"}, state), do: {:noreply, state, render?: false}

  def handle_event(%Key{} = key, state) do
    key
    |> dispatch_key(%{state | notice: nil, queue_notice_at: nil})
    |> sync_completions()
    |> refresh_status()
  end

  def handle_event(%Paste{content: content}, state) do
    {updated, commands, _changed?} = state |> handle_paste(content) |> sync_popups()

    if commands == [],
      do: {:noreply, updated},
      else: {:noreply, updated, commands: commands}
  end

  # Focus is bookkeeping for the completion notifications; nothing on screen
  # depends on it, so the frame is not repainted.
  def handle_event(%FocusGained{}, state),
    do: {:noreply, %{state | terminal_focused?: true}, render?: false}

  def handle_event(%FocusLost{}, state),
    do: {:noreply, %{state | terminal_focused?: false}, render?: false}

  def handle_event(%Resize{width: width, height: height}, state) do
    state = %{state | size: {width, height}}
    state = resize_overlay(state)

    {:noreply, Viewport.resize(state)}
  end

  def handle_event(%Mouse{kind: kind} = mouse, state) when kind in ["scroll_up", "scroll_down"] do
    delta =
      if kind == "scroll_up",
        do: -Conversation.mouse_scroll_rows(),
        else: Conversation.mouse_scroll_rows()

    case state.overlay do
      {:inspector, _inspector} ->
        {:noreply, Inspector.scroll(state, delta)}

      {:subagent_view, _view} ->
        {:noreply, SubagentView.scroll(state, delta)}

      nil ->
        scroll_conversation(state, mouse, delta)

      _overlay ->
        {:noreply, state, render?: false}
    end
  end

  def handle_event(%Mouse{button: "left", kind: kind} = mouse, state)
      when kind in ["down", "drag", "up"] do
    updated = TextSelection.mouse(mouse, state)
    {:noreply, updated, render?: updated != state}
  end

  def handle_event(_event, state), do: {:noreply, state, render?: false}

  defp scroll_conversation(state, mouse, delta) do
    case {Conversation.contains?(state.conversation, mouse.x, mouse.y), Browser.page?(state)} do
      {true, true} ->
        {:noreply, Browser.scroll(state, delta)}

      {true, false} ->
        updated = state |> Viewport.scroll(delta) |> TextSelection.after_scroll()
        {:noreply, updated, render?: updated != state}

      _other ->
        {:noreply, state, render?: false}
    end
  end

  # -- runtime events ------------------------------------------------------

  @impl true
  def handle_info({:text_selection_tick, token}, state) do
    updated = TextSelection.tick(state, token)
    {:noreply, updated, render?: updated != state}
  end

  # An external editor reports the terminal's size when it gives the terminal
  # back, because a resize while it ran never reached the shell's input poll.
  def handle_info(%Resize{} = resize, state), do: handle_event(resize, state)

  def handle_info(message, state) do
    if ExternalEditor.repainted?(message),
      do: {:noreply, %{state | full_repaint?: false}},
      else: RuntimeEvents.handle(message, state) |> refresh_status()
  end

  # The terminal title and the Herdr pane track the session and its activity,
  # which only change under key dispatch and runtime events; every other reply
  # shape passes through.
  defp refresh_status({:noreply, %State{} = state}),
    do: {:noreply, refresh_status(state)}

  defp refresh_status({:noreply, %State{} = state, opts}) when is_list(opts),
    do: {:noreply, refresh_status(state), opts}

  defp refresh_status(%State{} = state), do: state |> TerminalTitle.refresh() |> Herdr.refresh()

  defp refresh_status(other), do: other

  # Every key event ends here, so the `@` file-mention and `/` command popups
  # follow the draft no matter which chord edited it. A popup appearing or
  # disappearing must repaint even when the edit itself did not.
  defp sync_completions({:noreply, %State{} = state, opts}) when is_list(opts) do
    {updated, commands, changed?} = sync_popups(state)

    opts = Keyword.merge(opts, commands: commands ++ Keyword.get(opts, :commands, []))
    opts = if changed?, do: Keyword.put(opts, :render?, true), else: opts

    {:noreply, updated, opts}
  end

  defp sync_completions({:noreply, %State{} = state}) do
    {updated, commands, _changed?} = sync_popups(state)

    if commands == [],
      do: {:noreply, updated},
      else: {:noreply, updated, commands: commands}
  end

  defp sync_completions(other), do: other

  # The two inline completions are disjoint by construction — a leading
  # `/name` fragment is never an `@token` — and each sync leaves a foreign
  # overlay untouched, so they can run in sequence over the same draft.
  defp sync_popups(%State{} = state) do
    before = state.overlay

    {state, file_commands} = FileSearch.sync(state)
    {state, slash_commands} = SlashCommands.sync(state)

    {state, file_commands ++ slash_commands, state.overlay != before}
  end

  @impl true
  def subscriptions(state) do
    if state.storage == :delayed or state.active_turn != nil or state.pending_operation != nil or
         Review.animating?(state) do
      [Subscription.interval(:tui_spinner, 80, {:tui_spinner_tick})]
    else
      []
    end
  end

  @impl true
  def terminate(_reason, state) do
    # The title is the shell's own decoration, so it leaves with the shell.
    TerminalTitle.clear(state)

    # Releasing tells Herdr the agent left the pane, so it drops the state and
    # the resume command instead of waiting to see the shell prompt return.
    Herdr.release(state)

    # The shell owns whichever scope it is currently attached to, which is the
    # initial scope until a new session replaces it. Stopping it here keeps a
    # swapped-in scope from outliving the shell.
    Session.retire(state)

    Enum.each(state.image_paths, &Tackle.Executor.delete(state.executor, &1))

    notify_owner(state)
    :ok
  end

  # -- key dispatch --------------------------------------------------------

  defp dispatch_key(%Key{kind: "repeat"} = key, %{overlay: {:review, _}} = state) do
    if Keybinds.review_repeatable?(key),
      do: dispatch(key, state),
      else: {:noreply, state, render?: false}
  end

  defp dispatch_key(%Key{kind: "repeat"} = key, state) do
    if Keybinds.repeatable?(key),
      do: dispatch(key, state),
      else: {:noreply, state, render?: false}
  end

  defp dispatch_key(key, state), do: dispatch(key, state)

  defp dispatch(key, state) do
    selection? = TextSelection.enabled?(state) and state.conversation.text_selection != nil

    cond do
      selection? and key.code == "esc" ->
        {:noreply, TextSelection.clear(state)}

      selection? and key.code == "c" and "ctrl" in key.modifiers and
          TextSelection.selected?(state) ->
        {:noreply, TextSelection.copy(state)}

      true ->
        dispatch_unselected(key, state)
    end
  end

  defp dispatch_unselected(key, state) do
    case Keybinds.global(key) do
      :quit -> quit(state)
      :unbound -> dispatch_overlay(key, state)
    end
  end

  defp dispatch_overlay(key, %{overlay: nil} = state),
    do: dispatch_base(Keybinds.base(key, state.focus), key, state)

  defp dispatch_overlay(key, %{overlay: {:help, _}} = state),
    do: Help.handle(Keybinds.help(key), state)

  defp dispatch_overlay(key, %{overlay: {:confirm_quit, _}} = state) do
    case Keybinds.confirm(key) do
      :confirm -> {:stop, state}
      :cancel -> {:noreply, %{state | overlay: nil}}
      :ignore -> {:noreply, state, render?: false}
    end
  end

  defp dispatch_overlay(key, %{overlay: {:confirm_new_session, _}} = state) do
    case Keybinds.confirm(key) do
      :confirm -> Session.start_new(state)
      :cancel -> {:noreply, %{state | overlay: nil}}
      :ignore -> {:noreply, state, render?: false}
    end
  end

  defp dispatch_overlay(key, %{overlay: {:confirm_archive, _}} = state) do
    case Keybinds.confirm(key) do
      :confirm -> Session.archive_current(state)
      :cancel -> {:noreply, %{state | overlay: nil}}
      :ignore -> {:noreply, state, render?: false}
    end
  end

  defp dispatch_overlay(key, %{overlay: {:confirm_resume, _}} = state),
    do: ResumeConfirm.handle(Keybinds.confirm(key), state)

  defp dispatch_overlay(key, %{overlay: {:workflows, _}} = state),
    do: Workflows.handle(Keybinds.workflows(key), state)

  defp dispatch_overlay(key, %{overlay: {:picker, _}} = state),
    do: Menu.handle(Keybinds.picker(key), state)

  defp dispatch_overlay(key, %{overlay: {:tree, _}} = state),
    do: Tree.handle(Keybinds.tree(key), state)

  defp dispatch_overlay(key, %{overlay: {:resume, _}} = state),
    do: Resume.handle(Keybinds.resume(key), state)

  # The file-mention popup floats above the composer without owning editing:
  # its own intents navigate and accept, everything else keeps typing.
  defp dispatch_overlay(key, %{overlay: {:file_search, _}} = state) do
    case Keybinds.file_search(key) do
      :composer -> dispatch_base(:composer, key, state)
      intent -> FileSearch.handle(intent, state)
    end
  end

  # The command popup floats the same way: its own intents navigate,
  # complete, and run; everything else keeps typing.
  defp dispatch_overlay(key, %{overlay: {:slash_commands, _}} = state) do
    case Keybinds.slash_commands(key) do
      :composer -> dispatch_base(:composer, key, state)
      intent -> SlashCommands.handle(intent, state)
    end
  end

  defp dispatch_overlay(key, %{overlay: {:inspector, _}} = state),
    do: Inspector.handle(Keybinds.inspector(key), state)

  defp dispatch_overlay(key, %{overlay: {:subagent_view, _}} = state),
    do: SubagentView.handle(Keybinds.subagent_view(key), state)

  defp dispatch_overlay(key, %{overlay: {:search, _}} = state),
    do: Search.handle(Keybinds.search(key), state)

  defp dispatch_overlay(key, %{overlay: {:usage_chart, _}} = state),
    do: UsageChart.handle(Keybinds.usage_chart(key), state)

  defp dispatch_overlay(key, %{overlay: {:review, _}} = state),
    do: Review.handle(Keybinds.review(key), state)

  # Behaviour for each intent the binding table can return. Keeping one clause
  # per intent means an addition to `Keybinds` fails loudly here until it is
  # given behaviour, instead of silently doing nothing.
  defp dispatch_base(:help, key, state) do
    if state.focus != :composer or state.draft_empty? do
      Help.open(state)
    else
      Composer.key(state, key)
    end
  end

  defp dispatch_base(:model_picker, _key, state), do: Menu.open(:model, state)
  defp dispatch_base(:thinking_picker, _key, state), do: Menu.open(:thinking, state)
  defp dispatch_base(:settings_picker, _key, state), do: Menu.open(:settings, state)
  defp dispatch_base(:browse, _key, state), do: Browser.toggle_focus(state)
  defp dispatch_base(:escape, _key, state), do: escape(state)
  defp dispatch_base(:copy_final_answer, _key, state), do: copy_final_answer(state)

  defp dispatch_base({:resume_recent, index}, _key, state),
    do: Session.resume_recent(state, index)

  defp dispatch_base(:select_previous, _key, state), do: {:noreply, Browser.select(state, -1)}
  defp dispatch_base(:select_next, _key, state), do: {:noreply, Browser.select(state, 1)}
  defp dispatch_base(:copy_selected, _key, state), do: Browser.copy_selected(state)

  defp dispatch_base(:compact, _key, state), do: Compaction.request(state)
  defp dispatch_base(:external_editor, _key, state), do: ExternalEditor.open(state)
  defp dispatch_base(:tree, _key, state), do: Tree.open(state)
  defp dispatch_base(:usage_chart, _key, state), do: UsageChart.open(state)
  defp dispatch_base(:subagents, _key, state), do: Subagents.focus(state)
  defp dispatch_base(:toggle_thinking, _key, state), do: Viewport.toggle_thinking(state)

  defp dispatch_base(:scroll_start, _key, state),
    do: Viewport.scroll_reply(state, Viewport.scroll_to(state, :start))

  defp dispatch_base(:scroll_end, _key, state),
    do: Viewport.scroll_reply(state, Viewport.scroll_to(state, :end))

  defp dispatch_base(:page_up, _key, state),
    do: Viewport.scroll_reply(state, Viewport.scroll(state, -Viewport.page_size(state)))

  defp dispatch_base(:page_down, _key, state),
    do: Viewport.scroll_reply(state, Viewport.scroll(state, Viewport.page_size(state)))

  defp dispatch_base(:newline, _key, state), do: Composer.insert_newline(state)
  defp dispatch_base(:paste_clipboard, _key, state), do: Composer.paste_clipboard(state)
  defp dispatch_base(:submit, _key, state), do: Composer.submit(state)
  defp dispatch_base(:history_previous, _key, state), do: Composer.history_previous(state)
  defp dispatch_base(:history_next, _key, state), do: Composer.history_next(state)
  defp dispatch_base(:previous, key, state), do: Composer.previous(state, key)
  defp dispatch_base(:next, key, state), do: Composer.next(state, key)
  defp dispatch_base(:composer, key, state), do: Composer.key(state, key)

  defp dispatch_base({:subagents, intent}, _key, state),
    do: Subagents.handle(intent, state)

  defp dispatch_base({:transcript, intent}, _key, state),
    do: Browser.handle(intent, state)

  # -- paste ---------------------------------------------------------------

  defp handle_paste(%{overlay: {:search, _}} = state, content), do: Search.paste(state, content)

  defp handle_paste(%{overlay: {:workflows, _}} = state, content),
    do: Workflows.paste(state, content)

  defp handle_paste(%{overlay: {:picker, _}} = state, content), do: Menu.paste(state, content)
  defp handle_paste(%{overlay: {:tree, _}} = state, content), do: Tree.paste(state, content)
  defp handle_paste(%{overlay: {:resume, _}} = state, content), do: Resume.paste(state, content)

  # The transcript browser owns the keyboard, so a paste must not land in a
  # composer the user cannot see the cursor in.
  defp handle_paste(%{focus: :transcript} = state, content), do: Browser.paste(state, content)

  defp handle_paste(%{overlay: nil} = state, content), do: Composer.paste(state, content)

  defp handle_paste(state, _content), do: state

  # -- base actions --------------------------------------------------------

  # Ctrl+O copies the raw Markdown of the latest final answer, mirroring the
  # Codex shortcut. A turn in progress does not block it: the previous answer
  # stays copyable until the new one is complete.
  defp copy_final_answer(state) do
    notice =
      case State.latest_final_answer(state.agent_state) do
        nil -> "No final answer to copy"
        answer -> Util.copy_notice(state, answer, "Copied final answer")
      end

    {:noreply, %{state | notice: notice}}
  end

  # Esc peels one layer per press: a composer-made selection first, then a
  # non-empty draft, then cancellation.
  defp escape(%State{selected_entry: selected} = state) when is_binary(selected),
    do: {:noreply, Browser.clear_selection(state)}

  defp escape(state) do
    if Input.get_value(state.input) != "" do
      Composer.clear(state)
    else
      escape_empty(state)
    end
  end

  defp escape_empty(%{active_turn: nil, pending_operation: nil} = state) do
    {:noreply, %{state | notice: "Idle · Esc does not quit · Ctrl+C quits"}}
  end

  defp escape_empty(%{pending_operation: %{kind: :submit} = operation} = state) do
    agent_ref = state.agent_ref
    ref = operation.ref

    command =
      Command.async(
        fn -> Tackle.cancel(agent_ref) end,
        &{:tui_submit_cancel_result, ref, &1}
      )

    dispatch? =
      state.storage == :delayed and not Map.get(operation, :cancellation_dispatched?, false)

    commands = if dispatch?, do: [command], else: []

    operation =
      operation
      |> Map.put(:cancellation_requested?, true)
      |> Map.put(
        :cancellation_dispatched?,
        dispatch? or Map.get(operation, :cancellation_dispatched?, false)
      )

    # Preserve the submit correlation while cancelling its already-admitted
    # beginning turn. Waiting for submit to return could wait forever on sync.
    {:noreply,
     %{state | pending_operation: operation, activity: "cancelling", notice: "Cancelling…"},
     commands: commands}
  end

  defp escape_empty(%{pending_operation: %{kind: :compact}} = state) do
    {:noreply, %{state | notice: "Manual compaction cannot be cancelled; draft kept"}}
  end

  defp escape_empty(%{pending_operation: %{kind: :cancel}} = state) do
    {:noreply, %{state | notice: "Cancellation already requested"}}
  end

  defp escape_empty(%{activity: "cancelling"} = state) do
    {:noreply, %{state | notice: "Cancellation already requested"}}
  end

  defp escape_empty(state) do
    ref = make_ref()
    agent_ref = state.agent_ref

    command =
      Command.async(
        fn -> Tackle.cancel(agent_ref) end,
        &{:tui_operation_result, ref, :cancel, &1}
      )

    state = %{
      state
      | pending_operation: %{ref: ref, kind: :cancel},
        activity: "cancelling"
    }

    {:noreply, state, commands: [command]}
  end

  defp quit(%{active_turn: nil, pending_operation: nil} = state) do
    if state.draft_empty? do
      {:stop, state}
    else
      {:noreply, %{state | overlay: {:confirm_quit, %{reason: :draft}}}}
    end
  end

  defp quit(state) do
    {:noreply, %{state | overlay: {:confirm_quit, %{reason: :turn}}}}
  end

  defp resize_overlay(%{overlay: {:inspector, _inspector}} = state), do: Inspector.resize(state)
  defp resize_overlay(%{overlay: {:subagent_view, _view}} = state), do: SubagentView.resize(state)
  defp resize_overlay(%{overlay: {:search, _search}} = state), do: Search.refresh(state)
  defp resize_overlay(%{overlay: {:tree, _tree}} = state), do: Tree.resize(state)
  defp resize_overlay(state), do: state

  # -- app lifecycle -------------------------------------------------------

  # The shell reports the session it leaves behind to the process that started
  # it, because only that process survives the terminal teardown and can print
  # a resume command afterwards.
  defp notify_owner(%State{owner: owner, session_id: session_id}) when is_pid(owner) do
    send(owner, {:tui_exit, session_id})
    :ok
  end

  defp notify_owner(_state), do: :ok

  defp run_app(caller, result_ref, opts) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)

    opts =
      opts
      |> Keyword.put_new(:name, nil)
      |> Keyword.put(:owner, self())

    result =
      case start_link(opts) do
        {:ok, pid} -> await_exit(pid, caller, caller_monitor, nil, nil)
        {:error, reason} -> {:error, reason}
      end

    if result != :caller_down, do: send(caller, {result_ref, result})
  end

  defp await_exit(pid, caller, caller_monitor, reported_session_id, runtime_error) do
    receive do
      {:tui_exit, session_id} ->
        await_exit(pid, caller, caller_monitor, session_id, runtime_error)

      {:tui_runtime_error, reason} ->
        await_exit(pid, caller, caller_monitor, reported_session_id, reason)

      {:EXIT, ^pid, reason} when reason in [:normal, :shutdown] ->
        if runtime_error, do: {:error, runtime_error}, else: {:ok, reported_session_id}

      {:EXIT, ^pid, reason} ->
        {:error, reason}

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, :infinity)
        :caller_down
    end
  end
end
