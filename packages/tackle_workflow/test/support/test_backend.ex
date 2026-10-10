defmodule Tackle.Workflow.TestBackend do
  @moduledoc false

  # Minimal `Tackle.Runtime.AgentBackend` for workflow tests. Each agent session
  # is a GenServer that answers a submitted prompt from its configuration,
  # without a provider or a real `Tackle.Lib` loop.

  @behaviour Tackle.Runtime.AgentBackend

  alias Tackle.Lib.State
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Outcome

  @impl true
  def validate_spec(%AgentSpec{config: %{mode: mode}}) when is_atom(mode), do: :ok
  def validate_spec(%AgentSpec{config: config}), do: {:error, {:invalid_config, config}}

  @impl true
  def child_spec(%AgentSpec{config: config}, %AgentContext{} = context) do
    {Tackle.Workflow.TestAgent, {config, context}}
  end

  @impl true
  def call(pid, :submit, [input]), do: GenServer.call(pid, {:submit, input})
  def call(pid, :subscribe, []), do: GenServer.call(pid, :subscribe)
  def call(pid, :cancel, [reason]), do: GenServer.call(pid, {:cancel, reason})
  def call(_pid, operation, _args), do: {:error, {:unsupported_agent_operation, operation}}

  @impl true
  def select_model(%AgentSpec{config: config} = spec, "test/" <> _ = model),
    do: {:ok, %{spec | config: Map.put(config, :model, model)}}

  def select_model(_spec, model), do: {:error, {:unknown_model, model}}

  @impl true
  def model_ref(%AgentSpec{config: config}), do: Map.get(config, :model, "test/echo")

  @impl true
  def outcome({status, %State{} = state}, agent_ref) when status in [:ok, :error, :cancelled],
    do: Outcome.new(status, agent_state: state, agent_ref: agent_ref)

  def outcome(other, agent_ref),
    do:
      Outcome.new(:runtime_error,
        reason: {:unexpected_backend_result, other},
        agent_ref: agent_ref
      )
end

defmodule Tackle.Workflow.TestAgent do
  @moduledoc false

  # One fake agent session. Turn modes:
  #
  #   `:echo_prompt`  - settles with the submitted prompt as the answer.
  #   `:content`      - settles with the configured `:content` binary.
  #   `:manual`       - notifies the test and waits for `{:respond, content}`.
  #   `:block`        - notifies the test and waits for cancellation.
  #   `:error`        - settles with a library error outcome.
  #
  # A configured `:events` list is delivered to the subscriber before the turn
  # settles, the way a real session forwards its loop events. Terminal results
  # are reported to the delegated request helper through the runtime's
  # correlated terminal routing.

  use GenServer

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Runtime.AgentContext

  def start_link({config, context}) do
    GenServer.start_link(__MODULE__, {config, context})
  end

  @impl true
  def init({config, %AgentContext{} = context}) do
    Process.flag(:trap_exit, true)
    :ok = AgentContext.register(context)
    {:ok, %{config: config, context: context, turn: nil, turn_monitor: nil, subscriber: nil}}
  end

  @impl true
  def handle_call({:submit, input}, _from, %{turn: nil} = state) do
    agent = self()

    turn =
      spawn(fn ->
        result = run_turn(state.config, input)
        send(agent, {:turn_done, result})
      end)

    {:reply, {:ok, "turn"}, %{state | turn: turn, turn_monitor: Process.monitor(turn)}}
  end

  def handle_call({:submit, _input}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:subscribe, {pid, _tag}, state),
    do: {:reply, {:ok, :subscribed}, %{state | subscriber: pid}}

  def handle_call({:cancel, reason}, _from, state) do
    state = stop_turn(state, reason)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:turn_done, result}, state) do
    publish_events(state)
    state = report_terminal(state, result)
    {:noreply, %{state | turn: nil, turn_monitor: nil}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{turn_monitor: monitor} = state) do
    state = report_terminal(state, {:runtime_error, reason})
    {:noreply, %{state | turn: nil, turn_monitor: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if turn = state.turn, do: Process.exit(turn, :kill)
    :ok
  end

  defp run_turn(config, input) do
    case Map.get(config, :mode, :echo_prompt) do
      :echo_prompt ->
        {:ok, answer(input)}

      :content ->
        {:ok, answer(Map.fetch!(config, :content))}

      :manual ->
        notify(config, {:agent_called, self()})

        receive do
          {:respond, content} -> {:ok, answer(content)}
        after
          5_000 -> {:error, :manual_timeout}
        end

      :block ->
        notify(config, {:agent_called, self()})

        receive do
          {:respond, content} -> {:ok, answer(content)}
        after
          30_000 -> {:error, :block_timeout}
        end

      :error ->
        {:error, %State{error: "adapter_error"}}

      other ->
        {:runtime_error, {:unknown_mode, other}}
    end
  end

  # Events and the terminal result leave this process in order, as they do from
  # a real session, so the subscriber sees every event before the settlement.
  defp publish_events(%{subscriber: pid, config: config}) when is_pid(pid) do
    for event <- Map.get(config, :events, []) do
      send(pid, {:tackle_event, "test-session", "turn", event})
    end
  end

  defp publish_events(_state), do: :ok

  defp answer(content), do: %State{messages: [Message.assistant(content: content)]}

  defp notify(config, message) do
    if pid = Map.get(config, :test_pid), do: send(pid, message)
  end

  defp stop_turn(%{turn: nil} = state, _reason), do: state

  defp stop_turn(%{turn: turn, turn_monitor: monitor} = state, reason) do
    Process.exit(turn, :kill)
    Process.demonitor(monitor, [:flush])
    report_terminal(state, {:cancelled, reason})
    %{state | turn: nil, turn_monitor: nil}
  end

  defp report_terminal(state, result) do
    case state.context.terminal do
      %{destination: destination, run_id: run_id} ->
        send(destination, {:tackle_runtime_terminal, run_id, result})

      _other ->
        :ok
    end

    state
  end
end
