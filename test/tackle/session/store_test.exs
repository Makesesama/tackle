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
    assert [_, _] = child.messages
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

  test "reads current and fork-safe all-session usage timelines", ctx do
    {parent_id, parent_scope} = create_usage_session(ctx, 5)

    assert {:ok, current} = Tackle.session_usage_timeline(parent_id, home: ctx.home)
    assert current.scope == {:session, parent_id}
    assert current.usage.total_tokens == 5
    assert [_sample] = current.samples

    stop_scope(parent_scope.scope_ref)
    assert {:ok, child_id} = Tackle.fork_session(parent_id, home: ctx.home)
    {other_id, other_scope} = create_usage_session(ctx, 7)
    stop_scope(other_scope.scope_ref)

    assert {:ok, all} = Tackle.all_usage_timeline(home: ctx.home, usage_concurrency: 2)
    assert all.scope == :all
    assert all.session_count == 3
    assert all.usage.total_tokens == 12
    assert all.duplicate_sample_count == 1
    assert [_sample_one, _sample_two] = all.samples

    source_ids = MapSet.new(Enum.map(all.samples, & &1.session_id))
    assert MapSet.member?(source_ids, other_id)
    assert MapSet.size(MapSet.intersection(source_ids, MapSet.new([parent_id, child_id]))) == 1
  end

  test "all-session usage returns partial diagnostics for unreadable journals", ctx do
    {valid_id, scope} = create_usage_session(ctx, 9)
    stop_scope(scope.scope_ref)

    bad_id = ID.generate()
    {:ok, bad_dir} = Storage.ensure_session_dir(bad_id, home: ctx.home)
    File.write!(Path.join(bad_dir, "session.dlog"), "not a disk log")

    assert {:error, _reason} = Tackle.session_usage_timeline(bad_id, home: ctx.home)
    assert {:ok, all} = Tackle.all_usage_timeline(home: ctx.home)
    assert all.usage.total_tokens == 9
    assert all.session_count == 1
    assert all.skipped_session_count == 1
    assert [%{session_id: ^bad_id}] = all.skipped_sessions
    assert [%{session_id: ^valid_id}] = Enum.map(all.samples, &%{session_id: &1.session_id})
  end

  defp create_session(ctx) do
    cwd = Path.join(ctx.home, "cwd-#{System.unique_integer([:positive])}")

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [cwd: cwd, title: "Stored"],
        root: [content: "answer"]
      )

    finish_first_turn(scope)
  end

  defp create_usage_session(ctx, total_tokens) do
    cwd = Path.join(ctx.home, "usage-cwd-#{System.unique_integer([:positive])}")

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [cwd: cwd, title: "Usage"],
        root: [content: "answer", llm_opts: [usage: %{total_tokens: total_tokens}]]
      )

    finish_first_turn(scope)
  end

  defp finish_first_turn(scope) do
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    {snapshot.session_id, scope}
  end
end
