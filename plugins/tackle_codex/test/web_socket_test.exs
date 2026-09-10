defmodule Tackle.Plugins.Codex.WebSocketTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Cancellation
  alias Tackle.Plugins.Codex.SSE
  alias Tackle.Plugins.Codex.WebSocket

  test "reuses a Mint connection and sends only the append-only continuation delta" do
    test_pid = self()
    session_id = "ws-session-#{System.unique_integer([:positive])}"
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request_headers} = recv_http_headers(socket, "")
        send(test_pid, {:upgrade_headers, request_headers})
        :ok = send_upgrade_response(socket, request_headers)

        {:ok, first_request} = recv_json_frame(socket)
        send(test_pid, {:websocket_request, 1, first_request})

        :ok =
          send_json_frame(socket, %{
            "type" => "response.created",
            "response" => %{"id" => "resp-1"}
          })

        :ok =
          send_json_frame(socket, %{
            "type" => "response.completed",
            "response" => %{
              "status" => "completed",
              "model" => "gpt-5.5",
              "output" => [assistant_item("first")]
            }
          })

        {:ok, second_request} = recv_json_frame(socket)
        send(test_pid, {:websocket_request, 2, second_request})

        :ok =
          send_json_frame(socket, %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp-2",
              "status" => "completed",
              "model" => "gpt-5.5",
              "output" => [assistant_item("second")]
            }
          })

        receive do
          :stop -> :ok
        after
          1_000 -> :ok
        end

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      WebSocket.close_session(session_id)
      send(server, :stop)
      :gen_tcp.close(listener)
    end)

    user_one = input_message("first request")
    assistant_one = assistant_item("first")
    user_two = input_message("second request")
    request_body = base_body([user_one])

    opts = [
      responses_url: "http://127.0.0.1:#{port}/codex/responses",
      session_id: session_id,
      transport: :websocket_cached,
      websocket_connect_timeout: 2_000,
      receive_timeout: 2_000
    ]

    headers = [
      {"authorization", "Bearer token"},
      {"chatgpt-account-id", "account"},
      {"openai-beta", "responses_websockets=2026-02-06"},
      {"session-id", session_id}
    ]

    assert {:ok, %{body: first_parser}} =
             WebSocket.request(request_body, opts, headers, fn _event -> :ok end)

    assert {:ok, %{data: %{"content" => "first"}}} =
             first_parser |> SSE.finish(fn _event -> :ok end) |> SSE.result("gpt-5.5", nil)

    second_body = base_body([user_one, assistant_one, user_two])

    assert {:ok, %{body: second_parser}} =
             WebSocket.request(second_body, opts, headers, fn _event -> :ok end)

    assert {:ok, %{data: %{"content" => "second"}}} =
             second_parser |> SSE.finish(fn _event -> :ok end) |> SSE.result("gpt-5.5", nil)

    assert_receive {:upgrade_headers, request_headers}

    assert String.contains?(
             String.downcase(request_headers),
             "openai-beta: responses_websockets=2026-02-06"
           )

    assert String.contains?(String.downcase(request_headers), "authorization: bearer token")

    assert_receive {:websocket_request, 1, first_wire}
    assert first_wire["type"] == "response.create"
    assert first_wire["store"] == false
    assert first_wire["input"] == [user_one]
    refute Map.has_key?(first_wire, "previous_response_id")

    assert_receive {:websocket_request, 2, second_wire}
    assert second_wire["previous_response_id"] == "resp-1"
    assert second_wire["input"] == [user_two]

    assert [_connection] = session_connections(session_id)
    assert :ok = WebSocket.close_session(session_id)
    assert session_connections(session_id) == []
  end

  test "backpressures frames and clears the connection when a callback cancels" do
    test_pid = self()
    session_id = "cancel-session-#{System.unique_integer([:positive])}"
    signal = Cancellation.new_signal()
    on_exit(fn -> Cancellation.delete(signal) end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        {:ok, first_socket} = accept_websocket(listener)
        {:ok, _first_request} = recv_json_frame(first_socket)

        :ok =
          :gen_tcp.send(first_socket, [
            server_frame(%{
              "type" => "response.output_text.delta",
              "output_index" => 0,
              "delta" => "one"
            }),
            server_frame(%{
              "type" => "response.output_text.delta",
              "output_index" => 0,
              "delta" => "two"
            }),
            server_frame(%{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp-cancelled",
                "status" => "completed",
                "output" => [assistant_item("onetwo")]
              }
            })
          ])

        {:ok, second_socket} = accept_websocket(listener)
        {:ok, second_request} = recv_json_frame(second_socket)
        send(test_pid, {:post_cancel_request, second_request})

        :ok =
          send_json_frame(second_socket, %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp-fresh",
              "status" => "completed",
              "output" => [assistant_item("fresh")]
            }
          })

        receive do
          :stop -> :ok
        after
          1_000 -> :ok
        end

        :gen_tcp.close(first_socket)
        :gen_tcp.close(second_socket)
      end)

    on_exit(fn ->
      WebSocket.close_session(session_id)
      send(server, :stop)
      :gen_tcp.close(listener)
    end)

    opts = [
      responses_url: "http://127.0.0.1:#{port}/codex/responses",
      session_id: session_id,
      transport: :websocket_cached,
      cancellation_signal: signal,
      websocket_connect_timeout: 2_000,
      receive_timeout: 2_000
    ]

    headers = [
      {"authorization", "Bearer token"},
      {"chatgpt-account-id", "account"}
    ]

    assert {:error, :cancelled} =
             WebSocket.request(base_body([input_message("cancel")]), opts, headers, fn event ->
               send(test_pid, {:callback, event})
               Cancellation.cancel(signal)
             end)

    assert_receive {:callback, %{type: :text_delta, delta: "one"}}
    refute_receive {:callback, %{type: :text_delta, delta: "two"}}, 20
    refute_receive {:websocket_event, _, _, _}, 20
    refute_receive {:websocket_done, _}, 20
    refute_receive {:websocket_error, _, _, _}, 20
    assert session_connections(session_id) == []

    Cancellation.delete(signal)

    fresh_opts = Keyword.delete(opts, :cancellation_signal)

    assert {:ok, %{body: fresh_parser}} =
             WebSocket.request(
               base_body([
                 input_message("cancel"),
                 assistant_item("onetwo"),
                 input_message("fresh")
               ]),
               fresh_opts,
               headers,
               fn _event -> :ok end
             )

    assert {:ok, %{data: %{"content" => "fresh"}}} =
             fresh_parser |> SSE.finish(fn _event -> :ok end) |> SSE.result("gpt-5.5", nil)

    assert_receive {:post_cancel_request, fresh_wire}
    refute Map.has_key?(fresh_wire, "previous_response_id")
  end

  test "a concurrent timeout does not kill the active session request" do
    test_pid = self()
    session_id = "concurrent-session-#{System.unique_integer([:positive])}"
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        {:ok, active_socket} = accept_websocket(listener)
        {:ok, active_request} = recv_json_frame(active_socket)
        send(test_pid, {:active_request_received, active_request})

        {:ok, timed_out_socket} = accept_websocket(listener)
        {:ok, timed_out_request} = recv_json_frame(timed_out_socket)
        send(test_pid, {:concurrent_request_received, timed_out_request})

        receive do
          :finish_active -> :ok
        end

        :ok =
          send_json_frame(active_socket, %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp-active",
              "status" => "completed",
              "output" => [assistant_item("active completed")]
            }
          })

        receive do
          :stop -> :ok
        after
          1_000 -> :ok
        end

        :gen_tcp.close(active_socket)
        :gen_tcp.close(timed_out_socket)
      end)

    on_exit(fn ->
      WebSocket.close_session(session_id)
      send(server, :stop)
      :gen_tcp.close(listener)
    end)

    headers = [
      {"authorization", "Bearer token"},
      {"chatgpt-account-id", "account"}
    ]

    base_opts = [
      responses_url: "http://127.0.0.1:#{port}/codex/responses",
      session_id: session_id,
      transport: :websocket_cached,
      websocket_connect_timeout: 2_000,
      receive_timeout: 2_000
    ]

    active_task =
      Task.async(fn ->
        WebSocket.request(
          base_body([input_message("active")]),
          base_opts,
          headers,
          fn _event -> :ok end
        )
      end)

    assert_receive {:active_request_received, active_wire}
    assert active_wire["input"] == [input_message("active")]

    timed_out_opts = Keyword.put(base_opts, :receive_timeout, 50)

    assert {:error, {:websocket_transport_failed, :before_stream, :receive_timeout}} =
             WebSocket.request(
               base_body([input_message("concurrent")]),
               timed_out_opts,
               headers,
               fn _event -> :ok end
             )

    assert_receive {:concurrent_request_received, concurrent_wire}
    refute Map.has_key?(concurrent_wire, "previous_response_id")

    send(server, :finish_active)

    assert {:ok, %{body: active_parser}} = Task.await(active_task, 2_000)

    assert {:ok, %{data: %{"content" => "active completed"}}} =
             active_parser |> SSE.finish(fn _event -> :ok end) |> SSE.result("gpt-5.5", nil)
  end

  test "receive timeout interrupts a stalled WebSocket upgrade" do
    session_id = "timeout-session-#{System.unique_integer([:positive])}"
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request_headers} = recv_http_headers(socket, "")

        receive do
          :stop -> :ok
        after
          2_000 -> :ok
        end

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      WebSocket.close_session(session_id)
      send(server, :stop)
      :gen_tcp.close(listener)
    end)

    opts = [
      responses_url: "http://127.0.0.1:#{port}/codex/responses",
      session_id: session_id,
      transport: :websocket_cached,
      websocket_connect_timeout: 2_000,
      receive_timeout: 50
    ]

    headers = [
      {"authorization", "Bearer token"},
      {"chatgpt-account-id", "account"}
    ]

    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:websocket_transport_failed, :before_stream, :receive_timeout}} =
             WebSocket.request(base_body([input_message("timeout")]), opts, headers, fn _event ->
               :ok
             end)

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed < 750
    assert session_connections(session_id) == []
  end

  test "reconnects and retries full context when the previous response is missing" do
    test_pid = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        {:ok, first_socket} = accept_websocket(listener)
        {:ok, first_request} = recv_json_frame(first_socket)
        send(test_pid, {:retry_request, 1, first_request})

        :ok =
          send_json_frame(first_socket, %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp-stale",
              "status" => "completed",
              "output" => [assistant_item("first")]
            }
          })

        {:ok, delta_request} = recv_json_frame(first_socket)
        send(test_pid, {:retry_request, 2, delta_request})

        :ok =
          send_json_frame(first_socket, %{
            "type" => "error",
            "error" => %{
              "code" => "previous_response_not_found",
              "message" => "missing"
            }
          })

        {:ok, second_socket} = accept_websocket(listener)
        {:ok, full_request} = recv_json_frame(second_socket)
        send(test_pid, {:retry_request, 3, full_request})

        :ok =
          send_json_frame(second_socket, %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp-recovered",
              "status" => "completed",
              "output" => [assistant_item("recovered")]
            }
          })

        receive do
          :stop -> :ok
        after
          1_000 -> :ok
        end

        :gen_tcp.close(first_socket)
        :gen_tcp.close(second_socket)
      end)

    on_exit(fn ->
      WebSocket.close_session("retry-session")
      send(server, :stop)
      :gen_tcp.close(listener)
    end)

    user_one = input_message("first request")
    assistant_one = assistant_item("first")
    user_two = input_message("second request")

    opts = [
      responses_url: "http://127.0.0.1:#{port}/codex/responses",
      session_id: "retry-session",
      transport: :websocket_cached,
      websocket_connect_timeout: 2_000,
      receive_timeout: 2_000
    ]

    headers = [
      {"authorization", "Bearer token"},
      {"chatgpt-account-id", "account"}
    ]

    assert {:ok, %{body: first_parser}} =
             WebSocket.request(base_body([user_one]), opts, headers, fn _event -> :ok end)

    assert {:ok, _result} =
             first_parser |> SSE.finish(fn _event -> :ok end) |> SSE.result("gpt-5.5", nil)

    assert {:ok, %{body: recovered_parser}} =
             WebSocket.request(
               base_body([user_one, assistant_one, user_two]),
               opts,
               headers,
               fn _event -> :ok end
             )

    assert {:ok, %{data: %{"content" => "recovered"}}} =
             recovered_parser
             |> SSE.finish(fn _event -> :ok end)
             |> SSE.result("gpt-5.5", nil)

    assert_receive {:retry_request, 1, first_wire}
    refute Map.has_key?(first_wire, "previous_response_id")

    assert_receive {:retry_request, 2, delta_wire}
    assert delta_wire["previous_response_id"] == "resp-stale"
    assert delta_wire["input"] == [user_two]

    assert_receive {:retry_request, 3, recovered_wire}
    refute Map.has_key?(recovered_wire, "previous_response_id")
    assert recovered_wire["input"] == [user_one, assistant_one, user_two]
  end

  test "falls back to a full request when non-input options change" do
    user = input_message("hello")
    assistant = assistant_item("hi")
    next_user = input_message("next")

    previous = base_body([user])

    continuation = %{
      request_body: previous,
      response_id: "resp-1",
      response_items: [assistant]
    }

    changed =
      previous |> Map.put("model", "gpt-5.4") |> Map.put("input", [user, assistant, next_user])

    assert {^changed, :full} = WebSocket.continuation_request(changed, continuation)
  end

  defp session_connections(session_id) do
    Registry.select(Tackle.Plugins.Codex.WebSocket.Registry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.filter(fn
      {{:session, ^session_id, _connection_key}, _pid} -> true
      _entry -> false
    end)
  end

  defp base_body(input) do
    %{
      "model" => "gpt-5.5",
      "store" => false,
      "stream" => true,
      "instructions" => "Be useful",
      "input" => input
    }
  end

  defp input_message(text) do
    %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}
  end

  defp assistant_item(text) do
    %{
      "type" => "message",
      "id" => "msg-#{text}",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }
  end

  defp accept_websocket(listener) do
    with {:ok, socket} <- :gen_tcp.accept(listener),
         {:ok, request_headers} <- recv_http_headers(socket, ""),
         :ok <- send_upgrade_response(socket, request_headers) do
      {:ok, socket}
    end
  end

  defp recv_http_headers(socket, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {index, 4} ->
        {:ok, binary_part(acc, 0, index + 4)}

      :nomatch ->
        with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 2_000) do
          recv_http_headers(socket, acc <> chunk)
        end
    end
  end

  defp send_upgrade_response(socket, headers) do
    key =
      headers
      |> String.split("\r\n")
      |> Enum.find_value(fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            if String.downcase(name) == "sec-websocket-key", do: String.trim(value)

          _parts ->
            nil
        end
      end)

    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :gen_tcp.send(
      socket,
      "HTTP/1.1 101 Switching Protocols\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
    )
  end

  defp recv_json_frame(socket) do
    with {:ok, <<_fin_opcode, masked_length>>} <- :gen_tcp.recv(socket, 2, 2_000),
         masked? <- Bitwise.band(masked_length, 0x80) != 0,
         length_code <- Bitwise.band(masked_length, 0x7F),
         {:ok, payload_length} <- recv_payload_length(socket, length_code),
         {:ok, mask} <- recv_mask(socket, masked?),
         {:ok, payload} <- :gen_tcp.recv(socket, payload_length, 2_000),
         decoded <- apply_mask(payload, mask),
         {:ok, event} <- JSON.decode(decoded) do
      {:ok, event}
    end
  end

  defp recv_payload_length(_socket, length) when length < 126, do: {:ok, length}

  defp recv_payload_length(socket, 126) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, 2_000), do: {:ok, length}
  end

  defp recv_payload_length(socket, 127) do
    with {:ok, <<length::64>>} <- :gen_tcp.recv(socket, 8, 2_000), do: {:ok, length}
  end

  defp recv_mask(socket, true), do: :gen_tcp.recv(socket, 4, 2_000)
  defp recv_mask(_socket, false), do: {:ok, <<0, 0, 0, 0>>}

  defp apply_mask(payload, mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, Enum.at(mask_bytes, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end

  defp send_json_frame(socket, event), do: :gen_tcp.send(socket, server_frame(event))

  defp server_frame(event) do
    payload = JSON.encode!(event)
    [<<0x81>>, server_payload_length(byte_size(payload)), payload]
  end

  defp server_payload_length(length) when length < 126, do: <<length>>
  defp server_payload_length(length) when length <= 65_535, do: <<126, length::16>>
  defp server_payload_length(length), do: <<127, length::64>>
end
