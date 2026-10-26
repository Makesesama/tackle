defmodule Tackle.Session.TurnFailureTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Tree
  alias Tackle.Runtime
  alias Tackle.Runtime.Envelope
  alias Tackle.Session
  alias Tackle.Test.BlockingTool

  # Forwards `DynamicSupervisor.start_child/2` calls to the session's work
  # supervisor but refuses the ones whose position is listed, so a test can
  # fail one particular task start.
  defmodule RefusingSupervisor do
    use GenServer

    def start_link(real, refuse), do: GenServer.start_link(__MODULE__, {real, refuse})

    @impl true
    def init({real, refuse}), do: {:ok, %{real: real, refuse: refuse, count: 0}}

    @impl true
    def handle_call({:start_child, _child} = request, _from, state) do
      count = state.count + 1
      state = %{state | count: count}

      if count in state.refuse,
        do: {:reply, {:error, :max_children}, state},
        else: {:reply, GenServer.call(state.real, request, :infinity), state}
    end
  end

  setup do
    {:ok, home: tmp_home()}
  end

  describe "a crashed durable turn" do
    test "keeps the journaled turn in memory in a session without branching", ctx do
      scope =
        start_durable_scope(home: ctx.home, session: [tree: false], root: [mode: :manual])

      root = scope.root_agent_ref
      {:ok, snapshot} = Tackle.subscribe(root)

      {:ok, crashed} = Tackle.submit(root, "seed")
      assert_receive {:adapter_called, task, _model, _opts}, 5_000
      send(task, :crash)
      assert_receive {:tackle_turn_failed, _session_id, ^crashed, _reason}, 5_000

      assert {:ok, %{agent_state: agent_state}} = Tackle.snapshot(root)
      assert contents(agent_state.messages) == ["seed"]

      {:ok, next} = Tackle.submit(root, "next")
      assert_receive {:adapter_called, task, _model, _opts}, 5_000
      send(task, {:respond, "answer"})
      assert_receive {:tackle_turn_finished, _session_id, ^next, {:ok, agent_state}}, 5_000

      assert contents(agent_state.messages) == ["seed", "next", "answer"]
      {:ok, projection} = read_projection(snapshot.session_id, home: ctx.home)
      assert contents(projection.messages) == ["seed", "next", "answer"]
    end

    test "continues the journaled branch and repairs its interrupted tool call", ctx do
      call = %{"id" => "call-crash", "name" => "blocking", "arguments" => %{"name" => "crash"}}

      scope =
        start_durable_scope(
          home: ctx.home,
          root: [
            tools: [BlockingTool],
            context: %{test_pid: self()},
            mode: :tool_then_answer,
            llm_opts: [tool_call: call, content: "answer"]
          ]
        )

      root = scope.root_agent_ref
      {:ok, snapshot} = Tackle.subscribe(root)

      {:ok, crashed} = Tackle.submit(root, "seed")
      assert_receive {:adapter_called, task, _model, _opts}, 5_000
      assert_receive {:tool_entered, "crash", _tool}, 5_000
      Process.exit(task, :kill)
      assert_receive {:tackle_turn_failed, _session_id, ^crashed, :killed}, 5_000

      {:ok, next} = Tackle.submit(root, "next")
      assert_receive {:tackle_turn_finished, _session_id, ^next, {:ok, agent_state}}, 5_000

      assert Enum.map(agent_state.messages, & &1.role) == [
               :user,
               :assistant,
               :tool,
               :user,
               :assistant
             ]

      assert [_root] = Tree.children(agent_state.tree, nil)

      {:ok, projection} = read_projection(snapshot.session_id, home: ctx.home)
      assert Enum.map(projection.messages, & &1["id"]) == Enum.map(agent_state.messages, & &1.id)
    end
  end

  describe "a durable turn whose task fails to start" do
    test "is settled in the journal before the caller gets the error", ctx do
      scope = start_durable_scope(home: ctx.home, root: [content: "answer"])
      root = scope.root_agent_ref
      {:ok, snapshot} = Tackle.subscribe(root)
      refuse_task_starts(root, [2])

      assert {:error, {:turn_task_failed, :max_children}} = Tackle.submit(root, "lost")
      refute_received {:tackle_turn_failed, _session_id, _turn_id, _reason}

      {:ok, replay} = read_journal(snapshot.session_id, home: ctx.home)
      assert replay.projection.active_turn == nil
      assert Enum.count(replay.commits, &event?(&1, "turn.crashed")) == 1

      {:ok, turn} = Tackle.submit(root, "again")
      assert_receive {:tackle_turn_finished, _session_id, ^turn, {:ok, agent_state}}, 5_000
      assert contents(agent_state.messages) == ["again", "answer"]
    end

    test "started from the inbox fails visibly and keeps the journaled messages", ctx do
      scope = start_durable_scope(home: ctx.home, root: [content: "answer"])
      root = scope.root_agent_ref
      {:ok, snapshot} = Tackle.subscribe(root)
      session = refuse_task_starts(root, [2])

      {:ok, envelope} = Envelope.new(:message, root, "note")
      assert :ok = Session.deliver(session, envelope)

      assert_receive {:tackle_turn_started, _session_id, turn, :queued_messages}, 5_000

      assert_receive {:tackle_turn_failed, _session_id, ^turn,
                      {:turn_task_failed, :max_children}},
                     5_000

      notice = "Message from agent #{root.agent_id}:\n\nnote"
      assert {:ok, %{agent_state: agent_state}} = Tackle.snapshot(root)
      assert contents(agent_state.messages) == [notice]
      assert Session.inbox(session) == []

      {:ok, next} = Tackle.submit(root, "again")
      assert_receive {:tackle_turn_finished, _session_id, ^next, {:ok, agent_state}}, 5_000
      assert contents(agent_state.messages) == [notice, "again", "answer"]

      {:ok, projection} = read_projection(snapshot.session_id, home: ctx.home)
      assert projection.active_turn == nil
      assert contents(projection.messages) == [notice, "again", "answer"]
    end
  end

  test "a session without a journal keeps queued messages when the turn task fails to start" do
    scope = start_scope(root: [mode: :echo_messages])
    root = scope.root_agent_ref
    {:ok, _snapshot} = Tackle.subscribe(root)
    session = refuse_task_starts(root, [1])

    {:ok, envelope} = Envelope.new(:message, root, "note")
    assert :ok = Session.deliver(session, envelope)
    # The wake the delivery scheduled runs before this call, and fails.
    assert Session.inbox(session) == [envelope]

    {:ok, turn} = Tackle.submit(root, "go")
    assert_receive {:tackle_turn_finished, _session_id, ^turn, {:ok, agent_state}}, 5_000
    assert Tackle.Lib.last_answer(agent_state) =~ "note"
    assert Session.inbox(session) == []
  end

  defp refuse_task_starts(agent_ref, refuse) do
    {:ok, session} = Runtime.session_pid(agent_ref)
    {:ok, proxy} = RefusingSupervisor.start_link(:sys.get_state(session).work_supervisor, refuse)
    :sys.replace_state(session, &%{&1 | work_supervisor: proxy})
    session
  end

  defp contents(messages), do: Enum.map(messages, &message_content/1)

  defp message_content(%{content: content}), do: content
  defp message_content(%{"content" => content}), do: content

  defp event?(commit, type), do: Enum.any?(commit["events"], &(&1["type"] == type))
end
