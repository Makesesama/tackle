defmodule Tackle.Narration.DigestTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Event
  alias Tackle.Narration.Digest

  test "keeps the task and profile, bounded and filled in only once" do
    digest = Digest.new(nil, nil)
    assert Digest.state(digest)["task"] == nil

    long = String.duplicate("é", 500)
    digest = digest |> Digest.put_task(long) |> Digest.put_profile("explorer")

    task = Digest.state(digest)["task"]
    assert String.valid?(task)
    assert String.length(task) == 401
    assert String.ends_with?(task, "…")

    digest = digest |> Digest.put_task("other") |> Digest.put_profile("other")
    assert Digest.state(digest)["task"] == task
    assert Digest.state(digest)["profile"] == "explorer"

    assert Digest.state(Digest.new("   ", "")) |> Map.take(["task", "profile"]) ==
             %{"task" => nil, "profile" => nil}
  end

  test "summarizes the last tool calls by name, short argument, and outcome" do
    digest =
      Enum.reduce(1..8, Digest.new("task"), fn i, digest ->
        digest
        |> Digest.observe(tool_start("c#{i}", "read", %{"path" => "lib/file_#{i}.ex"}))
        |> Digest.observe(tool_end("c#{i}"))
      end)

    lines = Digest.state(digest)["recent_tool_calls"]
    assert ["read lib/file_3.ex (ok)", _, _, _, _, "read lib/file_8.ex (ok)"] = lines

    digest =
      digest
      |> Digest.observe(
        tool_start("b1", "bash", %{"command" => "mix test\nsecond line", "timeout" => 5})
      )
      |> Digest.observe(tool_start("g1", "grep", %{pattern: "defmodule"}))
      |> Digest.observe(tool_start("x1", "think", %{"note" => "x"}))
      |> Digest.observe(
        Event.new(:tool_execution_end, %{tool_call_id: "b1", status: :failed, error: "boom"})
      )
      |> Digest.observe(
        Event.new(:tool_error, %{tool_call_id: "b1", name: "bash", error: "boom"})
      )

    assert Enum.take(Digest.state(digest)["recent_tool_calls"], -3) == [
             "bash mix test (error)",
             "grep defmodule (running)",
             "think (running)"
           ]

    assert Digest.state(digest)["errors"] == ["bash: boom"]
  end

  test "keeps a bounded tail of assistant text, ignoring reasoning and tool input" do
    digest =
      Digest.new("task")
      |> Digest.observe(delta("Looking at the session module. "))
      |> Digest.observe(delta("secret thoughts", :reasoning))
      |> Digest.observe(delta("{\"path\"", :tool_input))

    assert Digest.state(digest)["recent_assistant_text"] == "Looking at the session module."

    digest = Digest.observe(digest, Event.new(:message_start, %{role: :assistant}))
    digest = Digest.observe(digest, delta("Next message"))

    assert Digest.state(digest)["recent_assistant_text"] ==
             "Looking at the session module. \nNext message"

    digest = Digest.observe(digest, delta(String.duplicate("ü", 400)))
    text = Digest.state(digest)["recent_assistant_text"]
    assert String.valid?(text)
    assert String.length(text) == 300
  end

  test "strips terminal control sequences and invalid bytes" do
    digest =
      Digest.new("\e[31mfix\e[0m the <<build>>")
      |> Digest.observe(delta("\e[1mbold\e[0m and \a bell " <> <<0xFF>>))
      |> Digest.observe(tool_start("c1", "bash", %{"command" => "\e]0;title\amake"}))

    state = Digest.state(digest)
    assert state["task"] == "fix the <<build>>"
    assert state["recent_assistant_text"] == "bold and  bell"
    assert state["recent_tool_calls"] == ["bash make (running)"]
  end

  test "records the last errors once each" do
    digest =
      Enum.reduce(1..5, Digest.new(), fn i, digest ->
        digest
        |> Digest.observe(Event.new(:error, %{error: "failure #{i}"}))
        |> Digest.observe(Event.new(:error, %{error: "failure #{i}"}))
      end)

    assert Digest.state(digest)["errors"] == ["failure 3", "failure 4", "failure 5"]

    digest = Digest.observe(digest, Event.new(:error, %{error: {:http, 500}}))
    assert List.last(Digest.state(digest)["errors"]) == "{:http, 500}"
  end

  test "records each failed call's error once, also when concurrent calls interleave" do
    failed = fn id, error ->
      Event.new(:tool_execution_end, %{tool_call_id: id, status: :failed, error: error})
    end

    tool_error = &Event.new(:tool_error, %{tool_call_id: &1, name: "bash", error: &2})

    digest =
      Digest.new()
      |> Digest.observe(tool_start("a", "bash", %{"command" => "make a"}))
      |> Digest.observe(tool_start("b", "bash", %{"command" => "make b"}))
      |> Digest.observe(failed.("a", "a failed"))
      |> Digest.observe(failed.("b", "b failed"))
      |> Digest.observe(tool_error.("a", "a failed"))
      |> Digest.observe(tool_error.("b", "b failed"))

    assert Digest.state(digest)["errors"] == ["bash: a failed", "bash: b failed"]

    # A call the digest does not list adds nothing.
    assert Digest.observe(digest, tool_error.("unknown", "lost")) == digest
  end

  test "tracks changes since the digest was taken and remembers the last narration" do
    digest = Digest.new("task", "explorer")
    refute Digest.changed?(digest)

    # Events without anything to narrate change nothing.
    digest = Digest.observe(digest, Event.new(:usage, %{usage: nil}))
    digest = Digest.observe(digest, Event.new(:step_start, %{iteration: 1}))
    refute Digest.changed?(digest)

    digest = Digest.observe(digest, tool_start("c1", "read", %{"path" => "a.ex"}))
    assert Digest.changed?(digest)

    digest = Digest.taken(digest)
    refute Digest.changed?(digest)

    # Settling an already settled call is not a change.
    digest = digest |> Digest.observe(tool_end("c1"))
    assert Digest.changed?(digest)
    digest = digest |> Digest.taken() |> Digest.observe(tool_end("c1"))
    refute Digest.changed?(digest)

    digest = Digest.narrated(digest, "reading a.ex")
    assert Digest.state(digest)["previous_status"] == "reading a.ex"
    refute Digest.changed?(digest)
    assert Digest.changed?(Digest.changed(digest))
  end

  test "renders a JSON-compatible state" do
    digest =
      Digest.new("task", "explorer")
      |> Digest.observe(tool_start("c1", "read", %{"path" => "a.ex"}))

    assert {:ok, _decoded} = digest |> Digest.state() |> JSON.encode!() |> JSON.decode()
  end

  defp tool_start(id, name, arguments),
    do: Event.new(:tool_start, %{tool_call_id: id, name: name, arguments: arguments})

  defp tool_end(id), do: Event.new(:tool_end, %{tool_call_id: id, name: "tool"})

  defp delta(text, field \\ nil) do
    data = %{delta: text}
    data = if field, do: Map.put(data, :field, field), else: data
    Event.new(:message_delta, data)
  end
end
