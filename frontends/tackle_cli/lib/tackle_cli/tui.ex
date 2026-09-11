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
      configuration, and the settings menu stays empty until the harness gains
      options beyond the model and the reasoning level; quick actions do not
      belong in it.
    * **The transcript browser** (`F4`) is a focus mode rather than an overlay.
      There is no popup, the composer stops accepting text, and the arrows move
      a highlighted entry so it can be copied (`y`, `a`) or inspected (`Enter`).
      Esc or `F4` returns to the prompt.

  The TUI owns presentation and input state while the root harness continues to
  own the scope and agent loop. It addresses the root agent through a
  `Tackle.Runtime.AgentRef` and detects crashes through the PID-free monitoring
  operation, so it never retains a runtime PID. Events are correlated by
  session id and active turn id; stale events cannot mutate the current turn.

  While a turn is active the composer keeps accepting a draft, but Enter does
  not submit it: there is no queue, so the draft is explicitly labeled as
  belonging to the next turn. Esc leaves the transcript browser, closes
  overlays, then requests cancellation, and never exits while idle; Ctrl+C is
  the distinct quit action and asks for confirmation when a draft or active turn
  would be lost.

  `Alt+N` starts a new session behind a yes/no confirmation. The frontend asks
  the harness for a fresh root scope, subscribes to its root agent, and stops
  the previous scope, so the shell, its configuration menus, and the terminal
  stay up.

  This module is the coordinator: it owns the ExRatatui callbacks, the key
  table routing, and the process lifecycle. Each surface has its own module
  that takes and returns `Tackle.CLI.TUI.State`:

  | module | owns |
  | --- | --- |
  | `Tackle.CLI.TUI.State` | the state struct, mounting, and session reset |
  | `Tackle.CLI.TUI.Viewport` | transcript/layout synchronization and scrolling |
  | `Tackle.CLI.TUI.RuntimeEvents` | projecting harness events into state |
  | `Tackle.CLI.TUI.Composer` | draft editing and submission |
  | `Tackle.CLI.TUI.Browser` | transcript focus, selection, and copy |
  | `Tackle.CLI.TUI.Menu` | model, reasoning, and settings pickers |
  | `Tackle.CLI.TUI.Search` | transcript search |
  | `Tackle.CLI.TUI.Inspector` | the scrollable tool-output inspector |
  | `Tackle.CLI.TUI.Session` | root scope ownership and teardown |
  | `Tackle.CLI.TUI.View` | the scene and ordinary widgets |
  | `Tackle.CLI.TUI.StatusView` | status row, metrics, and hints |
  """

  use ExRatatui.App

  alias ExRatatui.Command
  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.Subscription
  alias Tackle.CLI.Keybinds

  alias Tackle.CLI.TUI.{
    Browser,
    Compaction,
    Composer,
    Conversation,
    Inspector,
    Menu,
    RuntimeEvents,
    Search,
    Session,
    State,
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
    opts = Keyword.put_new(opts, :mouse_capture, true)
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
  def mount(opts), do: State.new(opts)

  @impl true
  def render(state, frame), do: View.scene(state, frame)

  @doc false
  @spec scene(State.t(), ExRatatui.Frame.t()) :: [{struct(), ExRatatui.Layout.Rect.t()}]
  def scene(state, frame), do: View.scene(state, frame)

  # -- input routing -------------------------------------------------------

  @impl true
  def handle_event(%Key{kind: "release"}, state), do: {:noreply, state, render?: false}

  def handle_event(%Key{} = key, state) do
    dispatch_key(key, %{state | notice: nil})
  end

  def handle_event(%Paste{content: content}, state), do: {:noreply, handle_paste(state, content)}

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

      nil ->
        if Conversation.contains?(state.conversation, mouse.x, mouse.y) do
          Viewport.scroll_reply(state, Viewport.scroll(state, delta))
        else
          {:noreply, state, render?: false}
        end

      _overlay ->
        {:noreply, state, render?: false}
    end
  end

  def handle_event(_event, state), do: {:noreply, state, render?: false}

  # -- runtime events ------------------------------------------------------

  @impl true
  def handle_info(message, state), do: RuntimeEvents.handle(message, state)

  @impl true
  def subscriptions(state) do
    if state.active_turn != nil or state.pending_operation != nil do
      [Subscription.interval(:tui_spinner, 80, {:tui_spinner_tick})]
    else
      []
    end
  end

  @impl true
  def terminate(_reason, state) do
    # The shell owns whichever scope it is currently attached to, which is the
    # initial scope until a new session replaces it. Stopping it here keeps a
    # swapped-in scope from outliving the shell.
    Session.retire(state)
    notify_owner(state)
    :ok
  end

  # -- key dispatch --------------------------------------------------------

  defp dispatch_key(%Key{kind: "repeat"} = key, state) do
    if Keybinds.repeatable?(key),
      do: dispatch(key, state),
      else: {:noreply, state, render?: false}
  end

  defp dispatch_key(key, state), do: dispatch(key, state)

  defp dispatch(key, state) do
    case Keybinds.global(key) do
      :quit -> quit(state)
      :unbound -> dispatch_overlay(key, state)
    end
  end

  defp dispatch_overlay(key, %{overlay: nil} = state),
    do: dispatch_base(Keybinds.base(key, state.focus), key, state)

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

  defp dispatch_overlay(key, %{overlay: {:picker, _}} = state),
    do: Menu.handle(Keybinds.picker(key), state)

  defp dispatch_overlay(key, %{overlay: {:inspector, _}} = state),
    do: Inspector.handle(Keybinds.inspector(key), state)

  defp dispatch_overlay(key, %{overlay: {:search, _}} = state),
    do: Search.handle(Keybinds.search(key), state)

  # Behaviour for each intent the binding table can return. Keeping one clause
  # per intent means an addition to `Keybinds` fails loudly here until it is
  # given behaviour, instead of silently doing nothing.
  defp dispatch_base(:model_picker, _key, state), do: Menu.open(:model, state)
  defp dispatch_base(:thinking_picker, _key, state), do: Menu.open(:thinking, state)
  defp dispatch_base(:settings_picker, _key, state), do: Menu.open(:settings, state)
  defp dispatch_base(:browse, _key, state), do: Browser.toggle_focus(state)
  defp dispatch_base(:escape, _key, state), do: escape(state)
  defp dispatch_base(:new_session, _key, state), do: Session.request_new(state)
  defp dispatch_base(:compact, _key, state), do: Compaction.request(state)
  defp dispatch_base(:search, _key, state), do: Search.open(state)
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
  defp dispatch_base(:submit, _key, state), do: Composer.submit(state)
  defp dispatch_base(:composer, key, state), do: Composer.key(state, key)

  defp dispatch_base({:transcript, intent}, _key, state),
    do: Browser.handle(intent, state)

  # -- paste ---------------------------------------------------------------

  defp handle_paste(%{overlay: {:search, _}} = state, content), do: Search.paste(state, content)
  defp handle_paste(%{overlay: {:picker, _}} = state, content), do: Menu.paste(state, content)

  # The transcript browser owns the keyboard, so a paste must not land in a
  # composer the user cannot see the cursor in.
  defp handle_paste(%{focus: :transcript} = state, content), do: Browser.paste(state, content)

  defp handle_paste(%{overlay: nil} = state, content), do: Composer.paste(state, content)

  defp handle_paste(state, _content), do: state

  # -- base actions --------------------------------------------------------

  defp escape(%{active_turn: nil, pending_operation: nil} = state) do
    {:noreply, %{state | notice: "Idle · Esc does not quit · Ctrl+C quits"}}
  end

  defp escape(%{pending_operation: %{kind: :submit} = operation} = state) do
    operation = Map.put(operation, :cancellation_requested?, true)

    {:noreply,
     %{state | pending_operation: operation, activity: "cancelling", notice: "Cancelling…"}}
  end

  defp escape(%{pending_operation: %{kind: :compact}} = state) do
    {:noreply, %{state | notice: "Manual compaction cannot be cancelled; draft kept"}}
  end

  defp escape(%{pending_operation: %{kind: :cancel}} = state) do
    {:noreply, %{state | notice: "Cancellation already requested"}}
  end

  defp escape(state) do
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
  defp resize_overlay(%{overlay: {:search, _search}} = state), do: Search.refresh(state)
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
        {:ok, pid} -> await_exit(pid, caller, caller_monitor, nil)
        {:error, reason} -> {:error, reason}
      end

    if result != :caller_down, do: send(caller, {result_ref, result})
  end

  defp await_exit(pid, caller, caller_monitor, reported_session_id) do
    receive do
      {:tui_exit, session_id} ->
        await_exit(pid, caller, caller_monitor, session_id)

      {:EXIT, ^pid, reason} when reason in [:normal, :shutdown] ->
        {:ok, reported_session_id}

      {:EXIT, ^pid, reason} ->
        {:error, reason}

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, :infinity)
        :caller_down
    end
  end
end
