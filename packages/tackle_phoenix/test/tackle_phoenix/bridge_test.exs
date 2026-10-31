defmodule Tackle.Phoenix.BridgeTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Phoenix.Bridge
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ScopeSpec

  @pubsub __MODULE__.PubSub
  @topic "conversation:1"

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    :ok = Phoenix.PubSub.subscribe(@pubsub, @topic)
    :ok
  end

  test "relays the agent's events to the topic" do
    {scope, agent} = start_agent()
    start_bridge!(scope.root_agent_ref)

    start = Event.message_start(id: "answer")
    delta = Event.new(:message_delta, %{delta: "Hi"}, id: "answer")
    send(agent, {:emit, start})
    send(agent, {:emit, delta})

    assert_receive {:agent_event, ^start}
    assert_receive {:agent_event, ^delta}
  end

  test "keeps only visible in-flight text until the message settles" do
    {scope, agent} = start_agent()
    bridge = start_bridge!(scope.root_agent_ref)

    emit(agent, Event.message_start(id: "answer"))
    emit(agent, Event.new(:message_delta, %{delta: "Hel"}, id: "answer"))
    emit(agent, Event.new(:message_delta, %{delta: "secret", field: :reasoning}, id: "answer"))
    emit(agent, Event.new(:message_delta, %{delta: "{}", field: :tool_input}, id: "answer"))
    emit(agent, Event.new(:message_delta, %{delta: "lo"}, id: "answer"))
    emit(agent, Event.message_start(id: "user", role: :user))

    assert Bridge.streaming(bridge) == %{"answer" => %{content: "Hello"}}

    emit(agent, Event.message_end(Message.assistant(id: "answer", content: "Hello")))
    assert Bridge.streaming(bridge) == %{}
  end

  test "a retry discards the partial answer and a finished turn clears everything" do
    {scope, agent} = start_agent()
    bridge = start_bridge!(scope.root_agent_ref)

    emit(agent, Event.message_start(id: "first"))
    emit(agent, Event.new(:message_delta, %{delta: "discard"}, id: "first"))
    emit(agent, Event.retry_scheduled(1, 3, 10, :overloaded, id: "first"))
    assert Bridge.streaming(bridge) == %{}

    emit(agent, Event.message_start(id: "second"))
    emit(agent, Event.new(:message_delta, %{delta: "partial"}, id: "second"))
    assert Bridge.streaming(bridge) == %{"second" => %{content: "partial"}}

    emit(agent, Event.turn_end("session", :error))
    assert Bridge.streaming(bridge) == %{}
  end

  test "broadcasts agent_down and stops when the agent exits" do
    {scope, _agent} = start_agent()
    bridge = start_bridge!(scope.root_agent_ref)
    monitor = Process.monitor(bridge)

    :ok = Runtime.stop_scope(scope.scope_ref)

    assert_receive {:agent_down, _reason}
    assert_receive {:DOWN, ^monitor, :process, ^bridge, :normal}
  end

  test "refuses to start when the agent rejects the subscription" do
    {scope, _agent} = start_agent(%{subscribe: {:error, :denied}})
    Process.flag(:trap_exit, true)

    assert {:error, {:subscribe_failed, :denied}} = start_bridge(scope.root_agent_ref)
  end

  test "refuses to start for an agent that no longer runs" do
    {scope, _agent} = start_agent()
    :ok = Runtime.stop_scope(scope.scope_ref)
    Process.flag(:trap_exit, true)

    assert {:error, :not_found} = start_bridge(scope.root_agent_ref)
  end

  test "validates its options" do
    {scope, _agent} = start_agent()
    Process.flag(:trap_exit, true)

    assert {:error, {:missing_option, :agent_ref}} =
             Bridge.start_link(pubsub: @pubsub, topic: @topic)

    assert {:error, {:invalid_option, :topic, ""}} =
             Bridge.start_link(agent_ref: scope.root_agent_ref, pubsub: @pubsub, topic: "")

    assert {:error, {:missing_option, :pubsub}} =
             Bridge.start_link(agent_ref: scope.root_agent_ref, topic: @topic)
  end

  # The bridge has relayed an event once the topic carries it.
  defp emit(agent, event) do
    send(agent, {:emit, event})
    assert_receive {:agent_event, ^event}
  end

  defp start_agent(config \\ %{}) do
    spec =
      ScopeSpec.new!(
        backend: Tackle.Phoenix.FakeBackend,
        root_spec: AgentSpec.new!(name: "root", config: config)
      )

    {:ok, scope} = Runtime.start_scope(spec)
    on_exit(fn -> Runtime.stop_scope(scope.scope_ref) end)
    {:ok, agent} = Runtime.session_pid(scope.root_agent_ref)
    {scope, agent}
  end

  defp start_bridge(agent_ref),
    do: Bridge.start_link(agent_ref: agent_ref, pubsub: @pubsub, topic: @topic)

  defp start_bridge!(agent_ref),
    do: start_supervised!({Bridge, agent_ref: agent_ref, pubsub: @pubsub, topic: @topic})
end
