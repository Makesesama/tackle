defmodule Tackle.Plugins.Anthropic.ConvertTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.Anthropic.Convert

  @model "claude-opus-5-5"

  test "pairs tool_use with tool_result and caches the final user block" do
    messages = [
      %{role: :user, content: "hi"},
      %{
        role: :assistant,
        content: nil,
        tool_calls: [
          %{
            id: "t1",
            type: "function",
            function: %{name: "read", arguments: "{\"path\":\"a\"}"}
          }
        ]
      },
      %{role: :tool, tool_call_id: "t1", name: "read", content: "file body"}
    ]

    assert {:ok, params} = Convert.messages(messages, @model, false)

    assert [
             %{"role" => "user", "content" => "hi"},
             %{"role" => "assistant", "content" => [tool_use]},
             %{"role" => "user", "content" => [tool_result]}
           ] = params

    assert tool_use == %{
             "type" => "tool_use",
             "id" => "t1",
             "name" => "read",
             "input" => %{"path" => "a"}
           }

    assert tool_result == %{
             "type" => "tool_result",
             "tool_use_id" => "t1",
             "content" => "file body",
             "cache_control" => %{"type" => "ephemeral"}
           }
  end

  test "namespaces non-Claude-Code tool names under OAuth" do
    assert {:ok, [tool]} =
             Convert.tools(
               [
                 %{
                   name: "my_tool",
                   description: "Does a thing",
                   input_schema: [q: [type: :string, required: true]]
                 }
               ],
               true
             )

    assert tool["name"] == "mcp__tackle__my_tool"
    assert tool["description"] == "Does a thing"

    assert tool["input_schema"] == %{
             "type" => "object",
             "properties" => %{"q" => %{"type" => "string"}},
             "required" => ["q"]
           }

    assert {:ok, [known]} =
             Convert.tools(
               [%{name: "read", description: "Read", input_schema: []}],
               true
             )

    assert known["name"] == "Read"

    assert Convert.tool_name_map(
             [%{name: "read", description: "r", input_schema: []}],
             true
           ) == %{"Read" => "read"}
  end

  test "closes orphan tool calls with a synthetic result before the next user turn" do
    messages = [
      %{
        role: :assistant,
        content: "ok",
        tool_calls: [%{id: "t1", function: %{name: "bash", arguments: "{}"}}]
      },
      %{role: :user, content: "next"}
    ]

    assert {:ok, params} = Convert.messages(messages, @model, false)

    assert [%{"role" => "assistant"}, synthetic, %{"role" => "user", "content" => "next"}] =
             params

    assert synthetic == %{
             "role" => "user",
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "t1",
                 "content" => "No result provided",
                 "is_error" => true
               }
             ]
           }
  end

  test "replays stored provider_state blocks for the same provider, model, and auth mode" do
    blocks = [
      %{"type" => "thinking", "thinking" => "why", "signature" => "sig"},
      %{"type" => "tool_use", "id" => "t1", "name" => "Read", "input" => %{"path" => "a"}}
    ]

    message = %{
      role: :assistant,
      content: "ignored",
      tool_calls: [%{id: "t1", function: %{name: "read", arguments: "{}"}}],
      provider_state: %{
        "provider" => "anthropic",
        "model" => @model,
        "oauth" => true,
        "content_blocks" => blocks
      }
    }

    assert {:ok, [%{"role" => "assistant", "content" => ^blocks}]} =
             Convert.messages([message], @model, true)

    other_model = %{
      message
      | provider_state: %{message.provider_state | "model" => "claude-sonnet-5"}
    }

    assert {:ok, [%{"role" => "assistant", "content" => synthesized}]} =
             Convert.messages([other_model], @model, true)

    refute Enum.any?(synthesized, &(&1["type"] == "thinking"))
    assert Enum.any?(synthesized, &(&1["type"] == "tool_use"))

    other_auth = %{message | provider_state: %{message.provider_state | "oauth" => false}}

    assert {:ok, [%{"role" => "assistant", "content" => synthesized_auth}]} =
             Convert.messages([other_auth], @model, true)

    refute Enum.any?(synthesized_auth, &(&1["type"] == "thinking"))
  end

  test "keeps images in tool results" do
    messages = [
      %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "t1", function: %{name: "read", arguments: "{}"}}]
      },
      %{
        role: :tool,
        tool_call_id: "t1",
        name: "read",
        content: [
          %{"type" => "text", "text" => "see attached"},
          %{"type" => "image", "media_type" => "image/png", "data" => "AAA"}
        ]
      }
    ]

    assert {:ok, [_assistant, %{"role" => "user", "content" => [tool_result]}]} =
             Convert.messages(messages, @model, false)

    assert tool_result["cache_control"] == %{"type" => "ephemeral"}

    assert tool_result["content"] == [
             %{"type" => "text", "text" => "see attached"},
             %{
               "type" => "image",
               "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "AAA"}
             }
           ]
  end

  test "rejects unknown roles and malformed tool calls" do
    assert {:error, {:unsupported_message_role, :system}} =
             Convert.messages([%{role: :system, content: "x"}], @model, false)

    assert {:error, :invalid_tool_call} =
             Convert.messages(
               [%{role: :assistant, content: nil, tool_calls: [%{id: "t1"}]}],
               @model,
               false
             )
  end
end
