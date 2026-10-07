defmodule Tackle.Plugins.OllamaTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.LLM
  alias Tackle.Plugins.Ollama
  alias Tackle.Plugins.Ollama.SSE

  test "catalog is local and metadata is host-configured" do
    assert Ollama.adapter_id() == "ollama-cloud"

    assert Ollama.models() == [
             "gpt-oss:120b",
             "gpt-oss:20b",
             "kimi-k3",
             "deepseek-v4.1-flash"
           ]

    assert Ollama.model_info("gpt-oss:120b") == nil

    Application.put_env(:tackle_ollama, :models, [
      {"gpt-oss:120b", %{context_window: 65_536}},
      "custom"
    ])

    on_exit(fn -> Application.delete_env(:tackle_ollama, :models) end)
    assert Ollama.model_info("gpt-oss:120b") == %{context_window: 65_536}
    assert {:ok, %{model: "custom"}} = LLM.select([Ollama], "ollama-cloud/custom")
  end

  test "projects a chat request and normalizes streamed usage" do
    parent = self()

    request = fn options ->
      send(parent, {:request, options})
      into = Keyword.fetch!(options, :into)
      response = %Req.Response{status: 200, headers: %{}, body: ""}

      frames = [
        sse(%{
          "model" => "gpt-oss:120b",
          "choices" => [
            %{
              "delta" => %{"content" => JSON.encode!(%{"answer" => "ok"})},
              "finish_reason" => nil
            }
          ]
        }),
        sse(%{
          "model" => "gpt-oss:120b",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        }),
        sse(%{"choices" => [], "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 3}}),
        "data: [DONE]\n\n"
      ]

      {_request, response} =
        Enum.reduce(frames, {%Req.Request{}, response}, fn frame, pair ->
          case into.({:data, frame}, pair) do
            {:cont, next} -> next
            {:halt, next} -> next
          end
        end)

      {:ok, response}
    end

    opts = [
      model: "gpt-oss:120b",
      api_key: "  key-value  ",
      request: request,
      messages: [%{role: :user, content: "go"}],
      tools: [
        %{
          name: "search",
          description: "Search",
          input_schema: [query: [type: :string, required: true]]
        }
      ],
      reasoning_effort: :off
    ]

    assert {:ok, result} =
             LLM.generate_with(Ollama, [answer: [type: :string, required: true]], opts)

    assert result.data == %{"answer" => "ok"}
    assert result.provider == "ollama-cloud"
    assert result.usage.input_tokens == 10
    assert result.usage.output_tokens == 3
    assert_receive {:request, options}
    assert options[:url] == "https://ollama.com/v1/chat/completions"

    assert Enum.find(options[:headers], &(elem(&1, 0) == "authorization")) ==
             {"authorization", "Bearer key-value"}

    body = JSON.decode!(options[:body])
    assert body["stream_options"] == %{"include_usage" => true}
    assert body["reasoning_effort"] == "none"
    assert body["response_format"]["type"] == "json_schema"
    assert get_in(body, ["tools", Access.at(0), "function", "name"]) == "search"
  end

  test "rejects unsafe keys and local-only model suffix" do
    request = fn _ -> flunk("unexpected HTTP request") end

    assert {:error, :invalid_api_key} =
             Ollama.generate(nil, model: "gpt-oss:120b", api_key: "bad\nkey", request: request)

    assert {:error, {:unsupported_model, "gpt-oss:120b:cloud"}} =
             Ollama.generate(nil, model: "gpt-oss:120b:cloud", api_key: "key", request: request)
  end

  defp sse(event), do: "data: " <> JSON.encode!(event) <> "\n\n"

  test "synthesizes a stable tool id when Ollama omits it" do
    event = %{
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{"index" => 0, "function" => %{"name" => "search", "arguments" => "{}"}}
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }

    state =
      SSE.new()
      |> SSE.push(sse(event), fn value -> send(self(), {:event, value}) end)
      |> SSE.push("data: [DONE]\n\n", fn _ -> :ok end)

    assert {:ok, result} = SSE.result(state, "gpt-oss:120b", nil)
    [call] = result.data["tool_calls"]
    assert_receive {:event, %{type: :tool_input_delta, tool_call_id: event_id}}
    assert event_id == call["id"]
    assert String.starts_with?(call["id"], "ollama-cloud-generated-")
  end
end
