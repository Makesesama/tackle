defmodule Tackle.Runtime.RequestSetupTest do
  use ExUnit.Case, async: false

  alias Tackle.Runtime
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Messaging
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

      {:ok, spec.config}
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
    def handle_call({:subscribe, []}, _from, state) do
      result =
        case state.mode do
          :subscription_error -> {:error, :subscription_denied}
          :subscription_raise -> :raise_backend
          _other -> {:ok, %{}}
        end

      {:reply, result, state}
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

      opts =
        if unquote(mode) in [:subscription_error, :subscription_raise],
          do: [event_callback: fn _event -> :ok end],
          else: []

      assert {:ok, run_ref} = Runtime.request_agent(scope.root_agent_ref, "child", "go", opts)

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
