defmodule Tackle.Session.LogTest do
  use ExUnit.Case, async: true

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

  test "writing accepts only the current versions" do
    assert :ok = Log.validate_commit(commit([appended(1, %{})]), @session_id, 1)

    assert {:error, {:unsupported_event_version, "message.appended", 2}} =
             Log.validate_commit(commit([appended(2, %{})]), @session_id, 1)
  end
end
