defmodule Tackle.Session.LogTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tree.Change
  alias Tackle.Session.Codec
  alias Tackle.Session.Log

  @session_id "session-1"

  # A schema in which `message.appended` reached version 3: version 1 kept the
  # message under "msg", version 2 under "message" without a "parent_id".
  defp evolved_schema do
    %{
      versions: Map.put(Log.schema().versions, "message.appended", 3),
      upcasters: %{
        {"message.appended", 1} => fn data ->
          data |> Map.delete("msg") |> Map.put("message", data["msg"])
        end,
        {"message.appended", 2} => &Map.put_new(&1, "parent_id", nil)
      }
    }
  end

  defp commit(events) do
    Log.commit(
      session_id: @session_id,
      seq: 1,
      commit_id: "commit-1",
      written_at: "2026-01-01T00:00:00Z",
      events: events
    )
  end

  defp appended(version, data), do: Log.event("message.appended", data, version: version)

  test "reads an older event version by upcasting it one version at a time" do
    stored = commit([appended(1, %{"msg" => %{"role" => "user", "content" => "hi"}})])

    assert {:ok, %{"events" => [event]}} =
             Log.read_commit(stored, @session_id, 1, evolved_schema())

    assert event["version"] == 3

    assert event["data"] == %{
             "message" => %{"role" => "user", "content" => "hi"},
             "parent_id" => nil
           }
  end

  test "reads the current version unchanged" do
    data = %{"message" => %{"role" => "user"}, "parent_id" => "entry-1"}
    stored = commit([appended(3, data)])

    assert {:ok, %{"events" => [%{"version" => 3, "data" => ^data}]}} =
             Log.read_commit(stored, @session_id, 1, evolved_schema())
  end

  test "rejects a version newer than the current one" do
    stored = commit([appended(4, %{})])

    assert {:error, {:unsupported_event_version, "message.appended", 4}} =
             Log.read_commit(stored, @session_id, 1, evolved_schema())
  end

  test "rejects an older version that has no upcaster" do
    schema = %{
      evolved_schema()
      | upcasters: Map.delete(evolved_schema().upcasters, {"message.appended", 2})
    }

    stored = commit([appended(1, %{"msg" => %{}})])

    assert {:error, {:unsupported_event_version, "message.appended", 2}} =
             Log.read_commit(stored, @session_id, 1, schema)
  end

  test "rejects a version below 1" do
    assert {:error, {:unsupported_event_version, "message.appended", 0}} =
             Log.read_commit(commit([appended(0, %{})]), @session_id, 1, evolved_schema())
  end

  test "keeps unknown optional events and rejects unknown required ones" do
    optional = Log.event("plugin.note", %{"text" => "kept"}, required: false, version: 7)

    assert {:ok, %{"events" => [^optional]}} = Log.read_commit(commit([optional]), @session_id, 1)

    required = Log.event("plugin.note", %{}, version: 7)

    assert {:error, {:unsupported_required_event, "plugin.note", 7}} =
             Log.read_commit(commit([required]), @session_id, 1)
  end

  test "rejects event data that is not a map" do
    event = Log.event("turn.started", "not a map")

    assert {:error, {:invalid_event_data, "turn.started", :not_a_map}} =
             Log.read_commit(commit([event]), @session_id, 1)
  end

  test "every event version above 1 has an upcaster from each older version" do
    %{versions: versions, upcasters: upcasters} = Log.schema()

    for {type, current} <- versions, from <- 1..(current - 1)//1 do
      assert Map.has_key?(upcasters, {type, from}), "no upcaster for #{type} v#{from}"
    end
  end

  test "names the events that settle a turn and the status each gives it" do
    for {type, status} <- [
          {"turn.completed", :completed},
          {"turn.errored", :errored},
          {"turn.cancelled", :cancelled},
          {"turn.crashed", :crashed},
          {"turn.abandoned", :abandoned}
        ] do
      assert Log.terminal_event?(type)
      assert Log.terminal_status(type) == status
    end

    for type <- ["turn.started", "session.closed", "message.appended", nil, :completed] do
      refute Log.terminal_event?(type)
      assert Log.terminal_status(type) == nil
    end
  end

  @at "2026-01-01T00:00:00Z"

  test "builds the events the journal writes, each readable at its current version" do
    message = %Message{id: "u1", role: :user, content: "hi", timestamp: ~U[2026-01-01 00:00:00Z]}
    header = Log.header(session_id: @session_id, created_at: @at, cwd: "/work")

    change = %Change{
      from_id: "a",
      to_id: "b",
      selected_id: "b",
      mode: :move,
      revision: 2
    }

    events = [
      Log.session_created(header, model_ref: "fake/model", title: "T", tree: true),
      Log.session_recovered(%{"recovered_items" => 1, "bad_bytes" => 0}),
      Log.session_forked("parent", 3, @at),
      Log.configuration_changed("fake/model", "high", @at),
      Log.metadata_changed(%{"title" => "T"}, @at),
      Log.turn_started("t1", :run, "hi", @at),
      Log.message_appended(message, :none),
      Log.message_appended(message, {:tree, nil}),
      Log.tool_started(%Call{id: "c1", name: "read", arguments: %{"path" => "a"}}, @at),
      Log.turn_settled("turn.completed", "t1", %{"status" => "completed"}, @at),
      Log.context_compacted(%{"compaction_id" => "k1"}),
      Log.tree_navigated(change, @at),
      Log.tree_enabled(@at)
    ]

    %{versions: versions} = Log.schema()

    for event <- events do
      assert event["version"] == Map.fetch!(versions, event["type"])
      assert event["required"] == true
      assert :ok = Codec.validate(event["data"])
      assert {:ok, %{"events" => [^event]}} = Log.read_commit(commit([event]), @session_id, 1)
    end
  end

  test "event builders shape their data" do
    message = %Message{id: "u1", role: :user, content: "hi", timestamp: ~U[2026-01-01 00:00:00Z]}

    assert Log.turn_started("t1", :repair, nil, @at)["data"] == %{
             "turn_id" => "t1",
             "operation" => "repair",
             "input" => nil,
             "started_at" => @at
           }

    # Without branching the parent is implied and not written.
    assert Log.message_appended(message, :none)["data"] == %{
             "message" => Codec.encode_message!(message)
           }

    assert Log.message_appended(message, {:tree, "p"})["data"]["parent_id"] == "p"

    for call <- [
          %Call{id: "c1", name: "read", arguments: %{"path" => "a"}},
          %{id: "c1", name: "read", arguments: %{path: "a"}}
        ] do
      assert Log.tool_started(call, @at)["data"] == %{
               "tool_call_id" => "c1",
               "name" => "read",
               "arguments" => %{"path" => "a"},
               "started_at" => @at
             }
    end

    assert Log.tool_started(%{"id" => "c2", "name" => "ls"}, @at)["data"]["arguments"] == %{}

    # A settlement names its turn and keeps a time the caller recorded.
    assert Log.turn_settled(
             "turn.errored",
             "t1",
             %{"turn_id" => "x", "settled_at" => "then"},
             @at
           )[
             "data"
           ] == %{"turn_id" => "t1", "settled_at" => "then"}

    assert Log.metadata_changed(%{"changed_at" => "then"}, @at)["data"] == %{
             "changed_at" => "then"
           }

    header = Log.header(session_id: @session_id, created_at: @at, cwd: "/work")

    assert Log.session_created(header, [])["data"] == %{
             "cwd" => "/work",
             "model_ref" => nil,
             "thinking" => nil,
             "title" => nil,
             "tags" => [],
             "tree" => false
           }
  end
end
