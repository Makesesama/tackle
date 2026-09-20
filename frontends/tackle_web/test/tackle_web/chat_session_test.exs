defmodule Tackle.Web.ChatSessionTest do
  # Runners are keyed per conversation but the store and the harness
  # configuration are global.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Web.ChatAgent
  alias Tackle.Web.ChatFixture
  alias Tackle.Web.ChatSession
  alias Tackle.Web.ChatStore

  @slug "local-widgets-1a2b3c"

  @turn_timeout 5_000

  setup do
    ChatFixture.setup()
  end

  describe "the first look at a conversation" do
    test "builds an agent and reports no turn running", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

      assert {:ok, snapshot} = ChatSession.snapshot(conversation)

      assert %State{} = snapshot.agent_state
      assert snapshot.agent_state.context.cwd == cwd
      refute snapshot.turn_active?
      assert snapshot.runner_pid == nil
    end

    test "resumes the stored transcript", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      :ok = ChatStore.put_messages(conversation.id, [Message.user("Remembered?")])

      assert {:ok, snapshot} = ChatSession.snapshot(ChatStore.get(conversation.id))

      assert Enum.map(snapshot.agent_state.messages, & &1.content) == ["Remembered?"]
    end
  end

  describe "a turn" do
    test "answers and settles the transcript into the store", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      {:ok, snapshot} = ChatSession.snapshot(conversation)
      :ok = ChatSession.subscribe(conversation.id)

      assert {:ok, pid} = ChatSession.run_turn(conversation.id, snapshot.agent_state, "Hello")
      assert is_pid(pid)

      assert_receive {:agent_turn_done, {:ok, %State{} = state}}, @turn_timeout

      assert Enum.map(state.messages, &{&1.role, &1.content}) == [
               {:user, "Hello"},
               {:assistant, "Echo: Hello"}
             ]

      # The transcript outlives the Runner, which stops after thirty idle
      # minutes; this is what a reload or a restarted Runner reads back.
      stored = ChatStore.get(conversation.id)
      assert Enum.map(stored.messages, & &1.role) == [:user, :assistant]
      assert stored.title == "Hello"
    end

    test "can be retried without asking a new question", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      {:ok, snapshot} = ChatSession.snapshot(conversation)
      :ok = ChatSession.subscribe(conversation.id)

      {:ok, _pid} = ChatSession.run_turn(conversation.id, snapshot.agent_state, "Hello")
      assert_receive {:agent_turn_done, {:ok, state}}, @turn_timeout

      {:ok, _pid} = ChatSession.continue_turn(conversation.id, state)
      assert_receive {:agent_turn_done, {:ok, _state}}, @turn_timeout

      assert Enum.map(ChatStore.get(conversation.id).messages, & &1.role) == [
               :user,
               :assistant,
               :assistant
             ]
    end

    test "is refused when the working directory is gone", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      {:ok, snapshot} = ChatSession.snapshot(conversation)

      File.rm_rf!(cwd)

      assert {:error, {:workspace_missing, ^cwd}} =
               ChatSession.run_turn(conversation.id, snapshot.agent_state, "Hello")
    end
  end

  describe "changing the model" do
    test "keeps the conversation and changes the configuration", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      {:ok, state} = ChatAgent.new(cwd: cwd, model: "fake/echo")
      state = ChatAgent.with_messages(state, [Message.user("Hello")])
      :ok = ChatStore.put_messages(conversation.id, state.messages)

      assert {:ok, switched} =
               ChatSession.change_model(conversation, state, ChatFixture.other_model())

      assert switched.llm.model == "echo-2"
      assert switched.messages == state.messages

      stored = ChatStore.get(conversation.id)
      assert stored.model == "fake/echo-2"
      assert stored.messages == state.messages
    end

    test "reports a model no adapter offers", %{cwd: cwd} do
      {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
      {:ok, state} = ChatAgent.new(cwd: cwd, model: "fake/echo")

      assert {:error, {:unknown_model, "fake/nope"}} =
               ChatSession.change_model(conversation, state, "fake/nope")
    end
  end
end
