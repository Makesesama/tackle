defmodule Tackle.Runtime.Bench.Backend do
  @moduledoc false
  use GenServer
  @behaviour Tackle.Runtime.AgentBackend

  alias Tackle.Runtime.{AgentContext, AgentSpec, Outcome}

  @impl true
  def validate_spec(%AgentSpec{config: %{}}), do: :ok

  @impl true
  def child_spec(spec, context), do: {__MODULE__, {spec, context}}

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def call(pid, operation, args), do: GenServer.call(pid, {operation, args})

  @impl true
  def init({spec, context}) do
    :ok = AgentContext.register(context)
    {:ok, %{config: spec.config, context: context, subscriber: nil}}
  end

  @impl true
  def handle_call({:subscribe, []}, {caller, _tag}, state) do
    {:reply, :ok, %{state | subscriber: caller}}
  end

  def handle_call({:submit, [_prompt]}, _from, state) do
    send(self(), :finish)
    {:reply, {:ok, "bench-turn"}, state}
  end

  # Keep the backend alive until Request terminates its supervised subtree.
  def handle_call({:cancel, [_reason]}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(:finish, %{context: %{terminal: terminal}} = state) do
    emit(state.subscriber, Map.get(state.config, :events, 0))

    outcome =
      Outcome.new(:ok,
        agent_state: state.config.agent_state,
        agent_ref: state.context.agent_ref,
        run_id: terminal.run_id
      )

    send(terminal.destination, {:tackle_runtime_terminal, terminal.run_id, outcome})
    {:noreply, state}
  end

  def handle_info({:runtime_cancel, _reason}, state), do: {:noreply, state}

  defp emit(nil, _count), do: :ok
  defp emit(_subscriber, 0), do: :ok

  defp emit(subscriber, count) do
    event = Tackle.Lib.Event.new(:message_delta, %{delta: "synthetic chunk"})
    send(subscriber, {:tackle_runtime_event, event})
    emit(subscriber, count - 1)
  end
end

defmodule Tackle.Runtime.Bench.Workflow do
  @moduledoc false
  use Tackle.Runtime.Workflow

  @impl true
  def init(_input), do: {:ok, nil, [{"worker", "synthetic prompt"}]}

  @impl true
  def handle_result(_ref, outcome, state), do: {:stop, {:ok, outcome}, state}
end

defmodule Tackle.Runtime.Bench do
  @moduledoc false
  alias Tackle.Lib.{Message, State}
  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentSpec, Outcome, ScopeSpec}
  alias Tackle.Runtime.Bench.{Backend, Workflow}

  def input(count, events \\ 0) do
    messages =
      for index <- 1..count do
        %Message{
          id: "message-#{index}",
          role: if(rem(index, 2) == 1, do: :user, else: :assistant),
          content: "synthetic message #{index}",
          timestamp: ~U[2026-01-01 00:00:00Z]
        }
      end

    state = %{
      State.new(session_id: "bench", retry: false)
      | messages: messages,
        status: :completed
    }

    %{agent_state: state, events: events}
  end

  def setup(config) do
    root = AgentSpec.new!(name: "root", config: %{}, allow_delegation: true)
    worker = AgentSpec.new!(name: "worker", config: config)
    spec = ScopeSpec.new!(backend: Backend, root_spec: root, profiles: %{"worker" => worker})
    {:ok, scope} = Runtime.start_scope(spec)
    scope
  end

  def teardown(scope), do: Runtime.stop_scope(scope.scope_ref)

  def with_scope(config, fun) do
    scope = setup(config)

    try do
      fun.(scope)
    after
      :ok = teardown(scope)
    end
  end

  def launch_await(scope, opts \\ []) do
    {:ok, run} = Runtime.request_agent(scope.root_agent_ref, "worker", "synthetic prompt", opts)
    {:ok, pid} = Tackle.Runtime.Registry.whereis(run)
    monitor = Process.monitor(pid)
    %Outcome{status: :ok} = Runtime.await(run, 5_000)
    await_down(monitor)
    scope
  end

  def workflow(scope) do
    {:ok, ref} = Runtime.start_workflow(scope.root_agent_ref, Workflow, nil)
    {:ok, pid} = Tackle.Runtime.Registry.whereis(ref)
    monitor = Process.monitor(pid)
    {:ok, %Outcome{status: :ok}} = Runtime.await_workflow(ref, 5_000)
    {scope, monitor}
  catch
    kind, reason ->
      teardown(scope)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  def finish_workflow({scope, monitor}) do
    try do
      await_down(monitor)
    after
      :ok = teardown(scope)
    end
  end

  def collect(scope, run, pid) do
    monitor = Process.monitor(pid)
    %Outcome{status: :ok} = Runtime.collect(scope.root_agent_ref, run)
    await_down(monitor)
  end

  defp await_down(monitor) do
    receive do
      {:DOWN, ^monitor, :process, _pid, :normal} -> :ok
    after
      5_000 -> raise "benchmark process did not shut down normally"
    end
  end

  def retained(scope) do
    {:ok, run} =
      Runtime.request_agent(scope.root_agent_ref, "worker", "synthetic prompt",
        retention: :until_collected,
        owner: :parent
      )

    {:ok, pid} = Tackle.Runtime.Registry.whereis(run)
    wait_completed(pid, System.monotonic_time(:millisecond) + 5_000)
    {run, pid}
  end

  # Polling is only used by the untimed retained-memory diagnostic.
  defp wait_completed(pid, deadline) do
    if :sys.get_state(pid, 5_000).outcome do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline, do: raise("run did not settle")
      Process.sleep(1)
      wait_completed(pid, deadline)
    end
  end
end
