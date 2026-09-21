defmodule Tackle.Phoenix.RuntimeBackendTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Phoenix.RuntimeBackend
  alias Tackle.Phoenix.RuntimeSpec
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.ScopeSpec

  @pubsub __MODULE__.PubSub
  @registry __MODULE__.Registry
  @dynamic_supervisor __MODULE__.DynamicSupervisor
  @task_supervisor __MODULE__.TaskSupervisor

  defmodule Agent do
    def continue(state, opts) do
      tool_supervisor = Keyword.fetch!(opts, :tool_supervisor)
      send(state.context.test_pid, {:tool_supervisor, GenServer.whereis(tool_supervisor)})
      {:ok, State.add_message(state, Message.assistant(content: "done"))}
    end
  end

  defmodule Store do
    @behaviour Tackle.Phoenix.Store

    def before_turn(host, _opts), do: notify(host, :before_turn, :ok)
    def enrich_state(_host, state, _opts), do: state

    def persist_user_message(host, _state, _message),
      do: notify(host, :persist_user_message, host)

    def settle_turn(host, _result, _usage, _opts), do: notify(host, :settle_turn, host)
    def after_turn(host, _result, _opts), do: host
    def current_session_id(host), do: host.session_id
    def handle_turn_failed(host, _reason, _opts), do: {host, nil}

    defp notify(host, event, result) do
      send(host.test_pid, {:store, host.session_id, event})
      result
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @dynamic_supervisor})
    start_supervised!({Task.Supervisor, name: @task_supervisor})
    :ok
  end

  test "delegated Phoenix agents use Store lifecycle and a dedicated tool supervisor" do
    root = agent_spec("root", "root-session", true)
    child = agent_spec("worker", "child-session", false)

    scope_spec =
      ScopeSpec.new!(
        backend: RuntimeBackend,
        root_spec: root,
        profiles: %{"worker" => child},
        limits: Limits.new!(max_agents_per_fleet: 2, max_children_per_agent: 1)
      )

    assert {:ok, scope} = Runtime.start_scope(scope_spec)
    on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)

    assert {:ok, run_ref} = Runtime.request_agent(scope.root_agent_ref, "worker", "do it")
    assert %Runtime.Outcome{status: :ok, agent_state: %State{} = state} = Runtime.await(run_ref)
    assert %Message{content: "done"} = List.last(state.messages)

    assert_receive {:store, "child-session", :before_turn}
    assert_receive {:store, "child-session", :persist_user_message}
    assert_receive {:tool_supervisor, tool_supervisor} when is_pid(tool_supervisor)
    assert_receive {:store, "child-session", :settle_turn}
  end

  defp agent_spec(name, session_id, allow_delegation) do
    state = %State{
      context: %{test_pid: self(), persistence: %{}},
      tool_policy: Policy.concurrent()
    }

    runtime_spec =
      RuntimeSpec.new!(
        runner: %{
          registry: @registry,
          dynamic_supervisor: @dynamic_supervisor,
          task_supervisor: @task_supervisor,
          pubsub: @pubsub,
          store: Store,
          agent: Agent
        },
        user_id: "user",
        session_id: session_id,
        agent_state: state,
        host_state: %{test_pid: self(), session_id: session_id}
      )

    AgentSpec.new!(
      name: name,
      config: runtime_spec,
      allow_delegation: allow_delegation
    )
  end
end
