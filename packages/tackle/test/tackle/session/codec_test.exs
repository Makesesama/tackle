defmodule Tackle.Session.CodecTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Usage
  alias Tackle.Session.Codec

  describe "validate/1" do
    test "accepts constrained plain data" do
      value = %{
        "string" => "hello",
        "bytes" => <<0, 255, 1>>,
        "int" => 42,
        "float" => 1.5,
        "bool" => true,
        "nil" => nil,
        "list" => [1, "two", %{"three" => 3}]
      }

      assert :ok = Codec.validate(value)
    end

    test "rejects runtime references and executable terms" do
      assert {:error, {:forbidden_term, :pid}} = Codec.validate(self())
      assert {:error, {:forbidden_term, :reference}} = Codec.validate(make_ref())
      assert {:error, {:forbidden_term, :function}} = Codec.validate(fn -> :ok end)
      assert {:error, {:forbidden_term, :tuple}} = Codec.validate({:a, :b})
      assert {:error, {:forbidden_term, :atom, :some_atom}} = Codec.validate(:some_atom)
      assert {:error, {:forbidden_term, :struct, DateTime}} = Codec.validate(DateTime.utc_now())
    end

    test "rejects non-binary map keys and invalid key encoding" do
      assert {:error, {:invalid_key, 1}} = Codec.validate(%{1 => "value"})
      assert {:error, {:invalid_key_encoding, <<255>>}} = Codec.validate(%{<<255>> => "value"})
    end

    test "rejects nested forbidden terms" do
      assert {:error, {:forbidden_term, :pid}} = Codec.validate(%{"deep" => [%{"x" => self()}]})
    end

    test "rejects recursion depth beyond the limit" do
      deep = Enum.reduce(1..40, "leaf", fn _index, acc -> %{"next" => acc} end)
      assert {:error, {:too_deep, _depth}} = Codec.validate(deep)
    end

    test "rejects an oversized binary" do
      binary = :binary.copy(<<0>>, 9 * 1024 * 1024)
      assert {:error, {:binary_too_large, _size}} = Codec.validate(binary)
    end
  end

  describe "encode_message/1 and decode_message/1" do
    test "round-trips a user message" do
      message = Message.user("hello world")

      assert {:ok, data} = Codec.encode_message(message)
      assert data["role"] == "user"
      assert data["content"] == "hello world"

      assert {:ok, decoded} = Codec.decode_message(data)
      assert decoded.id == message.id
      assert decoded.role == :user
      assert decoded.content == "hello world"
      assert decoded.timestamp == message.timestamp
    end

    test "round-trips an assistant message with tool calls, usage, and provider state" do
      message =
        Message.assistant(
          content: nil,
          thinking: "reasoning",
          model: "test/echo",
          provider_state: %{"provider" => "test", "output" => [%{"type" => "message"}]},
          token_usage: %{input_tokens: 10, output_tokens: 5, cache_read_tokens: 2},
          tool_calls: [
            %{id: "call-1", name: "read", arguments: %{"path" => "lib/tackle.ex"}}
          ]
        )

      assert {:ok, data} = Codec.encode_message(message)
      assert [%{"id" => "call-1", "name" => "read"}] = data["tool_calls"]
      assert data["token_usage"]["input_tokens"] == 10
      assert data["provider_state"]["provider"] == "test"

      assert {:ok, decoded} = Codec.decode_message(data)
      assert decoded.role == :assistant
      assert decoded.thinking == "reasoning"
      assert decoded.provider_state == message.provider_state
      assert %Usage{input_tokens: 10, output_tokens: 5} = decoded.token_usage

      assert [%Call{id: "call-1", name: "read", arguments: %{"path" => "lib/tackle.ex"}}] =
               decoded.tool_calls
    end

    test "round-trips canonical usage, keeping the provider report as raw" do
      usage =
        Usage.new(
          prompt_tokens: 120,
          cache_read_tokens: 100,
          output_tokens: 8,
          cost: 0.5,
          cost_breakdown: %{input: 0.25, output: 0.25, total: 0.5, estimated: true},
          cost_estimated: true,
          currency: "USD",
          model: "echo",
          provider: "test",
          raw: %{"prompt_tokens" => 120, "prompt_tokens_details" => %{"cached_tokens" => 100}}
        )

      message = Message.assistant(content: "ok", token_usage: usage)

      assert {:ok, data} = Codec.encode_message(message)
      assert data["token_usage"]["raw"] == usage.raw
      assert {:ok, decoded} = Codec.decode_message(data)
      assert decoded.token_usage == usage

      assert {:ok, ^data} = Codec.encode_message(decoded)
    end

    test "round-trips Call structs through their stored maps" do
      calls = [
        %Call{id: "call-1", name: "read", arguments: %{"path" => "a"}, raw: %{"provider" => 1}},
        %Call{id: nil, name: "bash", arguments: %{cmd: "ls"}}
      ]

      assert {:ok, data} = Codec.encode_message(Message.assistant(tool_calls: calls))

      assert data["tool_calls"] == [
               %{"id" => "call-1", "name" => "read", "arguments" => %{"path" => "a"}},
               %{"id" => nil, "name" => "bash", "arguments" => %{"cmd" => "ls"}}
             ]

      assert {:ok, decoded} = Codec.decode_message(data)

      assert [
               %Call{id: "call-1", name: "read", arguments: %{"path" => "a"}},
               %Call{id: nil, name: "bash", arguments: %{"cmd" => "ls"}}
             ] = decoded.tool_calls

      assert {:ok, ^data} = Codec.encode_message(decoded)
    end

    test "decodes stored tool calls with string or atom keys into Call structs" do
      data = %{
        "role" => "assistant",
        "tool_calls" => [
          %{"id" => "call-1", "name" => "read", "arguments" => %{"path" => "a"}},
          %{id: "call-2", name: "bash"}
        ]
      }

      assert {:ok, %Message{tool_calls: calls}} = Codec.decode_message(data)

      assert [
               %Call{id: "call-1", name: "read", arguments: %{"path" => "a"}},
               %Call{id: "call-2", name: "bash", arguments: %{}}
             ] = calls
    end

    test "decodes a message without stored tool calls to none" do
      assert {:ok, %Message{tool_calls: []}} = Codec.decode_message(%{"role" => "user"})

      assert {:ok, %Message{tool_calls: []}} =
               Codec.decode_message(%{"role" => "assistant", "tool_calls" => []})
    end

    test "returns an explicit error for a stored tool call that does not normalize" do
      call = %{"id" => "call-1", "arguments" => %{}}

      assert {:error, {:invalid_tool_call, ^call, :malformed_tool_call}} =
               Codec.decode_message(%{"role" => "assistant", "tool_calls" => [call]})

      assert {:error, {:invalid_tool_calls, "nope"}} =
               Codec.decode_message(%{"role" => "assistant", "tool_calls" => "nope"})
    end

    test "round-trips a tool result message" do
      message = Message.tool_result("call-1", "read", "file contents")

      assert {:ok, data} = Codec.encode_message(message)
      assert {:ok, decoded} = Codec.decode_message(data)
      assert decoded.role == :tool
      assert decoded.tool_call_id == "call-1"
      assert decoded.tool_name == "read"
    end

    test "round-trips a tool result message with image content parts" do
      message =
        Message.tool_result("call-1", "read", "Read image shot.png (image/png).",
          parts: [%{"type" => "image", "media_type" => "image/png", "data" => "aGVsbG8="}]
        )

      assert {:ok, data} = Codec.encode_message(message)

      assert data["parts"] == [
               %{"type" => "image", "media_type" => "image/png", "data" => "aGVsbG8="}
             ]

      assert {:ok, decoded} = Codec.decode_message(data)
      assert decoded.content == "Read image shot.png (image/png)."
      assert decoded.parts == message.parts
    end

    test "decodes a tool result without parts to nil parts" do
      message = Message.tool_result("call-1", "read", "file contents")

      assert {:ok, data} = Codec.encode_message(message)
      assert data["parts"] == nil

      assert {:ok, decoded} = Codec.decode_message(data)
      assert decoded.parts == nil
    end

    test "rejects a message carrying a pid in provider state" do
      message = Message.assistant(content: "hi", provider_state: %{"pid" => self()})
      assert {:error, {:invalid_message, {:forbidden_term, :pid}}} = Codec.encode_message(message)
    end

    test "returns an explicit error for a malformed durable message" do
      assert {:error, {:invalid_role, "system"}} = Codec.decode_message(%{"role" => "system"})

      assert {:error, {:invalid_timestamp, "not-a-date", _}} =
               Codec.decode_message(%{"role" => "user", "timestamp" => "not-a-date"})
    end
  end
end
