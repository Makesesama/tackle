defmodule Tackle.Plugins.Codex.SSETest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.Codex.SSE

  test "flushes a terminal event without a final blank line" do
    wire =
      "data: " <>
        JSON.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "model" => "gpt-5.5-2026-09-01",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "done"}]
              }
            ]
          }
        })

    parser = SSE.new() |> SSE.push(wire, fn _event -> :ok end) |> SSE.finish(fn _event -> :ok end)

    assert {:ok, result} = SSE.result(parser, "gpt-5.5", nil)
    assert result.data == %{"content" => "done", "tool_calls" => []}
    assert result.model == "gpt-5.5-2026-09-01"
    assert result.provider_state["model"] == "gpt-5.5"
  end

  test "rejects a stream without a terminal response event" do
    parser = SSE.new() |> SSE.push(~s|data: {"type":"response.created"}\n\n|, fn _ -> :ok end)

    assert {:error, :stream_ended_without_terminal_event} =
             parser |> SSE.finish(fn _ -> :ok end) |> SSE.result("gpt-5.5", nil)
  end

  test "keeps multiple terminal message items in output order" do
    wire =
      "data: " <>
        JSON.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "first "}]
              },
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "second"}]
              }
            ]
          }
        }) <>
        "\n\n"

    parser = SSE.new() |> SSE.push(wire, fn _event -> :ok end) |> SSE.finish(fn _event -> :ok end)

    assert {:ok, %{data: %{"content" => "first second"}}} =
             SSE.result(parser, "gpt-5.5", nil)
  end

  test "streams refusal deltas as text" do
    callback = fn event -> send(self(), {:event, event}) end

    wire =
      "data: " <>
        JSON.encode!(%{
          "type" => "response.refusal.delta",
          "output_index" => 0,
          "delta" => "cannot comply"
        }) <>
        "\n\n" <>
        "data: " <>
        JSON.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "refusal", "refusal" => "cannot comply"}]
              }
            ]
          }
        }) <>
        "\n\n"

    parser = SSE.new() |> SSE.push(wire, callback) |> SSE.finish(callback)

    assert_receive {:event, %{type: :text_delta, delta: "cannot comply"}}

    assert {:ok, %{data: %{"content" => "cannot comply"}}} =
             SSE.result(parser, "gpt-5.5", nil)
  end

  test "keeps reasoning summary parts on separate lines and strips markdown emphasis" do
    callback = fn event -> send(self(), {:event, event}) end

    wire =
      Enum.map_join(
        [
          %{
            "type" => "response.reasoning_summary_text.delta",
            "output_index" => 0,
            "summary_index" => 0,
            "delta" => "**First thought**"
          },
          %{
            "type" => "response.reasoning_summary_text.delta",
            "output_index" => 0,
            "summary_index" => 1,
            "delta" => "**Second thought**"
          },
          %{
            "type" => "response.completed",
            "response" => %{"status" => "completed", "output" => []}
          }
        ],
        fn event -> "data: " <> JSON.encode!(event) <> "\n\n" end
      )

    parser = SSE.new() |> SSE.push(wire, callback) |> SSE.finish(callback)

    assert_receive {:event, %{type: :reasoning_delta, delta: "First thought"}}
    assert_receive {:event, %{type: :reasoning_delta, delta: "\n\nSecond thought"}}

    assert {:ok, %{data: %{"thinking" => "First thought\n\nSecond thought"}}} =
             SSE.result(parser, "gpt-5.5", nil)
  end

  test "decodes structured response content when a schema was requested" do
    wire =
      "data: " <>
        JSON.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "{\"answer\":42}"}]
              }
            ]
          }
        }) <>
        "\n\n"

    parser = SSE.new() |> SSE.push(wire, fn _ -> :ok end) |> SSE.finish(fn _ -> :ok end)

    assert {:ok, %{data: %{"answer" => 42}}} =
             SSE.result(parser, "gpt-5.5", answer: [type: :integer])
  end
end
