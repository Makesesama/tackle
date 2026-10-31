defmodule Tackle.Runtime.LoopAgent do
  @moduledoc """
  A ready-made `Tackle.Runtime.AgentBackend` that runs the `Tackle.Lib` loop.

  Use it as a scope's backend with a `Tackle.Runtime.LoopAgent.Config` in
  each `Tackle.Runtime.AgentSpec`:

      {:ok, config} =
        Tackle.Runtime.LoopAgent.Config.new(
          providers: providers,
          model: "provider/model",
          tools: tools,
          system_prompt: "You review code."
        )

      scope_spec =
        Tackle.Runtime.ScopeSpec.new!(
          backend: Tackle.Runtime.LoopAgent,
          root_spec: Tackle.Runtime.AgentSpec.new!(name: "root", config: config)
        )

  Each agent keeps its conversation in memory and runs one turn at a time in
  a linked task, with the agent's tool supervisor. It starts empty, or from a
  saved conversation (`:session_id` with `:messages` or `:tree` in the
  configuration) after a restart. It persists nothing and
  enforces no policy: a host gates turns before it submits them, and puts
  persistence or billing in `Tackle.Lib.Hook`s (`:hooks` in the
  configuration), for example `after_message/3` for messages and
  `after_turn/2` for settlement. Hosts that need more, such as an inbox or
  durable sessions, implement their own backend.

  ## Operations

    * `:submit` and `:continue` start a turn and return `{:ok, turn_id}`, or
      `{:error, :turn_in_progress}` while one runs.
    * `:cancel` requests cooperative cancellation of the active turn; the
      runtime also uses it for cancelled branches and requests.
    * `:cancel_tool_call` cancels one tool call of the active turn
      (`{:error, :no_active_turn}` when idle).
    * `:subscribe` returns `{:ok, snapshot}` and delivers every event as
      `{:tackle_event, session_id, turn_id, event}` until `:unsubscribe` or
      the subscriber exits; `:publish_event` sends an auxiliary event to the
      subscribers, with `turn_id` `nil`.
    * `:snapshot` returns `%{agent_state: state, active_turn: turn_id | nil}`.
      During a turn, the state's transcript already holds the messages the
      turn has settled (each `:message_end`), so a view that joins mid-turn
      starts from what the earlier subscribers have seen.
    * `:reconfigure` changes an idle agent's `:model` or `:thinking`.

  Other operations, including `:deliver`, return
  `{:error, {:unsupported_agent_operation, operation}}`.

  ## Turn ends

  The loop ends every turn it completes with a `:turn_end` event, and the
  agent then takes the state the turn returned. When the turn task itself
  crashes, the agent keeps the messages the turn settled before the crash
  (the ones its subscribers and `after_message/3` hooks have seen), publishes
  `:turn_end` with status `:error`, and reports a `:runtime_error` outcome to
  a delegated request. A tool call the crash left unanswered is repaired when
  the next turn starts. Stopping the agent cancels
  its turn and kills the task after a short grace period, even when the
  adapter ignores cancellation.
  """

  @behaviour Tackle.Runtime.AgentBackend
  use GenServer, restart: :temporary

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Thinking
  alias Tackle.Lib.Tree
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.LoopAgent.Config
  alias Tackle.Runtime.Outcome

  @termination_grace_period 1_000

  ## Spec callbacks

  @impl Tackle.Runtime.AgentBackend
  def validate_spec(%AgentSpec{config: %Config{} = config}), do: Config.validate(config)
  def validate_spec(%AgentSpec{config: config}), do: {:error, {:invalid_agent_config, config}}

  @impl Tackle.Runtime.AgentBackend
  def child_spec(%AgentSpec{} = spec, %AgentContext{} = context),
    do: {__MODULE__, {spec, context}}

  # A `model_source: :parent` child runs on its parent's current model and
  # thinking level.
  @impl Tackle.Runtime.AgentBackend
  def prepare_child(%AgentSpec{model_source: :parent} = spec, parent) do
    %{agent_state: %State{llm: llm, llm_opts: llm_opts}} = call(parent, :snapshot, [])
    configure(spec, model: llm.ref, thinking: Thinking.from_llm_opts(llm_opts))
  end

  def prepare_child(%AgentSpec{} = spec, _parent), do: {:ok, spec}

  @impl Tackle.Runtime.AgentBackend
  def select_model(%AgentSpec{} = spec, model), do: configure(spec, model: model)

  @impl Tackle.Runtime.AgentBackend
  def model_ref(%AgentSpec{config: %Config{model_ref: ref}}), do: ref

  @impl Tackle.Runtime.AgentBackend
  def configure(%AgentSpec{config: %Config{} = config} = spec, opts) do
    with {:ok, config} <- Config.update(config, opts), do: {:ok, %{spec | config: config}}
  end

  def configure(%AgentSpec{config: config}, _opts), do: {:error, {:invalid_agent_config, config}}

  @impl Tackle.Runtime.AgentBackend
  def describe(%AgentSpec{config: %Config{} = config}) do
    %{
      model: config.model_ref,
      thinking: Thinking.from_llm_opts(config.llm_opts),
      max_steps: config.max_steps,
      system_prompt: config.system_prompt,
      tools: Enum.map(config.tools, & &1.name())
    }
  end

  @impl Tackle.Runtime.AgentBackend
  def llm(%AgentSpec{config: %Config{llm: llm} = config}),
    do: {:ok, %{llm: llm, llm_opts: Config.llm_opts(config)}}

  @impl Tackle.Runtime.AgentBackend
  def outcome(%Outcome{} = outcome, _agent_ref), do: outcome

  def outcome({status, %State{} = state}, agent_ref) when status in [:ok, :error, :cancelled],
    do: Outcome.new(status, agent_state: state, agent_ref: agent_ref)

  def outcome(other, agent_ref) do
    Outcome.new(:runtime_error,
      reason: {:unexpected_backend_result, other},
      agent_ref: agent_ref
    )
  end

  @impl Tackle.Runtime.AgentBackend
  def call(pid, operation, args), do: GenServer.call(pid, {operation, args}, :infinity)

  ## Agent process

  @doc false
  def start_link({spec, context}), do: GenServer.start_link(__MODULE__, {spec, context})

  @impl GenServer
  def init({%AgentSpec{config: %Config{} = config}, %AgentContext{} = context}) do
    # Trapping exits lets `terminate/2` stop the turn when the scope stops.
    Process.flag(:trap_exit, true)
    :ok = AgentContext.register(context)

    {:ok,
     %{
       config: config,
       context: context,
       agent_state: new_state(config, context),
       subscribers: %{},
       turn: nil
     }}
  end

  defp new_state(config, context) do
    Tackle.Lib.new(
      session_id: config.session_id,
      tree: config.tree,
      llm: config.llm,
      tools: config.tools,
      hooks: config.hooks,
      system_prompt: config.system_prompt,
      context: Map.put(config.context, :runtime, context.agent_ref),
      max_iterations: config.max_steps || :infinity,
      llm_opts: Config.llm_opts(config)
    )
  end

  @impl GenServer
  def handle_call({:subscribe, []}, {pid, _tag}, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, {:ok, snapshot(state)}, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, []}, {pid, _tag}, state) do
    {monitor, subscribers} = Map.pop(state.subscribers, pid)
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:snapshot, []}, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({operation, _args}, _from, %{turn: turn} = state)
      when operation in [:submit, :continue, :reconfigure] and turn != nil,
      do: {:reply, {:error, :turn_in_progress}, state}

  def handle_call({:submit, [input]}, _from, state) when is_binary(input),
    do: start_turn(state, &Tackle.Lib.run(&1, input, &2))

  def handle_call({:submit, [input]}, _from, state),
    do: {:reply, {:error, {:invalid_input, input}}, state}

  def handle_call({:continue, []}, _from, state),
    do: start_turn(state, &Tackle.Lib.continue(&1, &2))

  def handle_call({:reconfigure, [opts]}, _from, state) when is_list(opts) do
    case Config.update(state.config, Keyword.take(opts, [:model, :thinking])) do
      {:ok, config} ->
        agent_state = %{state.agent_state | llm: config.llm, llm_opts: Config.llm_opts(config)}
        state = %{state | config: config, agent_state: agent_state}
        {:reply, {:ok, snapshot(state)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, [reason]}, _from, state), do: {:reply, :ok, cancel(state, reason)}

  def handle_call({:cancel_tool_call, [_call_id, _reason]}, _from, %{turn: nil} = state),
    do: {:reply, {:error, :no_active_turn}, state}

  def handle_call({:cancel_tool_call, [call_id, reason]}, _from, state) do
    state.turn.signal |> Cancellation.for_call(call_id) |> Cancellation.cancel(reason)
    {:reply, :ok, state}
  end

  def handle_call({:publish_event, [%Event{} = event]}, _from, state) do
    if Event.auxiliary?(event) do
      publish(state, nil, event)
      {:reply, :ok, state}
    else
      {:reply, {:error, {:invalid_event, event}}, state}
    end
  end

  def handle_call({operation, _args}, _from, state),
    do: {:reply, {:error, {:unsupported_agent_operation, operation}}, state}

  @impl GenServer
  def handle_info({:turn_event, turn_id, %Event{} = event}, %{turn: %{id: turn_id}} = state) do
    state = record_settled_message(state, event)
    publish(state, turn_id, event)
    {:noreply, state}
  end

  # A late event of a turn that has already settled.
  def handle_info({:turn_event, _turn_id, %Event{}}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{turn: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, settle(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{turn: %{task: %Task{ref: ref}}} = state
      ),
      do: {:noreply, crash(state, reason)}

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    subscribers =
      if Map.get(state.subscribers, pid) == monitor,
        do: Map.delete(state.subscribers, pid),
        else: state.subscribers

    {:noreply, %{state | subscribers: subscribers}}
  end

  # The turn task's exit signal; its result or `:DOWN` settles the turn.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{turn: nil}), do: :ok

  def terminate(_reason, %{turn: turn}) do
    Cancellation.cancel(turn.signal, :agent_stopped)

    case Task.yield(turn.task, @termination_grace_period) do
      nil -> Task.shutdown(turn.task, :brutal_kill)
      _settled -> :ok
    end

    Cancellation.delete(turn.signal)
    :ok
  end

  defp start_turn(state, run) do
    server = self()
    turn_id = ID.generate()
    signal = Cancellation.new_signal()

    opts = [
      event_callback: &send(server, {:turn_event, turn_id, &1}),
      cancellation_signal: signal,
      tool_supervisor: state.context.tool_supervisor,
      llm_stream: true
    ]

    agent_state = state.agent_state
    task = Task.async(fn -> run.(agent_state, opts) end)
    {:reply, {:ok, turn_id}, %{state | turn: %{id: turn_id, task: task, signal: signal}}}
  end

  defp settle(state, {status, %State{} = agent_state} = result)
       when status in [:ok, :error, :cancelled] do
    finish(%{state | agent_state: agent_state}, result)
  end

  defp settle(state, other), do: crash(state, {:unexpected_turn_result, other})

  # The messages the turn settled stay; the views learn that the turn is over
  # from `:turn_end`.
  defp crash(state, reason) do
    publish(state, state.turn.id, Event.turn_end(state.agent_state.session_id, :error))
    outcome = Outcome.new(:runtime_error, reason: reason, agent_ref: state.context.agent_ref)
    finish(state, outcome)
  end

  defp finish(%{turn: turn} = state, result) do
    Cancellation.delete(turn.signal)

    # A delegated run reports its outcome; a root agent has nobody to tell.
    if terminal = state.context.terminal do
      send(terminal.destination, {:tackle_runtime_terminal, terminal.run_id, result})
    end

    %{state | turn: nil}
  end

  # The snapshot follows the turn's settled messages; the turn's own result
  # replaces it when the turn ends.
  defp record_settled_message(state, %Event{type: :message_end, data: %{message: message}})
       when is_struct(message, Message) do
    agent_state = state.agent_state

    if Tree.contains?(agent_state.tree, message.id),
      do: state,
      else: %{state | agent_state: State.add_message(agent_state, message)}
  end

  defp record_settled_message(state, %Event{}), do: state

  defp cancel(%{turn: nil} = state, _reason), do: state

  defp cancel(%{turn: turn} = state, reason) do
    Cancellation.cancel(turn.signal, reason)
    state
  end

  defp publish(state, turn_id, %Event{} = event) do
    message = {:tackle_event, state.agent_state.session_id, turn_id, event}
    Enum.each(state.subscribers, fn {pid, _monitor} -> send(pid, message) end)
  end

  defp snapshot(state) do
    %{agent_state: state.agent_state, active_turn: state.turn && state.turn.id}
  end
end
