defmodule Tackle.Session.TreeTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Tree
  alias Tackle.Runtime.ID
  alias Tackle.Session.Journal
  alias Tackle.Session.Reader

  setup do
    home = tmp_home()
    {:ok, home: home}
  end

  test "a completed turn becomes a parent-linked tree", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "hello back"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    {:ok, tree} = Tackle.tree(scope.root_agent_ref)
    assert [user, assistant] = Tree.transcript(tree)
    assert user.role == :user
    assert assistant.role == :assistant
    assert Tree.entry(tree, assistant.id).parent_id == user.id
    assert Tree.active_id(tree) == assistant.id

    {:ok, projection} = Reader.projection(snapshot.session_id, home: ctx.home)
    assert projection.tree_enabled?
    assert Enum.map(projection.messages, & &1["content"]) == ["hello", "hello back"]
  end

  test "navigation is committed without a following prompt and survives resume", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    {:ok, tree} = Tackle.tree(scope.root_agent_ref)
    [user | _rest] = Tree.transcript(tree)
    session_id = snapshot.session_id

    assert {:ok, %{agent_state: %{tree: navigated}} = _snap, outcome} =
             Tackle.navigate(scope.root_agent_ref, {:edit, user.id})

    assert outcome.draft.content == "first"
    assert Tree.active_id(navigated) == nil

    stop_scope(scope.scope_ref)

    resumed =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [content: "second"]
      )

    {:ok, resumed_snapshot} = Tackle.snapshot(resumed.root_agent_ref)
    assert Tree.active_id(resumed_snapshot.agent_state.tree) == nil
    assert resumed_snapshot.agent_state.messages == []

    {:ok, _resumed_sub} = Tackle.subscribe(resumed.root_agent_ref)

    {:ok, turn_id} = Tackle.submit(resumed.root_agent_ref, "second question")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    {:ok, tree} = Tackle.tree(resumed.root_agent_ref)
    assert [_, _] = Tree.children(tree, nil)
    assert Enum.map(Tree.transcript(tree), & &1.content) == ["second question", "second"]
  end

  test "re-editing a user message creates a sibling without duplicating ancestors", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "answer"])
    {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    {:ok, tree} = Tackle.tree(scope.root_agent_ref)
    [user | _rest] = Tree.transcript(tree)

    assert {:ok, _snap, outcome} = Tackle.navigate(scope.root_agent_ref, {:edit, user.id})
    assert outcome.draft.content == "first"

    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "edited first")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    {:ok, tree} = Tackle.tree(scope.root_agent_ref)
    assert [_, _] = Tree.children(tree, nil)
    assert Enum.map(Tree.transcript(tree), & &1.content) == ["edited first", "answer"]
    assert Enum.count(Tree.enumerate(tree), &(&1.kind == :message)) == 4
  end

  test "navigation is rejected while a turn is active", ctx do
    scope =
      start_durable_scope(
        home: ctx.home,
        root: [mode: :manual, content: "answer"]
      )

    {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, _turn_id} = Tackle.submit(scope.root_agent_ref, "hold the turn")
    assert_receive {:adapter_called, _pid, _model, _opts}, 5_000

    assert {:error, :turn_in_progress} = Tackle.navigate(scope.root_agent_ref, nil)
  end

  test "a legacy linear journal is upgraded in place and then branches", ctx do
    scope =
      start_durable_scope(
        home: ctx.home,
        root: [content: "answer"],
        session: [tree: false]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "linear")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    session_id = snapshot.session_id
    stop_scope(scope.scope_ref)

    {:ok, projection} = Reader.projection(session_id, home: ctx.home)
    refute projection.tree_enabled?

    resumed =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [content: "answer two"]
      )

    {:ok, resumed_snapshot} = Tackle.snapshot(resumed.root_agent_ref)
    tree = resumed_snapshot.agent_state.tree
    assert [_, _] = Tree.transcript(tree)

    {:ok, projection} = Reader.projection(session_id, home: ctx.home)
    assert projection.tree_enabled?

    [user | _rest] = Tree.transcript(tree)
    assert {:ok, _snap, _outcome} = Tackle.navigate(resumed.root_agent_ref, {:edit, user.id})
  end

  test "navigation cannot bypass unresolved recovery", ctx do
    session_id = ID.generate()
    {:ok, journal} = Journal.start_link(session_id: session_id, home: ctx.home)
    {:ok, _turn_id} = Journal.begin_turn(journal, :run, "interrupted")
    :ok = GenServer.stop(journal)

    scope = start_durable_scope(home: ctx.home, session: [session_id: session_id])

    assert {:error, {:recovery_required, _info}} = Tackle.navigate(scope.root_agent_ref, nil)
  end

  test "a fork copies the tree and active position", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    session_id = snapshot.session_id
    stop_scope(scope.scope_ref)

    {:ok, forked_id} = Tackle.fork_session(session_id, home: ctx.home)
    assert {:ok, projection} = Reader.projection(forked_id, home: ctx.home)

    assert projection.tree_enabled?
    assert [user, assistant] = Tree.enumerate(projection.tree)
    assert Tree.entry(projection.tree, assistant.id).parent_id == user.id
    assert Tree.active_id(projection.tree) == assistant.id
  end

  test "an invalid parent link is rejected rather than repaired", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    session_id = snapshot.session_id
    stop_scope(scope.scope_ref)

    {:ok, replay} = Reader.read(session_id, home: ctx.home)

    assert {:ok, _} =
             Tree.restore(
               replay.projection.tree
               |> Tree.enumerate()
               |> Enum.map(&Map.from_struct/1)
             )

    bad = [
      %{
        id: "x",
        parent_id: "missing",
        kind: :message,
        message: %Tackle.Lib.Message{id: "x", role: :user}
      }
    ]

    assert {:error, {:unknown_parent, "missing"}} = Tree.restore(bad)
  end
end
