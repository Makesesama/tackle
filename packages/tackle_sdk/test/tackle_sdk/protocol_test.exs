defmodule Tackle.SDK.ProtocolTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Event
  alias Tackle.SDK.Protocol

  describe "decode/1" do
    test "decodes a request with params and id" do
      line = ~S({"jsonrpc":"2.0","id":1,"method":"session/new","params":{"model":"fake/echo"}})

      assert {:ok, %{method: "session/new", id: 1, params: %{"model" => "fake/echo"}}} =
               Protocol.decode(line)
    end

    test "defaults missing params to an empty map" do
      line = ~S({"jsonrpc":"2.0","id":2,"method":"tools/list"})

      assert {:ok, %{params: %{}, id: 2, method: "tools/list"}} = Protocol.decode(line)
    end

    test "treats a missing id as a client notification" do
      line = ~S({"jsonrpc":"2.0","method":"initialized"})

      assert {:ok, %{id: nil, method: "initialized"}} = Protocol.decode(line)
    end

    test "ignores blank lines" do
      assert Protocol.decode("   \n") == :ignore
    end

    test "rejects invalid JSON with the parse error code" do
      assert {:error, -32700, _message} = Protocol.decode("{not json")
    end

    test "rejects frames that are not JSON-RPC 2.0 requests" do
      assert {:error, -32600, _message} = Protocol.decode(~S({"id":1,"method":"x"}))
      assert {:error, -32600, _message} = Protocol.decode(~S({"jsonrpc":"1.0","method":"x"}))
      assert {:error, -32600, _message} = Protocol.decode(~S({"jsonrpc":"2.0","id":1}))
    end
  end

  describe "frame building" do
    test "response/2 and error_response/3 produce JSON-RPC 2.0 frames" do
      assert Protocol.response(7, %{"sessionId" => "s1"}) ==
               %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"sessionId" => "s1"}}

      assert Protocol.error_response(7, -32602, "bad params") ==
               %{
                 "jsonrpc" => "2.0",
                 "id" => 7,
                 "error" => %{"code" => -32602, "message" => "bad params"}
               }
    end

    test "error_response/4 includes data when given" do
      frame = Protocol.error_response(nil, -32700, "could not parse JSON", %{line: 3})

      assert frame["error"]["data"] == %{"line" => 3}
      assert is_nil(frame["id"])
    end

    test "notification/2 omits the id" do
      assert Protocol.notification("event", %{"turnId" => "t1"}) ==
               %{"jsonrpc" => "2.0", "method" => "event", "params" => %{"turnId" => "t1"}}
    end

    test "encode_line/1 appends the newline delimiter" do
      line = Protocol.encode_line(Protocol.response(1, %{}))

      assert String.ends_with?(line, "\n")
      assert {:ok, %{"id" => 1}} = Tackle.Lib.JSON.decode(line)
    end
  end

  describe "serialize_event/1" do
    test "serializes the event envelope with an ISO8601 timestamp" do
      {:ok, timestamp, _offset} = DateTime.from_iso8601("2026-01-02T03:04:05Z")

      event =
        Event.new(:tool_start, %{"name" => "echo", "args" => %{"text" => "hi"}},
          id: "evt_1",
          parent_id: "evt_0",
          timestamp: timestamp
        )

      assert %{
               "type" => "tool_start",
               "id" => "evt_1",
               "parentId" => "evt_0",
               "timestamp" => "2026-01-02T03:04:05Z",
               "data" => %{"name" => "echo", "args" => %{"text" => "hi"}}
             } = Protocol.serialize_event(event)
    end

    test "json_safe/1 converts structs, tuples, and atoms" do
      term = %{
        tuple: {1, :two},
        atom: :cancelled,
        struct: %Tackle.Lib.Usage{input_tokens: 10, output_tokens: 5},
        nested: [%{ok: true}]
      }

      safe = Protocol.json_safe(term)

      assert safe["tuple"] == [1, "two"]
      assert safe["atom"] == "cancelled"
      assert safe["struct"]["input_tokens"] == 10
      assert safe["struct"]["output_tokens"] == 5
      assert safe["nested"] == [%{"ok" => true}]
    end

    test "json_safe/1 turns a provider error into its fields" do
      error = Tackle.Lib.LLM.Error.from_response(429, "slow down", [{"retry-after", "2"}])

      assert Protocol.json_safe(error) == %{
               "kind" => "rate_limited",
               "status" => 429,
               "retry_after_ms" => 2_000,
               "message" => "The provider is rate limiting requests (HTTP 429): slow down",
               "details" => "slow down"
             }
    end

    test "json_safe/1 keeps booleans and nil literal instead of stringifying" do
      assert Protocol.json_safe(%{flag: true, missing: nil}) == %{
               "flag" => true,
               "missing" => nil
             }
    end

    test "json_safe/1 output always encodes" do
      term = %{pid: self(), ref: make_ref(), dt: DateTime.utc_now(), fun: fn -> :ok end}

      encoded =
        Protocol.encode_line(
          Protocol.notification("event", %{"payload" => Protocol.json_safe(term)})
        )

      assert {:ok, _} = Tackle.Lib.JSON.decode(encoded)
    end
  end
end
