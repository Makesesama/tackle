defmodule Tackle.Session.Durable do
  @moduledoc """
  The journal side of a `Tackle.Session`.

  A session owns at most one `Tackle.Session.Journal`. Everything it writes
  there, and the state it rebuilds from it, goes through this module, so the
  session itself only decides when to write. A session without a journal (a
  delegated agent, or a root scope started without a `Tackle.Session.Spec`)
  passes `nil`: opening builds a fresh state, the gates are absent, and
  beginning or settling a turn writes nothing.

  Apart from `open/3`, which runs while the session starts, the writes run in
  the session's storage tasks and in its turn's task (the persistence hook),
  not in the session process, so they never block its admission and control
  calls.
  """

  alias Tackle.Auth
  alias Tackle.Config
  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Lib.Tree
  alias Tackle.Runtime.AgentRef
  alias Tackle.Session.Committer
  alias Tackle.Session.Journal
  alias Tackle.Session.Journal.Deadline
  alias Tackle.Session.Loader
  alias Tackle.Session.Persistence
  alias Tackle.Session.Projection
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Session.Turn

  @typedoc "The session's journal, or `nil` for a session without one."
  @type journal :: pid() | nil

  @typedoc """
  An interrupted turn that awaits the frontend's decision, with the session's
  tool executions that have no durable result
  (`Tackle.Session.Projection.uncertain_tools/1`).
  """
  @type recovery :: %{
          required(:turn_id) => String.t(),
          required(:operation) => term(),
          required(:uncertain_tools) => [Projection.pending_tool()]
        }

  @typedoc """
  What a session starts from: its configuration (carrying the credential
  store), its state, its journal, an interrupted turn, whether it may branch,
  its recorded title, and its storage status.
  """
  @type opened :: %{
          config: Config.t(),
          agent_state: AgentState.t(),
          journal: journal(),
          recovery: recovery() | nil,
          tree_enabled?: boolean(),
          title: String.t() | nil,
          storage: :ready | :delayed
        }

  @typedoc "How a turn ended, as the session settles it."
  @type turn_result ::
          {:ok, AgentState.t()}
          | {:error, AgentState.t()}
          | {:cancelled, AgentState.t()}
          | {:runtime_error, term()}

  @doc """
  Opens the session for `agent_ref`, durable when a spec is given.

  Without a spec the state is built from `config`. With one, the session's
  journal is looked up and its projection read once: the configuration is
  resolved against the recorded one (and a change recorded), branching is
  enabled when the spec asks for it, and the state is restored with the
  persistence hook and committer installed. An interrupted turn is returned
  as the recovery the frontend must decide; otherwise tool calls a settled
  turn left without results are repaired first. The calling process, the
  session, is subscribed to the journal's storage status.

  The credential store is put into the configuration's LLM options here,
  once: the agent state, a later reconfiguration, and title generation all
  take it from there.
  """
  @spec open(Config.t(), AgentRef.t(), SessionSpec.t() | nil) ::
          {:ok, opened()} | {:error, term()}
  def open(%Config{} = config, %AgentRef{} = agent_ref, nil) do
    config = put_credential_store(config)

    {:ok,
     %{
       config: config,
       agent_state: config |> Config.to_agent_state() |> put_runtime_context(agent_ref),
       journal: nil,
       recovery: nil,
       tree_enabled?: false,
       title: nil,
       storage: :ready
     }}
  end

  def open(%Config{} = config, %AgentRef{} = agent_ref, %SessionSpec{} = spec) do
    with {:ok, journal} <- Journal.whereis(spec.session_id),
         {:ok, opened} <-
           restore(journal, put_credential_store(config), agent_ref,
             override_config: spec.override_config,
             tree: spec.tree
           ) do
      {:ok, %{opened | storage: Deadline.subscribe(journal, self())}}
    end
  end

  @doc """
  Rebuilds the state from the journal after a turn that could not finish
  (its start failed or its task crashed) was settled, or one that failed
  because the journal refused one of its messages
  (`{:message_not_journaled, reason}`, see `Tackle.Session.Persistence`).

  The turn's messages are journaled (by the persistence hook, or with the
  inbox) while the session still holds the pre-turn state, or the turn's
  state holds a message the journal refused. Rebuilding it the way `open/3`
  does makes memory and journal agree again: the next message links to the
  journaled tip instead of starting a branch, and calls the crash left without
  results are repaired. The session's configuration is authoritative, so it
  overrides the recorded one.
  """
  @spec reopen(pid(), Config.t(), AgentRef.t(), boolean()) ::
          {:ok, AgentState.t()} | {:error, term()}
  def reopen(journal, %Config{} = config, %AgentRef{} = agent_ref, tree_enabled?) do
    with {:ok, opened} <-
           restore(journal, config, agent_ref, override_config: true, tree: tree_enabled?) do
      {:ok, opened.agent_state}
    end
  end

  @doc """
  Records a turn's start, then the inbox messages it took.

  Returns `{:inbox_failed, reason, journaled}` when an inbox message cannot
  be appended after `turn.started` was, with the number of messages that
  were, so the session can settle the started turn.
  """
  @spec begin_turn(journal(), Turn.t(), String.t() | nil, AgentState.t(), [Message.t()]) ::
          :ok | {:inbox_failed, term(), non_neg_integer()} | {:error, term()}
  def begin_turn(nil, _turn, _input, _agent_state, _messages), do: :ok

  def begin_turn(journal, %Turn{} = turn, input, %AgentState{} = agent_state, messages) do
    with {:ok, _turn_id} <- Journal.begin_turn(journal, turn.operation, input, turn.id) do
      append_inbox_messages(journal, agent_state, messages)
    end
  end

  @doc "Settles a turn with its terminal event (write-behind)."
  @spec settle_turn(journal(), String.t(), turn_result()) :: :ok | {:error, term()}
  def settle_turn(nil, _turn_id, _result), do: :ok

  def settle_turn(journal, turn_id, result) do
    {type, data} = terminal_event(result)
    Journal.settle_turn(journal, type, Map.put(data, "turn_id", turn_id))
  end

  @doc """
  Abandons the interrupted turn `recovery` names, then repairs the tool calls
  it left without results.
  """
  @spec abandon_turn(pid(), recovery(), AgentState.t(), Config.t()) ::
          {:ok, AgentState.t()} | {:error, term()}
  def abandon_turn(journal, recovery, %AgentState{} = agent_state, %Config{} = config) do
    with :ok <-
           Journal.settle_turn(journal, "turn.abandoned", %{
             "turn_id" => recovery.turn_id,
             "reason" => "abandoned_by_frontend"
           }) do
      repair_interrupted_tool_results(journal, agent_state, config, nil)
    end
  end

  @doc "Records an accepted configuration change."
  @spec configure(pid(), Config.t()) :: :ok | {:error, term()}
  def configure(journal, %Config{} = config), do: Journal.configuration_changed(journal, config)

  @doc """
  Appends one message `agent_state` settled, write-behind, with its tree
  parent: the parent of its tree entry, or none when the tree does not hold
  it (the journal decides whether to record the link, see
  `Tackle.Session.Journal.append_message/4`). The persistence hook, the
  inbox, and the repair of interrupted tool calls all append through here.
  """
  @spec append_message(pid(), AgentState.t(), Message.t()) :: :ok | {:error, term()}
  def append_message(journal, %AgentState{tree: tree}, %Message{} = message) do
    parent =
      case Tree.entry(tree, message.id) do
        %{parent_id: parent_id} -> {:tree, parent_id}
        nil -> :none
      end

    Journal.append_message(journal, message, parent, sync: false)
  end

  @doc """
  The loop's `:before_provider_call` gate, or `nil` without a journal.

  Messages are appended write-behind. A provider call needs no durable record
  first (a crash only means calling again), but it must not run ahead of a
  stalled or failed journal, so it waits behind earlier requests without
  syncing.
  """
  @spec provider_gate(journal()) :: (-> :ok | {:error, term()}) | nil
  def provider_gate(nil), do: nil
  def provider_gate(journal), do: fn -> Journal.await_idle(journal) end

  @doc """
  The loop's `:before_tool_execution` gate, or `nil` without a journal.

  Tool intent (and everything before it) must be durable before a tool with
  external effects runs, so recovery can report it as uncertain after a
  crash. The loop skips this gate for read-only tools.
  """
  @spec tool_gate(journal()) :: (-> :ok | {:error, term()}) | nil
  def tool_gate(nil), do: nil
  def tool_gate(journal), do: fn -> Journal.await_durable(journal) end

  defp restore(journal, config, agent_ref, opts) do
    with {:ok, projection} <- Journal.projection(journal),
         {:ok, loaded} <-
           Loader.load(projection, config, override_config: opts[:override_config]),
         :ok <- record_configuration(journal, loaded),
         :ok <- enable_tree(journal, projection, opts[:tree]) do
      recovery = recovery(projection)

      agent_state =
        loaded.state
        |> put_runtime_context(agent_ref)
        |> install_persistence_hook()
        |> install_committer()

      with {:ok, agent_state} <-
             repair_interrupted_tool_results(journal, agent_state, loaded.config, recovery) do
        {:ok,
         %{
           config: loaded.config,
           agent_state: agent_state,
           journal: journal,
           recovery: recovery,
           tree_enabled?: opts[:tree] or projection.tree_enabled?,
           title: projection.title,
           storage: :ready
         }}
      end
    end
  end

  defp put_credential_store(%Config{} = config),
    do: %{
      config
      | llm_opts: Keyword.put(config.llm_opts, :credential_store, Auth.credential_store())
    }

  # Tools find the agent they act for under `:runtime` (`AgentRef.from_context/1`);
  # the scope coordinator owns what that agent may do.
  defp put_runtime_context(agent_state, %AgentRef{} = agent_ref),
    do: %{agent_state | context: Map.put(agent_state.context, :runtime, agent_ref)}

  defp record_configuration(_journal, %{configuration_changed?: false}), do: :ok
  defp record_configuration(journal, %{config: config}), do: configure(journal, config)

  # A legacy linear journal is never rewritten; enabling branching appends one
  # explicit versioned transition before any tree-specific write.
  defp enable_tree(_journal, _projection, false), do: :ok
  defp enable_tree(_journal, %Projection{tree_enabled?: true}, true), do: :ok
  defp enable_tree(journal, _projection, true), do: Journal.enable_tree(journal)

  # The hook is added directly rather than through Config; Tackle.Lib.Hook
  # loads hook modules itself when it validates or invokes them. It finds the
  # journal by session id and the session through the `:runtime` reference,
  # so nothing of the session reaches the context tools see.
  defp install_persistence_hook(%AgentState{} = state),
    do: %{state | hooks: Enum.concat(state.hooks, [Persistence])}

  # Durable sessions commit compactions and navigations through the journal
  # before the library installs them in memory.
  defp install_committer(%AgentState{} = state), do: %{state | committer: Committer}

  defp recovery(%Projection{active_turn: nil}), do: nil

  defp recovery(%Projection{active_turn: %{} = turn} = projection) do
    %{
      turn_id: turn.turn_id,
      operation: turn.operation,
      uncertain_tools: Projection.uncertain_tools(projection)
    }
  end

  # Runs after `turn.started`, so a failure reports how many messages were
  # journaled for the session to settle the started turn.
  defp append_inbox_messages(journal, agent_state, messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {message, index}, :ok ->
      case append_message(journal, agent_state, message) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:inbox_failed, reason, index}}
      end
    end)
  end

  # A settled turn can still leave assistant tool calls without results — a
  # turn cancelled or crashed mid-batch, or a journal written before the loop
  # settled interrupted batches — which providers reject. The loop settles such
  # calls itself when the next turn starts, but resume repairs them first: the
  # snapshot and transcript a frontend shows, manual compaction, and tree
  # navigation (which only accepts positions whose calls all have results) see
  # the history before any turn runs, and a resumed session need not run one.
  # Their outcome is unknown, since the tool may have run, which the results
  # say. The repair is committed through a dedicated repair turn so it is
  # durable. A turn that still requires an explicit recovery decision is left
  # untouched; `Tackle.Session.abandon_turn/1` settles those.
  defp repair_interrupted_tool_results(_journal, agent_state, _config, recovery)
       when not is_nil(recovery),
       do: {:ok, agent_state}

  defp repair_interrupted_tool_results(journal, %AgentState{} = agent_state, config, nil) do
    case Messages.unresolved_tool_calls(agent_state.messages) do
      [] ->
        {:ok, agent_state}

      _calls ->
        turn_id = config.id_generator.()

        with {:ok, _turn_id} <- Journal.begin_turn(journal, :repair, nil, turn_id),
             {:ok, agent_state} <- settle_unresolved_tool_results(journal, agent_state),
             :ok <-
               Journal.settle_turn(journal, "turn.abandoned", %{
                 "turn_id" => turn_id,
                 "reason" => "interrupted_tools_repaired"
               }) do
          {:ok, agent_state}
        end
    end
  end

  # Appends one synthetic result per unresolved tool call, journaled with the
  # same parent linkage as any other tool result, so it survives the next
  # resume.
  defp settle_unresolved_tool_results(journal, %AgentState{} = agent_state) do
    agent_state.messages
    |> Messages.interrupted_results(:unknown, id_generator: agent_state.id_generator)
    |> Enum.reduce_while({:ok, agent_state}, fn message, {:ok, acc} ->
      acc = AgentState.add_message(acc, message)

      case append_message(journal, acc, message) do
        :ok -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp terminal_event({:ok, _agent_state}), do: {"turn.completed", %{"status" => "completed"}}

  defp terminal_event({:error, %AgentState{} = agent_state}),
    do: {"turn.errored", %{"error" => agent_state.error}}

  defp terminal_event({:cancelled, %AgentState{} = agent_state}),
    do: {"turn.cancelled", %{"reason" => agent_state.error}}

  defp terminal_event({:runtime_error, reason}),
    do: {"turn.crashed", %{"reason" => inspect(reason)}}
end
