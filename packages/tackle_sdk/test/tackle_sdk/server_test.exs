defmodule Tackle.SDK.ServerTest do
  @moduledoc """
  End-to-end tests for `Tackle.SDK.Server` over in-memory stdio.

  Input lines are pre-fed and output lines are sent to the test process as
  messages, so these tests exercise the full frame path — decode, dispatch,
  turn tasks, cancellation, and shutdown — without touching real IO.
  """

  use ExUnit.Case, async: false

  alias Tackle.SDK.Server
  alias Tackle.SDK.Test.EchoTool
  alias Tackle.SDK.Test.FakeLLM
  alias Tackle.SDK.Test.RecordingLLM
  alias Tackle.SDK.Test.SlowLLM

  @init ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})

  defp start(input_lines, opts \\ []) do
    test_pid = self()

    output = fn line -> send(test_pid, {:out, line}) end

    spawn_link(fn ->
      result = Server.run(Keyword.merge([input: input_lines, output: output], opts))
      send(test_pid, {:run_result, result})
    end)
  end

  defp next_frame(timeout \\ 1_000) do
    assert_receive {:out, line}, timeout
    {:ok, frame} = Tackle.Lib.JSON.decode(line)
    frame
  end

  defp await_response(id, timeout \\ 1_000) do
    frame = next_frame(timeout)

    if frame["id"] == id do
      frame
    else
      await_response(id, timeout)
    end
  end

  defp collect_event_types(timeout) do
    collect_event_types([], timeout)
  end

  defp collect_event_types(acc, timeout) do
    receive do
      {:out, line} ->
        {:ok, frame} = Tackle.Lib.JSON.decode(line)

        case frame["method"] do
          "event" -> collect_event_types([frame["params"]["event"]["type"] | acc], timeout)
          "turn/end" -> {:ok, Enum.reverse(acc), frame["params"]}
          _ -> collect_event_types(acc, timeout)
        end
    after
      timeout -> flunk("expected a turn/end notification, got events: #{Enum.reverse(acc)}")
    end
  end

  describe "handshake" do
    test "initialize returns the protocol version and server info" do
      start([@init])

      assert %{
               "id" => 1,
               "result" => %{
                 "protocolVersion" => 1,
                 "serverInfo" => %{"name" => "tackle-sdk"}
               }
             } = await_response(1)

      assert_receive {:run_result, :ok}
    end

    test "requests before initialize are rejected" do
      line = ~s({"jsonrpc":"2.0","id":5,"method":"tools/list","params":{}})
      start([line])

      assert %{"id" => 5, "error" => %{"code" => -32002}} = await_response(5)
      assert_receive {:run_result, :ok}
    end

    test "tools/list describes the server-side registry" do
      start([@init, ~s({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})],
        tools: [EchoTool]
      )

      assert %{"result" => %{"tools" => [tool]}} = await_response(2)
      assert tool["name"] == "echo"
      assert is_binary(tool["description"])
      assert is_map(tool["parameters"])

      assert_receive {:run_result, :ok}
    end
  end

  describe "sessions" do
    test "session/new accepts a client-supplied sessionId and model ref" do
      line =
        ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"sessionId":"sess-1","model":"fake/echo"}})

      start([@init, line], adapters: [FakeLLM])

      assert %{"result" => %{"sessionId" => "sess-1"}} = await_response(2)
      assert_receive {:run_result, :ok}
    end

    test "session/new rejects duplicate session ids" do
      line =
        ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"sessionId":"sess-1","model":"fake/echo"}})

      start([@init, line, String.replace(line, ~s("id":2), ~s("id":3))], adapters: [FakeLLM])

      assert %{"result" => %{"sessionId" => "sess-1"}} = await_response(2)
      assert %{"id" => 3, "error" => %{"code" => -32602}} = await_response(3)
      assert_receive {:run_result, :ok}
    end

    test "session/new rejects unknown models and tools" do
      start(
        [
          @init,
          ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"model":"nope/nope"}}),
          ~s({"jsonrpc":"2.0","id":3,"method":"session/new","params":{"model":"fake/echo","tools":["missing"]}})
        ],
        adapters: [FakeLLM],
        tools: [EchoTool]
      )

      assert %{"id" => 2, "error" => %{"code" => -32602}} = await_response(2)
      assert %{"id" => 3, "error" => %{"code" => -32602}} = await_response(3)
      assert_receive {:run_result, :ok}
    end

    test "host llm_opts reach the adapter on every session" do
      start(
        [
          @init,
          ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"sessionId":"sess-1","model":"record/opts"}}),
          ~s({"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"sessionId":"sess-1","input":"hi"}})
        ],
        adapters: [RecordingLLM],
        llm_opts: [test_pid: self(), marker: "injected"]
      )

      assert %{"id" => 2, "result" => %{"sessionId" => "sess-1"}} = await_response(2)
      assert %{"id" => 3, "result" => %{"turnId" => _}} = await_response(3)
      assert {:ok, _event_types, %{"result" => "ok"}} = collect_event_types(1_000)

      assert_received {:generate_opts, opts}
      assert Keyword.get(opts, :marker) == "injected"
      assert_receive {:run_result, :ok}
    end
  end

  describe "turns" do
    test "a full turn streams events and ends with result ok" do
      start(
        [
          @init,
          ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"sessionId":"sess-1","model":"fake/echo","tools":["echo"]}}),
          ~s({"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"sessionId":"sess-1","turnId":"turn-1","input":"hello"}})
        ],
        adapters: [FakeLLM],
        tools: [EchoTool]
      )

      assert %{"result" => %{"sessionId" => "sess-1"}} = await_response(2)
      assert %{"id" => 3, "result" => %{"turnId" => "turn-1"}} = await_response(3)

      assert {:ok, event_types, turn_end} = collect_event_types(2_000)
      assert "turn_start" in event_types
      assert "tool_start" in event_types
      assert "tool_end" in event_types
      assert turn_end == %{"turnId" => "turn-1", "result" => "ok"}

      assert_receive {:run_result, :ok}
    end

    test "turn/cancel cancels an in-flight turn" do
      start(
        [
          @init,
          ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"sessionId":"sess-1","model":"slow/sleepy"}}),
          ~s({"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"sessionId":"sess-1","turnId":"turn-1","input":"hello"}}),
          ~s({"jsonrpc":"2.0","id":4,"method":"turn/cancel","params":{"turnId":"turn-1"}})
        ],
        adapters: [SlowLLM]
      )

      assert %{"id" => 3, "result" => %{"turnId" => "turn-1"}} = await_response(3)
      assert %{"id" => 4, "result" => %{"cancelled" => true}} = await_response(4)

      assert {:ok, _events, turn_end} = collect_event_types(2_000)
      assert turn_end["result"] == "cancelled"

      assert_receive {:run_result, :ok}
    end

    test "a second concurrent turn on the same session is rejected" do
      start(
        [
          @init,
          ~s({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"sessionId":"sess-1","model":"slow/sleepy"}}),
          ~s({"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"sessionId":"sess-1","turnId":"turn-1","input":"hello"}}),
          ~s({"jsonrpc":"2.0","id":4,"method":"turn/start","params":{"sessionId":"sess-1","turnId":"turn-2","input":"again"}})
        ],
        adapters: [SlowLLM]
      )

      assert %{"id" => 3, "result" => %{"turnId" => "turn-1"}} = await_response(3)
      assert %{"id" => 4, "error" => %{"code" => -32000}} = await_response(4)

      assert {:ok, _events, turn_end} = collect_event_types(2_000)
      assert turn_end["result"] == "ok"
      assert_receive {:run_result, :ok}
    end

    test "turn/start on an unknown session is rejected" do
      start(
        [
          @init,
          ~s({"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"sessionId":"ghost","input":"hi"}})
        ],
        adapters: [FakeLLM]
      )

      assert %{"id" => 3, "error" => %{"code" => -32602}} = await_response(3)
      assert_receive {:run_result, :ok}
    end

    test "turn/cancel on an unknown turn is rejected" do
      start(
        [@init, ~s({"jsonrpc":"2.0","id":4,"method":"turn/cancel","params":{"turnId":"ghost"}})],
        adapters: [FakeLLM]
      )

      assert %{"id" => 4, "error" => %{"code" => -32602}} = await_response(4)
      assert_receive {:run_result, :ok}
    end
  end

  describe "protocol errors" do
    test "malformed JSON is answered with a parse error and null id" do
      start(["{not json"])

      assert %{"id" => nil, "error" => %{"code" => -32700}} = next_frame()
      assert_receive {:run_result, :ok}
    end

    test "unknown methods are rejected with method not found" do
      start([@init, ~s({"jsonrpc":"2.0","id":9,"method":"frobnicate","params":{}})])

      assert %{"id" => 9, "error" => %{"code" => -32601}} = await_response(9)
      assert_receive {:run_result, :ok}
    end

    test "client notifications get no response" do
      start([@init, ~s({"jsonrpc":"2.0","method":"initialized"})])

      assert %{"id" => 1, "result" => %{"protocolVersion" => 1}} = await_response(1)
      # Only the initialize response is written; the notification is ignored
      # and the server stops cleanly at EOF.
      assert_receive {:run_result, :ok}
      refute_receive {:out, _line}
    end
  end
end
