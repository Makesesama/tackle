defmodule Tackle.Session.StoreTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.ID
  alias Tackle.Session.Catalog
  alias Tackle.Session.Storage

  setup do
    home = tmp_home()
    {:ok, home: home}
  end

  test "forks a self-contained session that survives parent deletion", ctx do
    {parent_id, scope} = create_session(ctx)
    {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "second")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    stop_scope(scope.scope_ref)

    assert {:ok, child_id} = Tackle.fork_session(parent_id, home: ctx.home)
    assert child_id != parent_id

    assert {:ok, child} = Tackle.inspect_session(child_id, home: ctx.home)
    assert child.parent["session_id"] == parent_id

    assert {:ok, parent} = Tackle.inspect_session(parent_id, home: ctx.home)
    assert child.messages == parent.messages

    assert :ok = Tackle.delete_session(parent_id, home: ctx.home)
    assert {:ok, _still_readable} = Tackle.inspect_session(child_id, home: ctx.home)
    assert {:error, _reason} = Tackle.inspect_session(parent_id, home: ctx.home)
  end

  test "forks only up to a selected sequence", ctx do
    {parent_id, scope} = create_session(ctx)
    {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "second")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    stop_scope(scope.scope_ref)

    assert {:ok, child_id} = Tackle.fork_session(parent_id, home: ctx.home, seq: 5)
    assert {:ok, child} = Tackle.inspect_session(child_id, home: ctx.home)
    assert length(child.messages) == 2
    assert child.last_seq == 6
    assert child.status == :clean
  end

  test "deletes an inactive session into trash and removes it from the catalog", ctx do
    {session_id, scope} = create_session(ctx)
    stop_scope(scope.scope_ref)

    assert :ok = Tackle.delete_session(session_id, home: ctx.home)
    assert {:error, :not_found} = Catalog.get(session_id)

    assert {:ok, trash} = Storage.trash_root(home: ctx.home)
    assert File.dir?(trash)
    assert Enum.any?(File.ls!(trash), &String.starts_with?(&1, session_id))
  end

  test "refuses to delete an active session", ctx do
    {session_id, _scope} = create_session(ctx)
    assert {:error, :session_active} = Tackle.delete_session(session_id, home: ctx.home)
  end

  test "flush_session is a durability barrier for live and unknown sessions", ctx do
    {session_id, _scope} = create_session(ctx)
    assert :ok = Tackle.flush_session(session_id)
    assert :ok = Tackle.flush_session(ID.generate())
  end

  defp create_session(ctx) do
    cwd = Path.join(ctx.home, "cwd-#{System.unique_integer([:positive])}")

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [cwd: cwd, title: "Stored"],
        root: [content: "answer"]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    {snapshot.session_id, scope}
  end
end
