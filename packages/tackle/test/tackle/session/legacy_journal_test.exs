defmodule Tackle.Session.LegacyJournalTest do
  @moduledoc false
  # Journals that earlier versions wrote must keep loading. Each fixture is
  # written as those versions wrote it (`Tackle.Test.LegacyJournals`), then
  # read with `Reader.read/2` and, where it means something, resumed.
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Usage
  alias Tackle.Runtime.ID
  alias Tackle.Session.Catalog
  alias Tackle.Session.Loader
  alias Tackle.Session.Projection
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage
  alias Tackle.Test.LegacyJournals

  setup do
    {:ok, home: tmp_home(), session_id: ID.generate()}
  end

  describe "a linear journal from before conversation trees" do
    setup ctx do
      LegacyJournals.write!(
        ctx.session_id,
        [home: ctx.home],
        LegacyJournals.pre_tree(ctx.session_id)
      )

      :ok
    end

    test "replays without parent links, content parts, or a tree flag", ctx do
      assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
      projection = replay.projection

      assert replay.status == :clean
      assert projection.tree_enabled? == false
      assert projection.model_ref == LegacyJournals.model()
      assert projection.thinking == nil
      assert Enum.map(projection.messages, & &1["id"]) == ~w(u1 a1 t1 a2 u2 a3)
      assert Projection.uncertain_tools(projection) == []

      # The compaction chains by position: its summary replaces the first turn.
      assert [%{"compaction_id" => "compaction-1"}] = projection.compactions
      assert Enum.map(projection.model_messages, & &1["id"]) == ~w(summary-1 u2 a3)
    end

    test "decodes usage stored under the struct's field names and string-keyed tool calls",
         ctx do
      {:ok, projection} = Reader.projection(ctx.session_id, home: ctx.home)
      %{state: state} = load!(projection)
      messages = Map.new(state.messages, &{&1.id, &1})

      assert %Message{tool_calls: [%Call{id: "call-1", name: "bash", arguments: arguments}]} =
               messages["a1"]

      assert arguments == %{"cmd" => "ls"}
      assert %Message{tool_call_id: "call-1", tool_name: "bash"} = messages["t1"]

      assert %Usage{
               input_tokens: 120,
               output_tokens: 30,
               cache_read_tokens: 64,
               total_tokens: 214,
               currency: "USD",
               provider: "test",
               raw: %{"prompt_tokens" => 184, "completion_tokens" => 30}
             } = messages["a2"].token_usage
    end

    test "resumes from the flat layout and continues the conversation", ctx do
      scope =
        start_durable_scope(
          home: ctx.home,
          session: [session_id: ctx.session_id],
          root: [content: "resumed answer"]
        )

      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      assert snapshot.session_id == ctx.session_id
      assert Enum.map(snapshot.agent_state.messages, & &1.id) == ~w(u1 a1 t1 a2 u2 a3)

      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "one more")
      assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
      stop_scope(scope.scope_ref)

      assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
      assert replay.status == :clean

      assert replay.projection.messages |> Enum.map(& &1["content"]) |> Enum.take(-2) == [
               "one more",
               "resumed answer"
             ]
    end

    test "is listed beside project sessions", ctx do
      project = Path.join(ctx.home, "project")
      other = ID.generate()

      LegacyJournals.write!(
        other,
        [home: ctx.home, cwd: project],
        LegacyJournals.closed_then_resumed(other, project)
      )

      assert {:ok, locations} = Storage.list_session_locations(home: ctx.home)
      assert {ctx.session_id, [home: ctx.home]} in locations

      assert %{indexed: 2, skipped: 0} = Catalog.rebuild(home: ctx.home)
      assert {:ok, %{status: :clean, message_count: 6}} = Catalog.get(ctx.session_id)
      assert {:ok, %{cwd: ^project}} = Catalog.get(other)
    end
  end

  describe "a legacy session.closed" do
    test "followed by more turns is a clean session that resumes", ctx do
      LegacyJournals.write!(
        ctx.session_id,
        [home: ctx.home],
        LegacyJournals.closed_then_resumed(ctx.session_id)
      )

      assert {:ok, %{status: :clean, projection: projection}} =
               Reader.read(ctx.session_id, home: ctx.home)

      assert projection.closed_at == "2026-01-01T00:00:00Z"
      assert projection.active_turn == nil

      assert %{"turn-1" => %{status: :completed}, "turn-2" => %{status: :completed}} =
               projection.turns

      scope =
        start_durable_scope(
          home: ctx.home,
          session: [session_id: ctx.session_id],
          root: [content: "after the close"]
        )

      {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "third")
      assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, state}}, 5_000

      assert state.messages |> Enum.map(& &1.content) |> Enum.take(-2) == [
               "third",
               "after the close"
             ]
    end

    test "written during a turn leaves that turn interrupted", ctx do
      LegacyJournals.write!(
        ctx.session_id,
        [home: ctx.home],
        LegacyJournals.closed_during_turn(ctx.session_id)
      )

      assert {:ok, %{status: :interrupted, projection: projection}} =
               Reader.read(ctx.session_id, home: ctx.home)

      assert projection.closed_at == "2026-01-01T00:00:00Z"
      assert %{turn_id: "turn-1"} = projection.active_turn
    end
  end

  test "a fork replays with its lineage after its parent is gone", ctx do
    parent_id = ID.generate()

    LegacyJournals.write!(
      ctx.session_id,
      [home: ctx.home],
      LegacyJournals.forked(ctx.session_id, parent_id, 4)
    )

    assert {:ok, %{status: :clean, projection: projection}} =
             Reader.read(ctx.session_id, home: ctx.home)

    assert projection.parent == %{"session_id" => parent_id, "seq" => 4}
    assert projection.title == "Forked work"
    assert Enum.map(projection.messages, & &1["content"]) == ["shared start", "shared answer"]

    assert %{indexed: 1} = Catalog.rebuild(home: ctx.home)
    assert {:ok, %{parent_session_id: ^parent_id}} = Catalog.get(ctx.session_id)
  end

  defp load!(projection) do
    {:ok, loaded} = Loader.load(projection, config())
    loaded
  end
end
