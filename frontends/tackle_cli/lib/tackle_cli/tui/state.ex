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
  alias Tackle.CLI.TUI.{Compaction, History, Viewport}
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
          | {:picker, map()}
          | {:tree, map()}
          | {:inspector, map()}
          | {:search, map()}
          | {:usage_chart, map()}
          | {:confirm_quit, map()}
          | {:confirm_new_session, map()}

  @typedoc "Which pane owns the keyboard."
  @type focus :: :composer | :transcript

  @type t :: %__MODULE__{
          agent_ref: Tackle.Runtime.AgentRef.t() | nil,
          agent_monitor: reference() | nil,
          scope_ref: term(),
          new_session: (map() -> {:ok, Scope.t()} | {:error, term()}) | nil,
          owner: pid() | nil,
          session_id: String.t() | nil,
          agent_state: AgentState.t() | nil,
          active_turn: map() | nil,
          input: reference(),
          history: History.t(),
          models: [String.t()],
          clipboard_writer: (String.t() -> :ok | {:error, term()}),
          usage_timeline_loader: (:current | :all, String.t() | nil ->
                                    {:ok, term()} | {:error, term()}),
          usage_timeline_cache: map(),
          overlay: overlay(),
          focus: focus(),
          selected_entry: String.t() | nil,
          pending_prompt: String.t() | nil,
          stream: Stream.t(),
          pending_operation: map() | nil,
          deferred_events: [term()],
          spinner_frame: non_neg_integer(),
          metrics: Metrics.t(),
          tool_activity: [map()],
          activity: String.t() | nil,
          compactions: [map()],
          error: String.t() | nil,
          outcome: :cancelled | :failed | nil,
          notice: String.t() | nil,
          thinking_expanded?: boolean(),
          draft_lines: pos_integer(),
          draft_empty?: boolean(),
          size: {pos_integer(), pos_integer()},
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
            owner: nil,
            session_id: nil,
            agent_state: nil,
            active_turn: nil,
            input: nil,
            history: %History{},
            models: [],
            clipboard_writer: &Clipboard.copy_local/1,
            usage_timeline_loader: &__MODULE__.default_usage_timeline_loader/2,
            usage_timeline_cache: %{},
            overlay: nil,
            focus: :composer,
            selected_entry: nil,
            pending_prompt: nil,
            stream: %Stream{},
            pending_operation: nil,
            deferred_events: [],
            spinner_frame: 0,
            metrics: %Metrics{},
            tool_activity: [],
            activity: nil,
            compactions: [],
            error: nil,
            outcome: nil,
            notice: nil,
            thinking_expanded?: false,
            draft_lines: 1,
            draft_empty?: true,
            size: {80, 24},
            conversation: nil

  @doc """
  Subscribes to the root agent and builds the initial shell state.

  Returns `{:error, :missing_agent_ref}` when the caller did not provide an
  agent to attach to, or the subscribe/monitor failure otherwise.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, agent_ref} <- Keyword.fetch(opts, :agent_ref),
         {:ok, %Snapshot{} = snapshot} <- Tackle.subscribe(agent_ref),
         {:ok, agent_monitor} <- Tackle.monitor_agent(agent_ref) do
      {width, height} = initial_terminal_size(opts)

      state = %__MODULE__{
        agent_ref: agent_ref,
        agent_monitor: agent_monitor,
        scope_ref: snapshot.scope_ref,
        new_session: Keyword.get(opts, :new_session),
        owner: Keyword.get(opts, :owner),
        session_id: snapshot.session_id,
        agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        input: Input.new(),
        history: History.new(),
        models: available_models(opts, snapshot.agent_state),
        clipboard_writer: Keyword.get(opts, :clipboard_writer, &Clipboard.copy_local/1),
        usage_timeline_loader:
          Keyword.get(opts, :usage_timeline_loader, &__MODULE__.default_usage_timeline_loader/2),
        stream: %Stream{coalesce?: is_nil(Keyword.get(opts, :test_mode))},
        size: {width, height},
        conversation: Viewport.new_conversation(width, height)
      }

      {:ok, state |> Compaction.restore() |> Viewport.refresh()}
    else
      :error -> {:error, :missing_agent_ref}
      {:error, reason} -> {:error, reason}
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
        agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        history: History.leave_browsing(state.history),
        pending_prompt: nil,
        stream: Stream.reset(state.stream),
        pending_operation: nil,
        deferred_events: [],
        spinner_frame: 0,
        metrics: %Metrics{latest_usage: latest_usage(snapshot.agent_state)},
        tool_activity: [],
        activity: nil,
        compactions: [],
        error: nil,
        outcome: nil,
        notice: "New session",
        thinking_expanded?: false,
        draft_lines: 1,
        draft_empty?: true,
        overlay: nil,
        focus: :composer,
        selected_entry: nil
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
