defmodule Tackle.CLI.TUI.State do
  @moduledoc """
  The shell's complete presentation state.

  One struct carries everything the panes read and write: the agent handle and
  its monitor, the subscribed snapshot, the live turn, the composer, the
  overlay stack, the transcript model, and the usage/metrics projection. Every
  feature module takes and returns this struct, which keeps the state shape in
  one place instead of an anonymous map spread across the frontend.

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
  alias Tackle.CLI.TUI.Viewport
  alias Tackle.Lib.{ContextUsage, ModelInfo, Usage}
  alias Tackle.Lib.Message
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Runtime.Scope
  alias Tackle.Session.Snapshot

  @typedoc "An open surface above the composer, or `nil` when the shell is plain."
  @type overlay ::
          nil
          | {:picker, map()}
          | {:inspector, map()}
          | {:search, map()}
          | {:confirm_quit, map()}
          | {:confirm_new_session, map()}

  @typedoc "Which pane owns the keyboard."
  @type focus :: :composer | :transcript

  @type t :: %__MODULE__{
          agent_ref: Tackle.Runtime.AgentRef.t() | nil,
          agent_monitor: reference() | nil,
          scope_ref: term(),
          new_session: (map() -> {:ok, Scope.t()} | {:error, term()}) | nil,
          session_id: String.t() | nil,
          agent_state: AgentState.t() | nil,
          active_turn: map() | nil,
          input: reference(),
          models: [String.t()],
          clipboard_writer: (String.t() -> :ok | {:error, term()}),
          overlay: overlay(),
          focus: focus(),
          selected_entry: String.t() | nil,
          pending_prompt: String.t() | nil,
          streaming_thinking: String.t(),
          streaming_response: String.t(),
          latest_usage: Usage.t() | nil,
          live_usage: Usage.t() | nil,
          live_context_usage: ContextUsage.t() | nil,
          tool_activity: [map()],
          activity: String.t() | nil,
          error: String.t() | nil,
          outcome: :cancelled | :failed | nil,
          notice: String.t() | nil,
          thinking_expanded?: boolean(),
          draft_lines: pos_integer(),
          draft_empty?: boolean(),
          size: {pos_integer(), pos_integer()},
          conversation: Tackle.CLI.TUI.Conversation.t()
        }

  defstruct agent_ref: nil,
            agent_monitor: nil,
            scope_ref: nil,
            new_session: nil,
            session_id: nil,
            agent_state: nil,
            active_turn: nil,
            input: nil,
            models: [],
            clipboard_writer: &Clipboard.copy_local/1,
            overlay: nil,
            focus: :composer,
            selected_entry: nil,
            pending_prompt: nil,
            streaming_thinking: "",
            streaming_response: "",
            latest_usage: nil,
            live_usage: nil,
            live_context_usage: nil,
            tool_activity: [],
            activity: nil,
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
        session_id: snapshot.session_id,
        agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        input: ExRatatui.textarea_new(),
        models: available_models(opts, snapshot.agent_state),
        clipboard_writer: Keyword.get(opts, :clipboard_writer, &Clipboard.copy_local/1),
        size: {width, height},
        conversation: Viewport.new_conversation(width, height)
      }

      {:ok, Viewport.refresh(state)}
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
    :ok = ExRatatui.textarea_set_value(state.input, "")

    state = %{
      state
      | agent_ref: scope.root_agent_ref,
        agent_monitor: monitor,
        scope_ref: scope.scope_ref,
        session_id: snapshot.session_id,
        agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        pending_prompt: nil,
        streaming_thinking: "",
        streaming_response: "",
        latest_usage: latest_usage(snapshot.agent_state),
        live_usage: nil,
        live_context_usage: nil,
        tool_activity: [],
        activity: nil,
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
    Viewport.refresh(state)
  end

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
