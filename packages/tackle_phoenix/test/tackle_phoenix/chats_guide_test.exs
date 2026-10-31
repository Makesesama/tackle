defmodule Tackle.Phoenix.ChatsGuideTest do
  # Runs the runtime side of guides/conversations_with_ecto.md through
  # `Tackle.Phoenix.Test.Chats`, the guide's `MyApp.Chats` with an in-memory
  # store.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Event
  alias Tackle.Phoenix.Test.Chats
  alias Tackle.Runtime

  @moduletag :capture_log

  setup do
    for child <- Chats.children(), do: start_supervised!(child)
    :ok
  end

  test "an idle conversation starts again from its saved messages" do
    conversation = conversation(idle_timeout: 100)
    :ok = Phoenix.PubSub.subscribe(Chats.pubsub(), Chats.topic(conversation))

    assert {:ok, first} = Chats.submit(conversation, "Hi")
    assert_receive {:model_call, llm}, 2_000
    send(llm, {:finish, "Hello"})
    assert_receive {:agent_event, %Event{type: :turn_end}}, 2_000

    # Idle: the scope stops, the bridge broadcasts and leaves the registry.
    assert_receive {:agent_down, _reason}, 2_000
    assert :ok = eventually(fn -> Chats.running(conversation) == :error end)

    # The next message starts a new agent from what the hook saved.
    assert {:ok, second} = Chats.submit(conversation, "Again")
    assert second != first
    assert_receive {:model_call, llm}, 2_000

    assert {:ok, %{agent_state: state}} = Runtime.session_snapshot(second)
    assert state.session_id == conversation.id
    assert Enum.map(state.messages, & &1.content) == ["Hi", "Hello", "Again"]

    send(llm, {:finish, "Welcome back"})
    assert_receive {:agent_event, %Event{type: :turn_end}}, 2_000
    stop(second)

    assert :ok =
             eventually(fn ->
               Enum.map(Chats.Store.all(conversation.id), & &1.content) ==
                 ["Hi", "Hello", "Again", "Welcome back"]
             end)
  end

  test "a message sent while the agent is stopping goes to a new agent" do
    conversation = conversation(idle_timeout: :infinity)
    assert {:ok, old} = Chats.ensure_started(conversation)

    # The idle timeout has fired: the agent refuses work until its scope is gone.
    {:ok, pid} = Runtime.session_pid(old)
    :sys.replace_state(pid, &%{&1 | stopping: true})

    Task.start(fn ->
      Process.sleep(50)
      stop(old)
    end)

    assert {:ok, new} = Chats.submit(conversation, "Hi")
    assert new != old
    assert_receive {:model_call, llm}, 2_000
    send(llm, {:finish, "Hello"})
    assert :ok = eventually(fn -> length(Chats.Store.all(conversation.id)) == 2 end)
    stop(new)
  end

  test "concurrent starts share one agent" do
    conversation = conversation(idle_timeout: :infinity)
    scopes = fn -> DynamicSupervisor.count_children(Tackle.AgentSupervisor).active end
    before = scopes.()

    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Chats.ensure_started(conversation) end) end)
      |> Task.await_many(5_000)

    assert [{:ok, agent_ref}] = Enum.uniq(results)
    assert {:ok, ^agent_ref} = Chats.running(conversation)

    # The agents that lost the race were stopped with their scopes.
    assert :ok = eventually(fn -> scopes.() == before + 1 end)
    stop(agent_ref)
  end

  test "cancel reaches a running conversation and is harmless otherwise" do
    conversation = conversation(idle_timeout: :infinity)
    assert :ok = Chats.cancel(conversation)
    assert Chats.streaming(conversation) == %{}

    :ok = Phoenix.PubSub.subscribe(Chats.pubsub(), Chats.topic(conversation))
    assert {:ok, agent_ref} = Chats.submit(conversation, "Hi")
    assert_receive {:model_call, llm}, 2_000
    send(llm, {:delta, "Hel"})

    assert :ok =
             eventually(fn ->
               Map.values(Chats.streaming(conversation)) == [%{content: "Hel"}]
             end)

    assert :ok = Chats.cancel(conversation)

    assert_receive {:agent_event, %Event{type: :turn_end, data: %{status: :cancelled}}}, 2_000
    stop(agent_ref)
  end

  defp stop(agent_ref), do: Runtime.stop_scope(Tackle.Runtime.Ref.scope_ref(agent_ref))

  defp conversation(opts) do
    %{
      id: Tackle.Lib.ID.uuid4(),
      test_pid: self(),
      idle_timeout: Keyword.fetch!(opts, :idle_timeout)
    }
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: :timeout

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
