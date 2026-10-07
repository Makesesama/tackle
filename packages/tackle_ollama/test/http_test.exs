defmodule Tackle.Plugins.Ollama.HTTPTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.Ollama
  alias Tackle.Plugins.Ollama.HTTP

  test "real Req transport streams a loopback response through the accumulator" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = receive_headers(socket, "")
        [headers, body] = String.split(request, "\r\n\r\n", parts: 2)
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        body = receive_body(socket, body, String.to_integer(length))
        send(parent, {:request, headers, JSON.decode!(body)})

        wire =
          "data: " <>
            JSON.encode!(%{
              "choices" => [%{"delta" => %{"content" => "hello"}, "finish_reason" => "stop"}]
            }) <> "\n\ndata: [DONE]\n\n"

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{byte_size(wire)}\r\nConnection: close\r\n\r\n" <>
              wire
          )

        :gen_tcp.close(socket)
      end)

    assert {:ok, result} =
             Ollama.stream(
               nil,
               [
                 model: "gpt-oss:120b",
                 api_key: "fake",
                 base_url: "http://127.0.0.1:#{port}/v1",
                 messages: [%{role: :user, content: "hi"}]
               ],
               &send(parent, {:event, &1})
             )

    assert result.data == %{"content" => "hello", "tool_calls" => []}
    assert_received {:event, %{type: :text_delta, delta: "hello"}}
    assert_received {:request, headers, body}
    assert headers =~ "POST /v1/chat/completions"
    assert body["messages"] == [%{"role" => "user", "content" => "hi"}]
    Task.await(server)
  end

  test "stream transport failures and invalid return shapes are explicit errors" do
    assert {:error, {:request_failed, :timeout}} =
             HTTP.stream([], nil, fn _, _, _ -> flunk("no chunk") end,
               stream: fn _, _, _ -> {:error, :timeout, nil, nil} end
             )

    assert {:error, {:invalid_http_response, :unexpected}} =
             HTTP.stream([], nil, fn _, _, _ -> flunk("no chunk") end,
               stream: fn _, _, _ -> :unexpected end
             )
  end

  defp receive_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
      receive_headers(socket, acc <> chunk)
    end
  end

  defp receive_body(_socket, acc, length) when byte_size(acc) >= length, do: acc

  defp receive_body(socket, acc, length) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
    receive_body(socket, acc <> chunk, length)
  end
end
