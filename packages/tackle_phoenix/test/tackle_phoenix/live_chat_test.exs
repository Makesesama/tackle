defmodule Tackle.Phoenix.LiveChatTest do
  # End to end: a `Tackle.Runtime.LoopAgent` scope, a `Tackle.Phoenix.Bridge`
  # on a real PubSub, and a chat LiveView wired as the README shows
  # (`Tackle.Phoenix.Test.ChatLive`), mounted by `Tackle.Phoenix.Test.LiveHarness`.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Message
  alias Tackle.Phoenix.Bridge
  alias Tackle.Phoenix.Test.ChatLive
  alias Tackle.Phoenix.Test.LiveHarness
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.LoopAgent
  alias Tackle.Runtime.ScopeSpec

  @moduletag :capture_log

  @pubsub __MODULE__.PubSub
  @topic "conversation:1"

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    :ok
  end

  test "a turn streams into the view and settles to the agent's transcript" do
    chat = start_chat()
    view = mount(chat)

    assert %{processing: false, streaming_messages: streaming} = LiveHarness.assigns(view)
    assert streaming == %{}

    :ok = LiveHarness.event(view, "submit", %{"input" => "Hi"})
    assert LiveHarness.assigns(view).processing
    assert_receive {:model_call, llm}, 2_000

    # The user's own message arrives as a settled message.
    assert_eventually(view, &(contents(&1) == ["Hi"]))

    send(llm, {:delta, "Hel"})
    assert_eventually(view, &(streaming_text(&1) == ["Hel"]))
    send(llm, {:delta, "lo"})
    assert_eventually(view, &(streaming_text(&1) == ["Hello"]))

    send(llm, {:finish, "Hello!"})

    assert_eventually(view, fn assigns ->
      not assigns.processing and assigns.streaming_messages == %{} and
        contents(assigns) == ["Hi", "Hello!"]
    end)

    assert_same_transcript(view, chat.agent_ref)
    assigns = LiveHarness.assigns(view)

    for message <- assigns.agent_state.messages do
      assert Map.has_key?(assigns.message_stream_blocks, "agent-msg-block-#{message.id}")
    end
  end

  test "a view that joins mid-turn catches up and then follows the turn" do
    chat = start_chat()
    first = mount(chat)

    :ok = LiveHarness.event(first, "submit", %{"input" => "Hi"})
    assert_receive {:model_call, llm}, 2_000
    send(llm, {:delta, "Hel"})
    assert_eventually(first, &(streaming_text(&1) == ["Hel"]))

    # The bridge has broadcast everything the first view saw.
    second = mount(chat)
    joined = LiveHarness.assigns(second)
    assert joined.processing
    assert contents(joined) == ["Hi"]
    assert streaming_text(joined) == ["Hel"]

    send(llm, {:delta, "lo"})
    assert_eventually(second, &(streaming_text(&1) == ["Hello"]))
    send(llm, {:finish, "Hello!"})

    for view <- [first, second] do
      assert_eventually(view, &(not &1.processing and contents(&1) == ["Hi", "Hello!"]))
      assert_same_transcript(view, chat.agent_ref)
    end
  end

  test "cancelling clears the in-flight answer and leaves the view in step with the agent" do
    chat = start_chat()
    view = mount(chat)

    :ok = LiveHarness.event(view, "submit", %{"input" => "Hi"})
    assert_receive {:model_call, llm}, 2_000
    send(llm, {:delta, "partial"})
    assert_eventually(view, &(streaming_text(&1) == ["partial"]))

    :ok = LiveHarness.event(view, "cancel")

    assert_eventually(view, &(not &1.processing and &1.streaming_messages == %{}))
    assert_same_transcript(view, chat.agent_ref)
    assert {:ok, %{active_turn: nil}} = Runtime.session_snapshot(chat.agent_ref)

    # The agent takes the next turn.
    :ok = LiveHarness.event(view, "submit", %{"input" => "Again"})
    assert_receive {:model_call, llm}, 2_000
    send(llm, {:finish, "Done"})
    assert_eventually(view, &(not &1.processing and List.last(contents(&1)) == "Done"))
    assert_same_transcript(view, chat.agent_ref)
  end

  test "a resumed conversation renders its saved transcript and continues it" do
    saved = [Message.user("Earlier", id: "m1"), Message.assistant(content: "Answer", id: "m2")]
    chat = start_chat(session_id: "saved", messages: saved)
    view = mount(chat)

    assert contents(LiveHarness.assigns(view)) == ["Earlier", "Answer"]

    :ok = LiveHarness.event(view, "submit", %{"input" => "More"})
    assert_receive {:model_call, llm}, 2_000
    send(llm, {:finish, "Sure"})

    assert_eventually(
      view,
      &(not &1.processing and contents(&1) == ["Earlier", "Answer", "More", "Sure"])
    )

    assert_same_transcript(view, chat.agent_ref)
  end

  test "the view learns when the agent goes away" do
    chat = start_chat()
    view = mount(chat)

    :ok = LiveHarness.event(view, "submit", %{"input" => "Hi"})
    assert_receive {:model_call, _llm}, 2_000

    :ok = Runtime.stop_scope(chat.scope_ref)

    assert_eventually(view, &(not &1.processing and &1.agent_error != nil))
    assert {:error, _reason} = Runtime.submit(chat.agent_ref, "Hello?")
  end

  test "an idle conversation stops and the view learns" do
    chat = start_chat(idle_timeout: 100)
    view = mount(chat)
    bridge = Process.monitor(chat.bridge)

    :ok = LiveHarness.event(view, "submit", %{"input" => "Hi"})
    assert_receive {:model_call, llm}, 2_000
    send(llm, {:finish, "Hello"})
    assert_eventually(view, &(not &1.processing and contents(&1) == ["Hi", "Hello"]))

    # A turn and the view's own calls count as activity; then nothing does.
    assert_receive {:DOWN, ^bridge, :process, _pid, :normal}, 2_000
    assert_eventually(view, &(&1.agent_error != nil))
    assert :ok = eventually(fn -> scope_gone?(chat.scope_ref) end)
  end

  # A scope that is shutting down exits callers until it is gone.
  defp scope_gone?(scope_ref) do
    Runtime.scope_snapshot(scope_ref) == {:error, :scope_not_found}
  catch
    :exit, _reason -> false
  end

  defp start_chat(opts \\ []) do
    {:ok, config} =
      LoopAgent.Config.new(
        [
          providers: [Tackle.Phoenix.Test.LLM],
          model: "test/chat",
          llm_opts: [test_pid: self()]
        ] ++ opts
      )

    {:ok, scope} =
      Runtime.start_scope(
        ScopeSpec.new!(
          backend: LoopAgent,
          root_spec: AgentSpec.new!(name: "root", config: config)
        )
      )

    on_exit(fn -> stop_scope(scope.scope_ref) end)

    bridge =
      start_supervised!({Bridge, agent_ref: scope.root_agent_ref, pubsub: @pubsub, topic: @topic})

    %{agent_ref: scope.root_agent_ref, scope_ref: scope.scope_ref, bridge: bridge}
  end

  defp mount(chat) do
    session = %{
      "agent_ref" => chat.agent_ref,
      "bridge" => chat.bridge,
      "pubsub" => @pubsub,
      "topic" => @topic
    }

    {:ok, view} = LiveHarness.start_link(ChatLive, session)
    view
  end

  defp stop_scope(ref) do
    Runtime.stop_scope(ref)
  catch
    :exit, _reason -> :ok
  end

  defp contents(assigns), do: Enum.map(assigns.agent_state.messages, & &1.content)

  defp streaming_text(assigns),
    do: assigns.streaming_messages |> Map.values() |> Enum.map(& &1.content)

  # The view built its transcript from events alone; it must end up with the
  # agent's own, once the agent has settled the turn.
  defp assert_same_transcript(view, agent_ref) do
    ids = fn messages -> Enum.map(messages, & &1.id) end

    assert :ok =
             eventually(fn ->
               case Runtime.session_snapshot(agent_ref) do
                 {:ok, %{agent_state: state, active_turn: nil}} ->
                   ids.(LiveHarness.assigns(view).agent_state.messages) == ids.(state.messages)

                 _turn_still_settling ->
                   false
               end
             end)
  end

  defp assert_eventually(view, fun) do
    assert :ok = eventually(fn -> fun.(LiveHarness.assigns(view)) end),
           "view assigns never matched: #{inspect(Map.take(LiveHarness.assigns(view), [:processing, :streaming_messages, :agent_error]))}"
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
