defmodule Tackle.Lib.Compaction.InputTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction.Checkpoint
  alias Tackle.Lib.Compaction.Input
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool

  defp text(tokens), do: String.duplicate("x", tokens * 4)

  test "returns messages that fit unchanged" do
    messages = [Message.user(text(100)), Message.assistant(content: text(100))]

    assert Input.fit(messages, 200) == {:ok, messages, 0}
  end

  test "shortens the largest messages to one size and keeps small ones verbatim" do
    small = Message.user(text(50))
    huge = Message.tool_result("c1", "read", text(5_000))
    call = Message.assistant(tool_calls: [%{id: "c1", name: "read", arguments: %{"p" => "a"}}])

    assert {:ok, [^small, ^call, shortened], 1} = Input.fit([small, call, huge], 1_000)
    assert ContextUsage.estimate_messages([small, call, shortened]) <= 1_000
    assert shortened.tool_call_id == "c1"
    assert shortened.content =~ "characters omitted for compaction"
    assert String.starts_with?(shortened.content, "xxxx")
    assert String.ends_with?(shortened.content, "xxxx")
  end

  test "never shortens an earlier checkpoint" do
    checkpoint = Checkpoint.message("cp", text(300))
    huge = Message.user(text(5_000))

    assert {:ok, [^checkpoint, shortened], 1} = Input.fit([checkpoint, huge], 1_000)
    assert ContextUsage.estimate_message(shortened) < 1_000
  end

  test "truncates large tool-call arguments but keeps the call's id and name" do
    call =
      Message.assistant(
        tool_calls: [%{id: "w1", name: "write", arguments: %{"content" => text(5_000)}}],
        provider_state: %{"output" => text(100)}
      )

    result = Message.tool_result("w1", "write", "ok")

    assert {:ok, [shortened, ^result], 1} = Input.fit([call, result], 1_000)
    assert [%Tool.Call{id: "w1", name: "write", arguments: arguments}] = shortened.tool_calls
    assert %{"truncated_arguments" => json} = arguments
    assert json =~ "characters omitted for compaction"
    assert shortened.provider_state == nil
  end

  test "replaces content parts with a note" do
    image = Tool.Content.image("image/png", String.duplicate("A", 100))

    message =
      Message.tool_result("c1", "read", text(2_000), parts: [image, image, image])

    assert {:ok, [shortened], 1} = Input.fit([message], 500)
    assert shortened.parts == []
    assert shortened.content =~ "3 content part(s)"
  end

  test "reports a budget too small to keep anything useful" do
    messages = for _ <- 1..10, do: Message.user(text(500))

    assert Input.fit(messages, 100) == {:error, :summary_input_too_large}
  end
end
