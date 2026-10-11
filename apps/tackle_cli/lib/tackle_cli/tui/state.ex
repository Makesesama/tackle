defmodule Tackle.CLI.TUI.State do
  @moduledoc """
  The shell's complete presentation state.

  One struct carries everything the panes read and write: the agent handle and
  its monitor, the subscribed snapshot, the live turn, the composer, the prompt
  history, the overlay stack, the transcript model, and the usage/metrics
  projection. Every feature module takes and returns this struct, which keeps
  the state shape in one place instead of an anonymous map spread across the
  frontend. The turn-scoped groups travel as nested values: `State.Stream` holds
  the live streaming turn and `State.Metrics` holds the usage and context
  numbers, so each group is reset by one call when a turn settles.

  Besides presentation the struct carries the two things the shell owes its
  starter: the `new_session` factory that builds a replacement scope, and the
  `owner` process that learns which session the shell exited with.

  It also owns the two ways the state is created: `new/1` mounts a shell onto
  an existing root agent, and `reset/4` adopts a replacement scope behind a new
  session. Both subscribe before they build so a failed subscription leaves the
  caller's previous state untouched.

  The module additionally exposes the read-only views of the agent state that
  several panes need (`model_ref/1`, `model_info/1`, `latest_usage/1`, and
  `available_models/2`), so the model/usage knowledge lives next to the state
  it describes rather than being re-derived in each renderer.
  """

  alias Tackle.CLI.Clipboard

  alias Tackle.CLI.TUI.{
    Compaction,
    FileSearch,
    History,
    Preferences,
    SlashCommands,
    TurnTip,
    Viewport
  }

  alias Tackle.CLI.TUI.State.{Metrics, Stream}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.Message
  alias Tackle.Lib.{ModelInfo, Usage}
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Runtime.Scope
  alias Tackle.Session.{Snapshot, UsageTimeline}

  @typedoc "An open surface above the composer, or `nil` when the shell is plain."
  @type overlay ::
          nil
          | {:help, map()}
          | {:picker, map()}
          | {:resume, map()}
          | {:tree, map()}
          | {:file_search, FileSearch.popup()}
          | {:slash_commands, SlashCommands.popup()}
          | {:inspector, map()}
          | {:subagent_view, Tackle.CLI.TUI.SubagentView.t()}
          | {:search, map()}
          | {:usage_chart, map()}
          | {:confirm_quit, map()}
          | {:confirm_new_session, map()}

  @typedoc "Which pane owns the keyboard."
  @type focus :: :composer | :transcript | :subagents

  @type t :: %__MODULE__{
          agent_ref: Tackle.Runtime.AgentRef.t() | nil,
          agent_monitor: reference() | nil,
          scope_ref: term(),
          new_session: (map() -> {:ok, Scope.t()} | {:error, term()}) | nil,
          list_recent_sessions:
            (cursor :: term() ->
               {:ok, %{sessions: [map()], next_cursor: term() | nil}} | {:error, term()})
            | nil,
          resume_session: (String.t() -> {:ok, Scope.t()} | {:error, term()}) | nil,
          inspect_session: (String.t() -> {:ok, map()} | {:error, term()}) | nil,
          recent_sessions: [map()],
          recent_sessions_ref: reference() | nil,
          owner: pid() | nil,
          session_id: String.t() | nil,
          session_title: String.t() | nil,
          agent_state: AgentState.t() | nil,
          active_turn: map() | nil,
          input: reference(),
          history: History.t(),
          models: [String.t()],
          clipboard_writer: (String.t() -> Tackle.CLI.Clipboard.copy_result()),
          terminal_title_writer: (String.t() | nil ->
                                    {:ok, Tackle.CLI.TerminalTitle.set_result()}
                                    | :ok
                                    | {:error, term()}),
          terminal_title: String.t() | nil,
          herdr: Tackle.CLI.TUI.Herdr.t() | nil,
          notification_writer: (String.t() -> Tackle.CLI.Notifications.notify_result()),
          terminal_focused?: boolean(),
          clipboard_text_reader: (-> {:ok, binary()} | {:error, term()}),
          clipboard_image_reader: (-> {:ok, binary()} | {:error, term()}),
          external_editor: Tackle.CLI.TUI.ExternalEditor.editor(),
          full_repaint?: boolean(),
          image_paths: [String.t()],
          pastes: %{optional(non_neg_integer()) => Tackle.CLI.TUI.Pastes.Paste.t()},
          next_paste_id: pos_integer(),
          executor: Tackle.Executor.t(),
          usage_timeline_loader: (:current | :all, String.t() | nil ->
                                    {:ok, term()} | {:error, term()}),
          usage_timeline_cache: map(),
          overlay: overlay(),
          focus: focus(),
          file_search: FileSearch.t(),
          slash_commands: SlashCommands.t(),
          subagent_selected: String.t() | nil,
          show_subagent_sidebar?: boolean(),
          prose_width: pos_integer() | nil,
          selected_entry: String.t() | nil,
          browse_page:
            :transcript | :overview | :subagents | :prompt | :context | :tools | :events,
          browse_content: map() | nil,
          pending_prompt: String.t() | nil,
          queued_prompts: [String.t()],
          queued_drafts: %{optional(String.t()) => Tackle.CLI.TUI.Pastes.Draft.t()},
          stream: Stream.t(),
          pending_operation: map() | nil,
          deferred_events: [term()],
          spinner_frame: non_neg_integer(),
          turn_tip: TurnTip.t(),
          metrics: Metrics.t(),
          observations: Tackle.CLI.TUI.Observations.t(),
          tool_activity: [map()],
          subagents: %{optional(String.t()) => map()},
          storage: :ready | :delayed,
          activity: String.t() | nil,
          compactions: [map()],
          error: String.t() | nil,
          outcome: :cancelled | :failed | nil,
          notice: String.t() | nil,
          queue_notice_at: integer() | nil,
          thinking_expanded?: boolean(),
          draft_lines: pos_integer(),
          draft_empty?: boolean(),
          size: {pos_integer(), pos_integer()},
          header_image: ExRatatui.Widgets.Image.t() | nil,
          conversation: Tackle.CLI.TUI.Conversation.t()
        }

  # The shell deliberately keeps all presentation state in one struct so every
  # feature module passes the same shape; the extra field only changes the VM's
  # internal map representation, which is acceptable for this frontend.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct agent_ref: nil,
            agent_monitor: nil,
            scope_ref: nil,
            new_session: nil,
            list_recent_sessions: nil,
            resume_session: nil,
            inspect_session: nil,
            recent_sessions: [],
            recent_sessions_ref: nil,
            owner: nil,
            session_id: nil,
            session_title: nil,
            agent_state: nil,
            active_turn: nil,
            input: nil,
            history: %History{},
            models: [],
            clipboard_writer: &Clipboard.copy/1,
            terminal_title_writer: &Tackle.CLI.TerminalTitle.write/1,
            terminal_title: nil,
            herdr: nil,
            notification_writer: &Tackle.CLI.Notifications.write/1,
            terminal_focused?: true,
            clipboard_text_reader: &Tackle.CLI.ImageClipboard.read_text/0,
            clipboard_image_reader: &Tackle.CLI.ImageClipboard.read/0,
            external_editor: &Tackle.CLI.TUI.ExternalEditor.edit/1,
            # Set while the terminal has just been handed back by an external
            # editor: the next frame is drawn blank so the one after repaints
            # every cell.
            full_repaint?: false,
            image_paths: [],
            # Retained paste payloads, by the id the composer's label carries.
            # They outlive the draft that introduced them: undo can resurrect a
            # deleted label, and a transcript preview needs every content the
            # session ever collapsed.
            pastes: %{},
            next_paste_id: 1,
            executor: Tackle.Executor.local(),
            usage_timeline_loader: &__MODULE__.default_usage_timeline_loader/2,
            usage_timeline_cache: %{},
            overlay: nil,
            focus: :composer,
            file_search: %FileSearch{},
            slash_commands: %SlashCommands{},
            subagent_selected: nil,
            show_subagent_sidebar?: true,
            prose_width: nil,
            selected_entry: nil,
            browse_page: :transcript,
            browse_content: nil,
            pending_prompt: nil,
            queued_prompts: [],
            # The draft behind each queued prompt, so taking one back restores
            # the labels the user wrote instead of the expanded text.
            queued_drafts: %{},
            stream: %Stream{},
            pending_operation: nil,
            deferred_events: [],
            spinner_frame: 0,
            turn_tip: %TurnTip{},
            metrics: %Metrics{},
            observations: %Tackle.CLI.TUI.Observations{},
            tool_activity: [],
            subagents: %{},
            storage: :ready,
            activity: nil,
            compactions: [],
            error: nil,
            outcome: nil,
            notice: nil,
            queue_notice_at: nil,
            thinking_expanded?: false,
            draft_lines: 1,
            draft_empty?: true,
            size: {80, 24},
            header_image: nil,
            conversation: nil

  @doc """
  Subscribes to the root agent and builds the initial shell state.

  Returns `{:error, :missing_agent_ref}` when the caller did not provide an
  agent to attach to, or the subscribe/monitor failure otherwise.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, agent_ref} <- Keyword.fetch(opts, :agent_ref),
         {:ok, sidebar?} <- sidebar_preference(opts),
         {:ok, %Snapshot{} = snapshot} <- Tackle.subscribe(agent_ref),
         {:ok, agent_monitor} <- Tackle.monitor_agent(agent_ref) do
      {width, height} = initial_terminal_size(opts)

      state = %__MODULE__{
        agent_ref: agent_ref,
        agent_monitor: agent_monitor,
        scope_ref: snapshot.scope_ref,
        new_session: Keyword.get(opts, :new_session),
        list_recent_sessions: Keyword.get(opts, :list_recent_sessions),
        resume_session: Keyword.get(opts, :resume_session),
        inspect_session: Keyword.get(opts, :inspect_session),
        owner: Keyword.get(opts, :owner),
        session_id: snapshot.session_id,
        session_title: snapshot.session_title,
        storage: snapshot.storage,
        agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        input: Input.new(),
        history: History.new(),
        models: available_models(opts, snapshot.agent_state),
        clipboard_writer: Keyword.get(opts, :clipboard_writer, &Clipboard.copy/1),
        terminal_title_writer: terminal_title_writer(opts),
        terminal_title: nil,
        notification_writer: notification_writer(opts),
        terminal_focused?: true,
        clipboard_text_reader:
          Keyword.get(opts, :clipboard_text_reader, &Tackle.CLI.ImageClipboard.read_text/0),
        clipboard_image_reader:
          Keyword.get(opts, :clipboard_image_reader, &Tackle.CLI.ImageClipboard.read/0),
        external_editor: external_editor(opts),
        executor:
          Keyword.get_lazy(opts, :executor, fn ->
            Tackle.CLI.Jail.executor() || Tackle.Executor.local()
          end),
        usage_timeline_loader:
          Keyword.get(opts, :usage_timeline_loader, &__MODULE__.default_usage_timeline_loader/2),
        stream: %Stream{coalesce?: is_nil(Keyword.get(opts, :test_mode))},
        show_subagent_sidebar?: sidebar?,
        size: {width, height},
        header_image: Keyword.get(opts, :header_image),
        conversation: Viewport.new_conversation(width, height)
      }

      {:ok, state |> Compaction.restore() |> Viewport.refresh()}
    else
      :error -> {:error, :missing_agent_ref}
      {:error, reason} -> {:error, reason}
    end
  end

  # Test terminals have no window title, and the default writer would emit
  # OSC title bytes into the test terminal's output; a no-op writer keeps the
  # refresh path exercised without touching the real terminal.
  defp terminal_title_writer(opts) do
    case Keyword.fetch(opts, :terminal_title_writer) do
      {:ok, writer} ->
        writer

      :error ->
        if Keyword.has_key?(opts, :test_mode) do
          fn
            nil -> :ok
            _title -> {:ok, :applied}
          end
        else
          &Tackle.CLI.TerminalTitle.write/1
        end
    end
  end

  # Test terminals have no desktop notifications, and the default writer would
  # emit OSC 9 or BEL bytes into the test terminal's output; a no-op writer
  # keeps the completion path exercised without touching the real terminal.
  defp notification_writer(opts) do
    case Keyword.fetch(opts, :notification_writer) do
      {:ok, writer} ->
        writer

      :error ->
        if Keyword.has_key?(opts, :test_mode) do
          fn _message -> {:ok, :applied} end
        else
          &Tackle.CLI.Notifications.write/1
        end
    end
  end

  # Test terminals are not the process's terminal, and the default editor would
  # take over whichever terminal runs the tests; without an injected editor,
  # a test shell behaves as though none were configured.
  defp external_editor(opts) do
    case Keyword.fetch(opts, :external_editor) do
      {:ok, editor} ->
        editor

      :error ->
        if Keyword.has_key?(opts, :test_mode) do
          fn _text -> {:error, :no_editor} end
        else
          modes = Keyword.take(opts, [:mouse_capture, :focus_events])
          &Tackle.CLI.TUI.ExternalEditor.edit(&1, modes)
        end
    end
  end

  defp sidebar_preference(opts) do
    case Keyword.fetch(opts, :show_subagent_sidebar?) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_option, :show_subagent_sidebar?, value}}
      :error -> Preferences.sidebar()
    end
  end

  @doc """
  Adopts `scope` as the shell's session.

  Clears the composer and every turn-scoped projection, drops the reading
  position, and rebuilds the transcript from the replacement snapshot. The
  caller is responsible for retiring the previous scope, which happens after
  this state is ready so a failed adoption does not disturb the old session.
  """
  @spec reset(t(), Scope.t(), Snapshot.t(), reference()) :: t()
  def reset(%__MODULE__{} = state, %Scope{} = scope, %Snapshot{} = snapshot, monitor) do
    :ok = Input.set_value(state.input, "")

    state = %{
      state
      | agent_ref: scope.root_agent_ref,
        agent_monitor: monitor,
        scope_ref: scope.scope_ref,
        session_id: snapshot.session_id,
        session_title: snapshot.session_title,
        storage: snapshot.storage,
        agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        history: History.leave_browsing(state.history),
        pending_prompt: nil,
        queued_prompts: [],
        queued_drafts: %{},
        stream: Stream.reset(state.stream),
        pending_operation: nil,
        deferred_events: [],
        spinner_frame: 0,
        turn_tip: TurnTip.dismiss(state.turn_tip),
        metrics: %Metrics{latest_usage: latest_usage(snapshot.agent_state)},
        observations: %Tackle.CLI.TUI.Observations{},
        tool_activity: [],
        subagents: %{},
        activity: nil,
        compactions: [],
        error: nil,
        outcome: nil,
        notice: "New session",
        queue_notice_at: nil,
        thinking_expanded?: false,
        draft_lines: 1,
        draft_empty?: true,
        overlay: nil,
        focus: :composer,
        file_search: %FileSearch{},
        slash_commands: %SlashCommands{},
        subagent_selected: nil,
        selected_entry: nil,
        browse_page: :transcript,
        browse_content: nil,
        recent_sessions: [],
        recent_sessions_ref: nil
    }

    {width, height} = state.size
    state = %{state | conversation: Viewport.new_conversation(width, height)}
    state |> Compaction.restore() |> Viewport.refresh()
  end

  @doc false
  @spec default_usage_timeline_loader(atom(), String.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def default_usage_timeline_loader(:current, session_id) when is_binary(session_id),
    do: Tackle.session_usage_timeline(session_id)

  def default_usage_timeline_loader(:current, session_id),
    do: {:error, {:invalid_session_id, session_id}}

  def default_usage_timeline_loader(:all, _session_id),
    do: Tackle.all_usage_timeline(since: UsageTimeline.calendar_week_start())

  @doc "Returns the selected model reference, or nil when the state names none."
  @spec model_ref(AgentState.t() | nil) :: String.t() | nil
  def model_ref(%AgentState{llm: %{ref: ref}}) when is_binary(ref), do: ref
  def model_ref(%AgentState{model: model}) when is_binary(model), do: model
  def model_ref(_agent_state), do: nil

  @doc "Returns the selected model's metadata, or nil when it is unavailable."
  @spec model_info(AgentState.t() | nil) :: ModelInfo.t() | nil
  def model_info(%AgentState{llm: %{model_info: %ModelInfo{} = info}}), do: info
  def model_info(%AgentState{}), do: nil

  @doc "Returns the most recent assistant usage in the agent state, normalized."
  @spec latest_usage(AgentState.t() | nil) :: Usage.t() | nil
  def latest_usage(%AgentState{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, token_usage: usage} when not is_nil(usage) ->
        Usage.normalize(usage)

      _message ->
        nil
    end)
  end

  def latest_usage(_agent_state), do: nil

  @doc """
  Returns the raw Markdown of the most recent final answer in the agent state.

  A final answer is an assistant message with content and no tool calls (see
  `Tackle.Lib.Message.final_answer?/1`), so narration that preceded tool calls
  is skipped. Returns `nil` when the conversation has no final answer yet.
  """
  @spec latest_final_answer(AgentState.t() | nil) :: String.t() | nil
  def latest_final_answer(%AgentState{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      if Message.final_answer?(message), do: message.content
    end)
  end

  def latest_final_answer(_agent_state), do: nil

  @doc """
  Returns the model references the menus may offer.

  The selected model is always present, so a frontend that was given no model
  list still shows one honest entry instead of an empty menu.
  """
  @spec available_models(keyword(), AgentState.t()) :: [String.t()]
  def available_models(opts, agent_state) do
    current = model_ref(agent_state)

    models =
      opts
      |> Keyword.get(:models, [])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    cond do
      is_binary(current) and current not in models -> [current | models]
      models == [] -> [current || "configured default"]
      true -> models
    end
  end

  defp initial_terminal_size(opts) do
    case Keyword.get(opts, :test_mode) do
      {width, height} ->
        {width, height}

      nil ->
        configured_terminal_size(opts)
    end
  end

  defp configured_terminal_size(opts) do
    width = Keyword.get(opts, :width)
    height = Keyword.get(opts, :height)

    if is_integer(width) and is_integer(height) do
      {width, height}
    else
      detect_terminal_size()
    end
  end

  defp detect_terminal_size do
    case ExRatatui.terminal_size() do
      {width, height} when is_integer(width) and is_integer(height) -> {width, height}
      {:error, _reason} -> {80, 24}
    end
  end
end
