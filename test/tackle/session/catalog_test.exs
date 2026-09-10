defmodule Tackle.Session.CatalogTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Session.Catalog

  setup do
    home = Tackle.Test.Runtime.tmp_home()
    {:ok, home: home}
  end

  test "lists and searches durable sessions", ctx do
    cwd = unique_cwd(ctx, "alpha")
    create_session(ctx, cwd: cwd, title: "Alpha work", content: "answer")
    other = unique_cwd(ctx, "beta")
    create_session(ctx, cwd: other, title: "Beta work", content: "answer")

    Catalog.rebuild(home: ctx.home)

    assert {:ok, %{sessions: sessions}} = Tackle.list_sessions(%{cwd: cwd})
    assert Enum.map(sessions, & &1.title) == ["Alpha work"]

    assert {:ok, %{sessions: found}} = Tackle.search_sessions("Alpha work")
    assert Enum.map(found, & &1.cwd) == [cwd]
  end

  test "excludes tool arguments and tool output from default search", ctx do
    secret = "SECRET-#{System.unique_integer([:positive])}"
    path = Path.join(ctx.home, "tool-input.txt")
    File.write!(path, secret)

    tool_call = %{"id" => "call_1", "name" => "read", "arguments" => %{"path" => path}}

    scope =
      start_durable_scope(
        home: ctx.home,
        root: [
          tools: [Tackle.Tools.Read],
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "done"]
        ]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "please read a file")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, entry} = Tackle.session_summary(snapshot.session_id, home: ctx.home)
    refute Map.has_key?(entry, :search_text)

    assert {:ok, %{sessions: []}} = Tackle.search_sessions(secret)
  end

  test "paginates with a stable cursor", ctx do
    cwd = unique_cwd(ctx, "paged")
    ids = for index <- 1..3, do: create_session(ctx, cwd: cwd, title: "Page #{index}")

    Catalog.rebuild(home: ctx.home)

    {:ok, %{sessions: first_page, next_cursor: cursor}} =
      Tackle.list_sessions(%{cwd: cwd, limit: 2})

    assert length(first_page) == 2
    assert is_binary(cursor)

    {:ok, %{sessions: second_page, next_cursor: nil}} =
      Tackle.list_sessions(%{cwd: cwd, limit: 2, cursor: cursor})

    assert length(second_page) == 1

    all_ids = Enum.map(first_page ++ second_page, & &1.session_id)
    assert Enum.sort(all_ids) == Enum.sort(ids)
  end

  test "rebuilds missing or corrupt summaries from journals", ctx do
    cwd = unique_cwd(ctx, "rebuild")
    session_id = create_session(ctx, cwd: cwd, title: "Rebuildable")

    {:ok, path} = Tackle.Session.Storage.summary_path(session_id, home: ctx.home)
    File.write!(path, "not an etf sidecar")

    Catalog.rebuild(home: ctx.home)

    assert {:ok, entry} = Catalog.get(session_id)
    assert entry.title == "Rebuildable"
    assert entry.last_indexed_seq > 0
  end

  test "marks stale projections and catches them up by sequence", ctx do
    cwd = unique_cwd(ctx, "stale")

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [cwd: cwd, title: "Stale"],
        root: [content: "a"]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, entry} = Catalog.get(snapshot.session_id)
    first_seq = entry.last_indexed_seq

    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "second")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, updated} = Catalog.get(snapshot.session_id)
    assert updated.last_indexed_seq > first_seq
  end

  defp create_session(ctx, opts) do
    root_opts = [content: Keyword.get(opts, :content, "answer")]
    session_opts = Keyword.take(opts, [:cwd, :title, :tags]) ++ [home: ctx.home]

    scope = start_durable_scope(home: ctx.home, session: session_opts, root: root_opts)
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello from #{opts[:title]}")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    stop_scope(scope.scope_ref)
    snapshot.session_id
  end

  defp unique_cwd(ctx, label) do
    Path.join(ctx.home, "cwd-#{label}-#{System.unique_integer([:positive])}")
  end
end
