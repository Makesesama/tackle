defmodule Tackle.CLI.Output.SessionsTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Output
  alias Tackle.CLI.Output.Sessions

  @now DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  test "output policy enables color only when requested for human output" do
    human = Output.new(format: :human, color: :always)
    plain = Output.new(format: :plain, color: :always)
    json = Output.new(format: :json, color: :always)

    assert human.color?
    refute plain.color?
    refute json.color?
    assert plain(Output.style(human, :success, "ok")) == "ok"
    assert Output.style(plain, :success, "ok") == "ok"
  end

  test "human output is borderless, bounded, and keeps complete session ids" do
    page = %{sessions: [session(title: String.duplicate("long title ", 20))], next_cursor: nil}
    output = Output.new(format: :human, color: :never, width: 100)

    rendered = plain(Sessions.render(page, nil, output))

    assert rendered =~ "STATUS"
    assert rendered =~ "TITLE"
    assert rendered =~ "SESSION"
    assert rendered =~ "12345678-1234-1234-1234-123456789012"
    assert rendered =~ "…"
    refute rendered =~ "╭"

    assert rendered
           |> String.split("\n")
           |> Enum.all?(&(String.length(&1) <= 100))
  end

  test "narrow human output switches to stacked summaries" do
    page = %{sessions: [session()], next_cursor: nil}
    output = Output.new(format: :human, color: :never, width: 60)

    rendered = plain(Sessions.render(page, nil, output))

    assert rendered =~ "A useful session"
    assert rendered =~ "clean ·"
    assert rendered =~ "4 msgs"
    assert rendered =~ "12345678-1234-1234-1234-123456789012"
    refute rendered =~ "STATUS"
  end

  test "human output has useful empty and pagination messages" do
    output = Output.new(format: :human, color: :never, width: 100)

    assert plain(Sessions.render(%{sessions: [], next_cursor: nil}, nil, output)) ==
             "No sessions yet."

    assert plain(Sessions.render(%{sessions: [], next_cursor: nil}, "missing", output)) ==
             ~s(No sessions found for "missing".)

    rendered =
      plain(Sessions.render(%{sessions: [session()], next_cursor: "next"}, nil, output))

    assert rendered =~ "Showing the 1 most recent matches. Use --limit N to show more."
  end

  test "plain output is stable tab-separated data with exact timestamps and ids" do
    page = %{sessions: [session(title: "first\nsecond")], next_cursor: nil}
    output = Output.new(format: :plain, color: :always, width: 20)

    rendered = plain(Sessions.render(page, nil, output))

    assert rendered ==
             "updated\tstatus\tmessages\ttitle\tsession\n" <>
               "#{@now}\tclean\t4\tfirst second\t12345678-1234-1234-1234-123456789012"

    refute rendered =~ "\e["
  end

  test "json output returns structured pagination and session metadata" do
    page = %{sessions: [session()], next_cursor: "cursor-value"}
    output = Output.new(format: :json, color: :always)

    decoded = page |> Sessions.render(nil, output) |> plain() |> JSON.decode!()

    assert decoded["next_cursor"] == "cursor-value"
    assert [rendered] = decoded["sessions"]
    assert rendered["session_id"] == "12345678-1234-1234-1234-123456789012"
    assert rendered["updated_at"] == @now
    assert rendered["status"] == "clean"
    assert rendered["message_count"] == 4
    assert rendered["last_indexed_seq"] == 10
    assert rendered["title"] == "A useful session"
    assert rendered["preview"] == nil
  end

  test "empty plain and json output retain their machine-readable shape" do
    plain_output = Output.new(format: :plain, color: :never)
    json_output = Output.new(format: :json, color: :never)
    page = %{sessions: [], next_cursor: nil}

    assert plain(Sessions.render(page, nil, plain_output)) ==
             "updated\tstatus\tmessages\ttitle\tsession"

    assert page |> Sessions.render(nil, json_output) |> plain() |> JSON.decode!() == %{
             "next_cursor" => nil,
             "sessions" => []
           }
  end

  defp session(overrides \\ []) do
    Map.merge(
      %{
        session_id: "12345678-1234-1234-1234-123456789012",
        title: "A useful session",
        cwd: "/tmp/project",
        created_at: @now,
        updated_at: @now,
        status: :clean,
        model: "provider/model",
        tags: ["test"],
        message_count: 4,
        preview: nil,
        last_indexed_seq: 10,
        parent_session_id: nil
      },
      Map.new(overrides)
    )
  end

  defp plain(data), do: data |> Owl.Data.untag() |> IO.iodata_to_binary()
end
