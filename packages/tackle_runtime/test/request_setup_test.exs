defmodule Tackle.Runtime.RequestSetupTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Event
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Messaging
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.Request
  alias Tackle.Runtime.ScopeSpec

  defmodule Backend do
    @behaviour Tackle.Runtime.AgentBackend
    use GenServer

    @impl true
    def validate_spec(_spec), do: :ok

    @impl true
    def child_spec(spec, context), do: {__MODULE__, {spec, context}}

    @impl true
    def model_ref(%AgentSpec{config: %{mode: :model_raise}}), do: raise("model lookup failed")
    def model_ref(_spec), do: "test-model"

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    @impl true
    def init({spec, context}) do
      if context.kind == :child, do: send(spec.config.test_pid, {:child_started, self()})

      if spec.config.mode != :unregistered do
        :ok = AgentContext.register(context)
      end

      {:ok, Map.merge(spec.config, %{context: context, subscriber: nil})}
    end

    @impl true
    def call(pid, operation, args) do
      case GenServer.call(pid, {operation, args}) do
        :raise_backend -> raise "backend crashed"
        :exit_backend -> exit(:backend_exited)
        result -> result
      end
    end

    @impl true
    def handle_call({:subscribe, []}, {subscriber, _tag}, state) do
      result =
        case state.mode do
          :subscription_error -> {:error, :subscription_denied}
          :subscription_raise -> :raise_backend
          _other -> {:ok, %{}}
        end

      {:reply, result, %{state | subscriber: subscriber}}
    end

    def handle_call({:progress, [event]}, _from, state) do
      send(state.subscriber, {:tackle_runtime_event, event})
      {:reply, :ok, state}
    end

    def handle_call({:finish, []}, _from, state) do
      %{destination: destination, run_id: run_id} = state.context.terminal

      send(
        destination,
        {:tackle_runtime_terminal, run_id,
         Tackle.Runtime.Outcome.new(:ok, agent_state: Tackle.Lib.State.new())}
      )

      {:reply, :ok, state}
    end

    def handle_call({:submit, [_prompt]}, _from, state) do
      result =
        case state.mode do
          :submission_error -> {:error, :submission_denied}
          :submission_exit -> :exit_backend
          _other -> {:ok, "turn"}
        end

      {:reply, result, state}
    end

    def handle_call({:cancel, [_reason]}, _from, state), do: {:reply, :ok, state}

    def handle_call({:deliver, [_envelope]}, _from, state) do
      result = if state.mode == :delivery_raise, do: :raise_backend, else: :ok
      {:reply, result, state}
    end

    @impl true
    def handle_info({:runtime_cancel, _reason}, state), do: {:noreply, state}
  end

  for {mode, reason} <- [
        {:unregistered, :agent_not_registered},
        {:subscription_error, {:event_subscription_failed, :subscription_denied}},
        {:submission_error, :submission_denied},
        {:subscription_raise,
         {:event_subscription_failed, {:agent_backend_failed, "backend crashed"}}},
        {:submission_exit, {:agent_unavailable, :backend_exited}}
      ] do
    test "setup failure #{mode} releases the reservation and terminates the child" do
      child = AgentSpec.new!(name: "child", config: %{mode: unquote(mode), test_pid: self()})

      root =
        AgentSpec.new!(
          name: "root",
          config: %{mode: :root, test_pid: self()},
          allow_delegation: true
        )

      scope_spec =
        ScopeSpec.new!(backend: Backend, root_spec: root, profiles: %{"child" => child})

      {:ok, scope} = Runtime.start_scope(scope_spec)
      on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)

      assert {:ok, run_ref} = Runtime.request_agent(scope.root_agent_ref, "child", "go")

      assert_receive {:child_started, child_pid}, 2_000
      monitor = Process.monitor(child_pid)

      assert %{status: :runtime_error, reason: {:setup_failed, unquote(Macro.escape(reason))}} =
               Runtime.await(run_ref, 5_000)

      assert_receive {:DOWN, ^monitor, :process, ^child_pid, _reason}, 2_000

      assert_eventually(fn ->
        {:ok, snapshot} = Runtime.scope_snapshot(scope.scope_ref)
        snapshot.agent_count == 1
      end)
    end
  end

  test "a cancelled await timer cannot time out a later waiter" do
    root =
      AgentSpec.new!(
        name: "root",
        config: %{mode: :root, test_pid: self()},
        allow_delegation: true
      )

    child = AgentSpec.new!(name: "child", config: %{mode: :normal, test_pid: self()})
    scope_spec = ScopeSpec.new!(backend: Backend, root_spec: root, profiles: %{"child" => child})

    {:ok, scope} = Runtime.start_scope(scope_spec)
    on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)

    assert {:ok, run_ref} =
             Runtime.request_agent(scope.root_agent_ref, "child", "go", timeout: :infinity)

    assert_receive {:child_started, _pid}, 2_000
    {:ok, request} = Registry.whereis(run_ref)

    first_waiter = spawn(fn -> Runtime.await(run_ref, 60_000) end)

    assert_eventually(fn -> map_size(:sys.get_state(request).awaiters) == 1 end)
    first_timer = :sys.get_state(request).await_timer
    assert is_reference(first_timer)

    Process.exit(first_waiter, :kill)
    assert_eventually(fn -> :sys.get_state(request).await_timer == nil end)

    # A timer that already entered the mailbox cannot be recalled by cancel_timer.
    send(request, {:timeout, first_timer, {:request_timeout, :await}})
    assert {:ok, :running} = Request.status(run_ref)

    second_waiter = Task.async(fn -> Runtime.await(run_ref, 60_000) end)
    assert_eventually(fn -> map_size(:sys.get_state(request).awaiters) == 1 end)
    second_timer = :sys.get_state(request).await_timer
    assert is_reference(second_timer)
    refute second_timer == first_timer

    send(request, {:timeout, first_timer, {:request_timeout, :await}})
    assert {:ok, :running} = Request.status(run_ref)

    send(request, {:timeout, second_timer, {:request_timeout, :await}})
    assert %{status: :timeout} = Task.await(second_waiter, 2_000)
  end

  for retention <- [:linger, :until_collected] do
    test "progress renews the idle window for #{retention} requests without a callback" do
      {scope, run_ref, child, request} = start_idle_request(unquote(retention), 200)

      # Keep working for longer than the entire original timeout window.
      for type <- [:step_start, :message_delta, :tool_start, :tool_progress, :tool_execution_end] do
        previous_timer = :sys.get_state(request).idle_timer
        Process.sleep(60)
        :ok = Backend.call(child, :progress, [Event.new(type, %{})])
        assert_eventually(fn -> :sys.get_state(request).idle_timer != previous_timer end)
        assert {:ok, :running} = Request.status(run_ref)
      end

      :ok = Backend.call(child, :finish, [])
      assert %{status: :ok} = Runtime.await(run_ref)
      assert :ok = Runtime.stop_scope(scope.scope_ref)
    end
  end

  test "a stalled request times out after its renewed idle window" do
    {_scope, run_ref, child, request} = start_idle_request(:until_collected, 200)
    original_timer = :sys.get_state(request).idle_timer
    Process.sleep(100)
    :ok = Backend.call(child, :progress, [Event.new(:step_start, %{})])
    assert_eventually(fn -> :sys.get_state(request).idle_timer != original_timer end)

    Process.sleep(120)
    assert {:ok, :running} = Request.status(run_ref)
    assert %{status: :timeout, reason: :run_timeout} = Runtime.await(run_ref)
    monitor = Process.monitor(child)
    assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 2_000
  end

  test "auxiliary events are forwarded but do not renew the idle window" do
    test_pid = self()
    callback = fn event -> send(test_pid, {:forwarded, event.type, event.data}) end
    {_scope, run_ref, child, request} = start_idle_request(:until_collected, 200, callback)
    original_timer = :sys.get_state(request).idle_timer

    for message <- [
          {:progress, Event.new(:status_change, %{auxiliary: true, notice: "watching"})},
          {:raw,
           {:tackle_event, "session", "turn", Event.new(:status_change, %{auxiliary: true})}}
        ] do
      Process.sleep(60)

      case message do
        {:progress, event} -> :ok = Backend.call(child, :progress, [event])
        {:raw, raw} -> send(request, raw)
      end

      assert_receive {:forwarded, :status_change, %{auxiliary: true}}
      assert :sys.get_state(request).idle_timer == original_timer
    end

    assert %{status: :timeout, reason: :run_timeout} = Runtime.await(run_ref, 2_000)
  end

  test "stale idle timers and late progress cannot change a settled outcome" do
    {_scope, run_ref, child, request} = start_idle_request(:until_collected, 60_000)
    first_timer = :sys.get_state(request).idle_timer
    :ok = Backend.call(child, :progress, [Event.new(:step_start, %{})])
    assert_eventually(fn -> :sys.get_state(request).idle_timer != first_timer end)
    current_timer = :sys.get_state(request).idle_timer

    send(request, {:timeout, first_timer, {:request_timeout, :idle}})
    assert {:ok, :running} = Request.status(run_ref)

    send(request, {:tackle_event, "session", "turn", Event.new(:tool_execution_end, %{})})
    assert {:ok, :running} = Request.status(run_ref)
    refute :sys.get_state(request).idle_timer == current_timer

    :ok = Backend.call(child, :finish, [])
    assert_eventually(fn -> :sys.get_state(request).outcome != nil end)
    send(request, {:timeout, current_timer, {:request_timeout, :idle}})
    send(request, {:tackle_runtime_event, Event.new(:message_delta, %{})})
    assert {:ok, {:completed, %{status: :ok}}} = Request.status(run_ref)
    assert :sys.get_state(request).idle_timer == nil
    assert %{status: :ok} = Request.collect(run_ref)
  end

  defp start_idle_request(retention, timeout, event_callback \\ nil) do
    root =
      AgentSpec.new!(
        name: "root",
        config: %{mode: :root, test_pid: self()},
        allow_delegation: true
      )

    child =
      AgentSpec.new!(name: "child", config: %{mode: :normal, test_pid: self()}, timeout: timeout)

    scope_spec = ScopeSpec.new!(backend: Backend, root_spec: root, profiles: %{"child" => child})
    {:ok, scope} = Runtime.start_scope(scope_spec)
    on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)

    {:ok, run_ref} =
      Runtime.request_agent(scope.root_agent_ref, "child", "go",
        retention: retention,
        event_callback: event_callback
      )

    assert_receive {:child_started, child}, 2_000
    {:ok, request} = Registry.whereis(run_ref)
    assert is_reference(:sys.get_state(request).idle_timer)
    {scope, run_ref, child, request}
  end

  test "request preparation failures do not reserve a child slot" do
    root =
      AgentSpec.new!(
        name: "root",
        config: %{mode: :root, test_pid: self()},
        allow_delegation: true
      )

    child = AgentSpec.new!(name: "child", config: %{mode: :normal, test_pid: self()})
    broken = AgentSpec.new!(name: "broken", config: %{mode: :model_raise, test_pid: self()})

    scope_spec =
      ScopeSpec.new!(
        backend: Backend,
        root_spec: root,
        profiles: %{"child" => child, "broken" => broken},
        limits: Limits.new!(max_agents_per_fleet: 2)
      )

    {:ok, scope} = Runtime.start_scope(scope_spec)
    on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)

    for {profile, opts, exception, message} <- [
          {"broken", [], RuntimeError, "model lookup failed"},
          {"child", [owner: :invalid], ArgumentError, "invalid request owner: :invalid"}
        ] do
      assert_raise exception, message, fn ->
        Runtime.request_agent(scope.root_agent_ref, profile, "go", opts)
      end

      assert {:ok, snapshot} = Runtime.scope_snapshot(scope.scope_ref)
      assert snapshot.agent_count == 1
      refute_receive {:child_started, _pid}
    end

    assert {:ok, run_ref} = Runtime.request_agent(scope.root_agent_ref, "child", "go")
    assert run_ref.model_ref == "test-model"
    assert_receive {:child_started, _pid}, 2_000
    assert :ok = Runtime.cancel(run_ref)
  end

  test "model overrides are validated and need backend support before admission" do
    root =
      AgentSpec.new!(
        name: "root",
        config: %{mode: :root, test_pid: self()},
        allow_delegation: true
      )

    child = AgentSpec.new!(name: "child", config: %{mode: :normal, test_pid: self()})
    scope_spec = ScopeSpec.new!(backend: Backend, root_spec: root, profiles: %{"child" => child})
    {:ok, scope} = Runtime.start_scope(scope_spec)
    on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)

    for {model, expected} <- [
          {"provider/model", {:model_selection_unsupported, "provider/model"}},
          {"", {:invalid_model, ""}},
          {:atom, {:invalid_model, :atom}}
        ] do
      assert {:error, ^expected} =
               Runtime.request_agent(scope.root_agent_ref, "child", "go", model: model)

      assert {:ok, %{agent_count: 1}} = Runtime.scope_snapshot(scope.scope_ref)
      refute_receive {:child_started, _pid}
    end

    assert {:ok, run_ref} =
             Runtime.request_agent(scope.root_agent_ref, "child", "go", model: nil)

    assert run_ref.model_ref == "test-model"
    assert :ok = Runtime.cancel(run_ref)
  end

  test "runtime operations preserve the backend failure contract" do
    for {mode, expected} <- [
          {:subscription_raise, {:error, {:agent_backend_failed, "backend crashed"}}},
          {:submission_exit, {:error, {:agent_unavailable, :backend_exited}}}
        ] do
      root = AgentSpec.new!(name: "root", config: %{mode: mode, test_pid: self()})
      {:ok, scope} = Runtime.start_scope(ScopeSpec.new!(backend: Backend, root_spec: root))

      assert if(mode == :subscription_raise,
               do: Runtime.subscribe(scope.root_agent_ref),
               else: Runtime.submit(scope.root_agent_ref, "go")
             ) == expected

      assert :ok = Runtime.stop_scope(scope.scope_ref)
    end
  end

  test "messaging keeps backend failures separate from routing checks" do
    root = AgentSpec.new!(name: "root", config: %{mode: :delivery_raise, test_pid: self()})
    {:ok, scope} = Runtime.start_scope(ScopeSpec.new!(backend: Backend, root_spec: root))
    on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)

    {:ok, envelope} = Envelope.new(:completion, scope.root_agent_ref, "done")

    assert {:error, {:agent_backend_failed, "backend crashed"}} =
             Messaging.deliver(scope.root_agent_ref, envelope)
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

  defp assert_eventually(_fun, 0), do: flunk("reservation was not released")
end
