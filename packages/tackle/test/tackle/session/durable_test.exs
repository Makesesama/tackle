defmodule Tackle.Session.DurableTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Message
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Lib.Tree
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.ID
  alias Tackle.Session.Committer
  alias Tackle.Session.Durable
  alias Tackle.Session.Journal
  alias Tackle.Session.Persistence
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Session.Turn

  defmodule ContextTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "context"

    @impl true
    def description, do: "Reports its execution context to the test."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, context) do
      send(context.test_pid, {:tool_context, context})
      {:ok, %{}}
    end
  end

  setup do
    {:ok, home: tmp_home(), agent_ref: AgentRef.new!(ID.generate(), ID.generate())}
  end

  describe "without a journal" do
    test "open builds the state from the configuration", ctx do
      store = Tackle.Auth.credential_store()

      assert {:ok, opened} = Durable.open(config(), ctx.agent_ref, nil)
      assert %{journal: nil, recovery: nil, tree_enabled?: false, title: nil} = opened
      assert opened.storage == :ready
      assert opened.config.llm_opts[:credential_store] == store
      assert opened.agent_state.llm_opts[:credential_store] == store
      assert opened.agent_state.context.runtime == ctx.agent_ref
      assert opened.agent_state.committer == nil
      refute Persistence in opened.agent_state.hooks
    end

    test "has no gates and writes nothing" do
      turn = Turn.new("turn-1", :run, "hello", AgentState.new())
      on_exit(fn -> Turn.delete_signal(turn) end)

      assert Durable.provider_gate(nil) == nil
      assert Durable.tool_gate(nil) == nil
      assert :ok = Durable.begin_turn(nil, turn, "hello", AgentState.new(), [])
      assert :ok = Durable.settle_turn(nil, "turn-1", {:runtime_error, :crashed})
    end
  end

  describe "with a journal" do
    test "open restores the recorded session and repairs unresolved tool calls", ctx do
      session_id = ID.generate()
      {:ok, journal} = Journal.start_link(session_id: session_id, home: ctx.home)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "run tools", ID.generate())
      :ok = Journal.append_message(journal, Message.user("run tools"))
      call = %{id: "call-1", name: "bash", arguments: %{}}
      :ok = Journal.append_message(journal, Message.assistant(content: nil, tool_calls: [call]))
      :ok = Journal.settle_turn(journal, "turn.completed", %{})
      :ok = Journal.metadata_changed(journal, %{"title" => "Run tools"})

      spec = SessionSpec.new!(session_id: session_id)
      assert {:ok, opened} = Durable.open(config(), ctx.agent_ref, spec)

      assert %{journal: ^journal, recovery: nil, tree_enabled?: true, title: "Run tools"} =
               opened

      assert opened.storage == :ready
      assert opened.agent_state.session_id == session_id
      assert opened.agent_state.committer == Committer
      assert Persistence in opened.agent_state.hooks
      assert opened.agent_state.context.runtime == ctx.agent_ref

      assert [%Message{role: :tool, tool_call_id: "call-1"} = repaired] =
               Enum.filter(opened.agent_state.messages, &(&1.role == :tool))

      {:ok, projection} = Journal.projection(journal)
      assert repaired.id in Enum.map(projection.messages, & &1["id"])

      GenServer.stop(journal)
    end

    test "tools of a durable session see none of its internals", ctx do
      scope =
        start_durable_scope(
          home: ctx.home,
          root: [
            tools: [ContextTool],
            context: %{test_pid: self()},
            llm_opts: [
              mode: :tool_then_answer,
              tool_call: %{"id" => "c1", "name" => "context", "arguments" => %{}}
            ]
          ]
        )

      root = scope.root_agent_ref
      {:ok, _snapshot} = Tackle.subscribe(root)
      {:ok, turn_id} = Tackle.submit(root, "hello")
      assert_receive {:tool_context, context}, 5_000
      assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

      assert context.runtime == root
      refute Map.has_key?(context, :session_owner)
      refute Map.has_key?(context, :journal_required)
    end

    test "append_message records the message's tree parent", ctx do
      session_id = ID.generate()
      {:ok, journal} = Journal.start_link(session_id: session_id, home: ctx.home)
      :ok = Journal.enable_tree(journal)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello", ID.generate())

      first = Message.user("hello")
      second = Message.assistant(content: "answer")

      state =
        AgentState.new(session_id: session_id)
        |> AgentState.add_message(first)
        |> AgentState.add_message(second)

      assert :ok = Durable.append_message(journal, state, first)
      assert :ok = Durable.append_message(journal, state, second)

      {:ok, projection} = Journal.projection(journal)
      assert %{parent_id: nil} = Tree.entry(projection.tree, first.id)
      assert %{parent_id: parent_id} = Tree.entry(projection.tree, second.id)
      assert parent_id == first.id

      GenServer.stop(journal)
    end
  end
end
