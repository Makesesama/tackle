defmodule Tackle.Runtime.AgentServicesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Tackle.Lib.Event
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Runtime.ServiceSupervisor

  defmodule Agent do
    @moduledoc false
    use GenServer

    def start_link({spec, context}), do: GenServer.start_link(__MODULE__, {spec, context})

    @impl true
    def init({spec, context}) do
      :ok = AgentContext.register(context)
      send(spec.config.test_pid, {:agent_started, context.kind, self(), context})
      {:ok, Map.put(spec.config, :context, context)}
    end

    @impl true
    def handle_call({:cancel_tool_call, args}, _from, state) do
      send(state.test_pid, {:cancel_tool_call, args})
      {:reply, :ok, state}
    end

    def handle_call({:publish_event, args}, _from, state) do
      send(state.test_pid, {:publish_event, args})
      {:reply, :ok, state}
    end

    def handle_call({:subscribe, []}, _from, state), do: {:reply, :ok, state}
    def handle_call({:submit, [_prompt]}, _from, state), do: {:reply, {:ok, "turn"}, state}

    def handle_call({:cancel, [reason]}, _from, %{context: %{terminal: terminal}} = state)
        when is_map(terminal) do
      outcome =
        Tackle.Runtime.Outcome.new(:cancelled,
          reason: reason,
          agent_state: Tackle.Lib.State.new()
        )

      send(terminal.destination, {:tackle_runtime_terminal, terminal.run_id, outcome})
      {:reply, :ok, state}
    end

    def handle_call({:cancel, [_reason]}, _from, state), do: {:reply, :ok, state}

    @impl true
    def handle_info({:runtime_cancel, _reason}, state), do: {:noreply, state}
  end

  defmodule Service do
    @moduledoc false
    use GenServer

    def start_link({test_pid, context}), do: GenServer.start_link(__MODULE__, {test_pid, context})

    @impl true
    def init({test_pid, %AgentContext{} = context}) do
      # The service task supervisor starts before every service.
      task_supervisor = GenServer.whereis(context.service_task_supervisor)
      send(test_pid, {:service_started, context.kind, self(), task_supervisor})
      {:ok, test_pid}
    end
  end

  defmodule RefusingService do
    @moduledoc false
    def child_spec(_arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
    def start_link, do: {:error, :refused}
  end

  defmodule Backend do
    @moduledoc false
    @behaviour Tackle.Runtime.AgentBackend

    @impl true
    def validate_spec(_spec), do: :ok

    @impl true
    def child_spec(spec, context), do: {Agent, {spec, context}}

    @impl true
    def call(pid, :cancel_tool_call, args), do: GenServer.call(pid, {:cancel_tool_call, args})

    def call(pid, :publish_event, args), do: GenServer.call(pid, {:publish_event, args})

    def call(pid, operation, args) when operation in [:subscribe, :submit, :cancel],
      do: GenServer.call(pid, {operation, args})

    def call(_pid, operation, _args), do: {:error, {:unsupported_agent_operation, operation}}

    @impl true
    def services(%AgentSpec{config: config}, context) do
      case config.services do
        :none -> []
        :raise -> raise "services exploded"
        :invalid -> :not_a_list
        :broken_first -> [RefusingService, nil, service(config, context)]
        :one -> [service(config, context)]
      end
    end

    defp service(config, context) do
      Supervisor.child_spec({Service, {config.test_pid, context}}, id: :test_service)
    end
  end

  defmodule PlainBackend do
    @moduledoc false
    @behaviour Tackle.Runtime.AgentBackend

    @impl true
    def validate_spec(_spec), do: :ok

    @impl true
    def child_spec(spec, context), do: {Agent, {spec, context}}

    @impl true
    def call(_pid, operation, _args), do: {:error, {:unsupported_agent_operation, operation}}
  end

  test "a crashing service is restarted while the agent keeps running" do
    scope = start_scope(:one)
    assert_receive {:agent_started, :root, agent, context}
    assert_receive {:service_started, :root, service, task_supervisor}
    assert is_pid(task_supervisor)
    assert context.service_task_supervisor == Registry.service_task_supervisor_name(scope.ref)
    assert {:ok, ^task_supervisor} = Registry.service_task_supervisor(scope.ref)

    Process.exit(service, :kill)

    assert_receive {:service_started, :root, restarted, ^task_supervisor}
    refute restarted == service
    assert Process.alive?(agent)
    assert {:ok, ^agent} = Runtime.session_pid(scope.ref)
  end

  test "exceeding the service restart bound drops services but keeps the agent" do
    scope = start_scope(:one)
    assert_receive {:agent_started, :root, agent, _context}
    assert_receive {:service_started, :root, service, _task_supervisor}

    service_supervisor = service_supervisor(scope.ref)
    monitor = Process.monitor(service_supervisor)

    # Three restarts are allowed within five seconds; the fourth crash exceeds the bound.
    last =
      Enum.reduce(1..3, service, fn _restart, pid ->
        Process.exit(pid, :kill)
        assert_receive {:service_started, :root, next, _task_supervisor}
        next
      end)

    Process.exit(last, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^service_supervisor, :shutdown}, 2_000
    assert Process.alive?(agent)
    assert {:ok, ^agent} = Runtime.session_pid(scope.ref)
    assert service_supervisor(scope.ref) == nil

    assert_eventually(fn ->
      Registry.service_task_supervisor(scope.ref) == {:error, :not_found}
    end)

    assert :ok = Runtime.cancel_tool_call(scope.ref, "call-1", :stuck)
  end

  test "stopping the scope terminates services and their task supervisor" do
    scope = start_scope(:one)
    assert_receive {:service_started, :root, service, task_supervisor}
    monitors = Enum.map([service, task_supervisor], &{Process.monitor(&1), &1})

    assert :ok = Runtime.stop_scope(scope.scope_ref)

    for {monitor, pid} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
    end
  end

  test "named services are discoverable by agent reference while they run" do
    agent_ref = %AgentRef{scope_id: "named-scope", agent_id: "named-agent"}
    assert Registry.service(agent_ref, :probe) == {:error, :not_found}

    {:ok, pid} =
      Elixir.Agent.start(fn -> :ok end, name: Registry.service_name(agent_ref, :probe))

    assert Registry.service(agent_ref, :probe) == {:ok, pid}
    assert Registry.service(agent_ref, :other) == {:error, :not_found}

    other_agent = %{agent_ref | agent_id: "other-agent"}
    assert Registry.service(other_agent, :probe) == {:error, :not_found}

    Elixir.Agent.stop(pid)
    assert Registry.service(agent_ref, :probe) == {:error, :not_found}
  end

  test "agents without services start no service supervisor" do
    for {backend, services} <- [{Backend, :none}, {PlainBackend, :one}] do
      scope = start_scope(services, backend)
      assert_receive {:agent_started, :root, _agent, context}
      assert context.service_task_supervisor == nil
      assert service_supervisor(scope.ref) == nil
      assert Registry.service_task_supervisor(scope.ref) == {:error, :not_found}
      assert length(Supervisor.which_children(agent_supervisor(scope.ref))) == 2
      refute_received {:service_started, _kind, _pid, _task_supervisor}
    end
  end

  test "failing services callbacks start the agent without services" do
    for {services, message} <- [{:raise, "services exploded"}, {:invalid, ":not_a_list"}] do
      log =
        capture_log(fn ->
          scope = start_scope(services)
          assert_receive {:agent_started, :root, _agent, context}
          assert context.service_task_supervisor == nil
          assert service_supervisor(scope.ref) == nil
        end)

      assert log =~ "failed to provide services"
      assert log =~ message
    end
  end

  test "a service that fails to start is skipped" do
    log =
      capture_log(fn ->
        scope = start_scope(:broken_first)
        assert_receive {:agent_started, :root, agent, _context}
        assert_receive {:service_started, :root, _service, _task_supervisor}
        assert is_pid(service_supervisor(scope.ref))
        assert Process.alive?(agent)
      end)

    assert log =~ "RefusingService"
    assert log =~ ":refused"
    assert log =~ "nil"
  end

  test "delegated child agents receive their own services" do
    child = AgentSpec.new!(name: "child", config: %{test_pid: self(), services: :one})
    scope = start_scope(:none, Backend, %{"child" => child})
    assert_receive {:agent_started, :root, _root, _context}

    assert {:ok, run_ref} = Runtime.request_agent(scope.ref, "child", "go")
    assert_receive {:agent_started, :child, child_agent, child_context}
    assert_receive {:service_started, :child, service, task_supervisor}
    assert {:ok, ^task_supervisor} = Registry.service_task_supervisor(child_context.agent_ref)
    monitors = Enum.map([service, task_supervisor, child_agent], &{Process.monitor(&1), &1})

    assert :ok = Runtime.cancel(run_ref)
    assert %{status: :cancelled} = Runtime.await(run_ref, 2_000)

    for {monitor, pid} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
    end
  end

  test "cancel_tool_call forwards to the agent backend" do
    scope = start_scope(:none)
    assert_receive {:agent_started, :root, _agent, _context}

    assert :ok = Runtime.cancel_tool_call(scope.ref, "call-1", {:watchdog, "stuck"})
    assert_receive {:cancel_tool_call, ["call-1", {:watchdog, "stuck"}]}

    assert {:error, {:invalid_tool_call_id, ""}} = Runtime.cancel_tool_call(scope.ref, "", :x)
    assert {:error, {:invalid_tool_call_id, nil}} = Runtime.cancel_tool_call(scope.ref, nil, :x)

    assert {:error, :not_found} =
             Runtime.cancel_tool_call(AgentRef.new!(scope.ref.scope_id, "missing"), "c", :x)
  end

  test "cancel_tool_call reports backends without per-call cancellation" do
    scope = start_scope(:none, PlainBackend)
    assert_receive {:agent_started, :root, _agent, _context}

    assert {:error, {:unsupported_agent_operation, :cancel_tool_call}} =
             Runtime.cancel_tool_call(scope.ref, "call-1", :stuck)
  end

  test "publish_event forwards auxiliary events to the agent backend" do
    scope = start_scope(:none)
    assert_receive {:agent_started, :root, _agent, _context}

    event = Event.new(:narration, %{run_id: "run-1", text: "reading", auxiliary: true})
    assert :ok = Runtime.publish_event(scope.ref, event)
    assert_receive {:publish_event, [^event]}

    assert {:error, :not_found} =
             Runtime.publish_event(AgentRef.new!(scope.ref.scope_id, "missing"), event)
  end

  test "publish_event refuses events that are not auxiliary" do
    scope = start_scope(:none)
    assert_receive {:agent_started, :root, _agent, _context}

    progress = Event.new(:narration, %{run_id: "run-1", text: "reading"})
    assert {:error, {:invalid_event, ^progress}} = Runtime.publish_event(scope.ref, progress)
    assert {:error, {:invalid_event, :nope}} = Runtime.publish_event(scope.ref, :nope)
    refute_receive {:publish_event, _args}, 50
  end

  test "publish_event reports backends without it" do
    scope = start_scope(:none, PlainBackend)
    assert_receive {:agent_started, :root, _agent, _context}

    event = Event.new(:narration, %{run_id: "run-1", text: "reading", auxiliary: true})

    assert {:error, {:unsupported_agent_operation, :publish_event}} =
             Runtime.publish_event(scope.ref, event)
  end

  defp start_scope(services, backend \\ Backend, profiles \\ %{}) do
    root =
      AgentSpec.new!(
        name: "root",
        config: %{test_pid: self(), services: services},
        allow_delegation: profiles != %{}
      )

    spec = ScopeSpec.new!(backend: backend, root_spec: root, profiles: profiles)
    {:ok, scope} = Runtime.start_scope(spec)
    on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)
    %{scope_ref: scope.scope_ref, ref: scope.root_agent_ref}
  end

  defp agent_supervisor(%AgentRef{} = agent_ref) do
    {:ok, scope} = Registry.scope(agent_ref)

    Enum.find_value(Supervisor.which_children(scope), fn
      {{:runtime_agent, id}, pid, :supervisor, _modules} when id == agent_ref.agent_id -> pid
      _child -> nil
    end)
  end

  defp service_supervisor(agent_ref) do
    agent_ref
    |> agent_supervisor()
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {ServiceSupervisor, pid, :supervisor, _modules} when is_pid(pid) -> pid
      _child -> nil
    end)
  end

  defp assert_eventually(fun, attempts \\ 200)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")
end
