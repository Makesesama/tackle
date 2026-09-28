defmodule Tackle.Runtime.RequestSetupTest do
  use ExUnit.Case, async: false

  alias Tackle.Runtime
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ScopeSpec

  defmodule Backend do
    @behaviour Tackle.Runtime.AgentBackend
    use GenServer

    @impl true
    def validate_spec(_spec), do: :ok

    @impl true
    def child_spec(spec, context), do: {__MODULE__, {spec, context}}

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
    def call(pid, operation, args), do: GenServer.call(pid, {operation, args})

    @impl true
    def handle_call({:subscribe, []}, _from, state) do
      if state.mode == :subscription_error,
        do: {:reply, {:error, :subscription_denied}, state},
        else: {:reply, {:ok, %{}}, state}
    end

    def handle_call({:submit, [_prompt]}, _from, state) do
      if state.mode == :submission_error,
        do: {:reply, {:error, :submission_denied}, state},
        else: {:reply, {:ok, "turn"}, state}
    end

    def handle_call({:cancel, [_reason]}, _from, state), do: {:reply, :ok, state}
  end

  for {mode, reason} <- [
        {:unregistered, :agent_not_registered},
        {:subscription_error, {:event_subscription_failed, :subscription_denied}},
        {:submission_error, :submission_denied}
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
        if unquote(mode) == :subscription_error,
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
