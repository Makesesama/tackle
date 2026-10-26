defmodule Tackle.Plugins.OllamaTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.{Decision, LLM, Thinking}
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Plugins.Ollama
  alias Tackle.Plugins.Ollama.SSE

  setup do
    previous = Application.get_env(:tackle_ollama, Ollama)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tackle_ollama, Ollama, previous),
        else: Application.delete_env(:tackle_ollama, Ollama)
    end)

    Application.delete_env(:tackle_ollama, Ollama)
    :ok
  end

  @search_schema %{
    "type" => "object",
    "properties" => %{"query" => %{"type" => "string"}},
    "required" => ["query"]
  }

  @catalog ["gpt-oss:120b", "gpt-oss:20b", "kimi-k3", "deepseek-v4.1-flash", "glm-5.3"]

  describe "default providers" do
    test "are a keyless local server and the keyed cloud catalog" do
      assert Ollama.adapter_id() == "ollama"
      assert Ollama.catalog_models() == @catalog

      assert [{"ollama", local}, {"ollama-cloud", cloud}] = Ollama.default_providers()

      assert %{
               "base_url" => "http://localhost:11434/v1",
               "api_key" => "none",
               "local" => true,
               "models" => [],
               "decision_models" => []
             } = local

      assert %{
               "base_url" => "https://ollama.com/v1",
               "api_key" => "required",
               "api_key_env" => "OLLAMA_API_KEY",
               "local" => false,
               "models" => @catalog
             } = cloud

      assert Ollama.model_info("gpt-oss:120b", cloud) == nil
    end

    test "resolve existing ollama and ollama-cloud refs" do
      Application.put_env(:tackle_ollama, Ollama,
        providers: %{"ollama" => %{"models" => ["qwen3:8b"]}}
      )

      assert {:ok, %LLM.Selection{adapter: Ollama, provider_id: "ollama", model: "qwen3:8b"}} =
               LLM.select([Ollama], "ollama/qwen3:8b")

      assert {:ok, %LLM.Selection{adapter: Ollama, provider_id: "ollama-cloud"} = cloud} =
               LLM.select([Ollama], "ollama-cloud/glm-5.3")

      assert cloud.model == "glm-5.3"
      assert cloud.model_info == nil
      assert cloud.provider_settings["api_key"] == "required"

      assert {:error, {:unknown_model, "ollama/gpt-oss:120b"}} =
               LLM.select([Ollama], "ollama/gpt-oss:120b")
    end

    test "merge application configuration by provider id and add new providers" do
      Application.put_env(:tackle_ollama, Ollama,
        providers: %{
          "ollama-cloud" => %{
            "models" => ["custom"],
            "model_info" => %{"custom" => %{"context_window" => 65_536}}
          },
          "lab" => %{"base_url" => "http://lab:11434/v1", "models" => ["m"]}
        }
      )

      assert [{"ollama", _}, {"ollama-cloud", cloud}, {"lab", lab}] = Ollama.default_providers()
      assert cloud["models"] == ["custom"]
      assert cloud["base_url"] == "https://ollama.com/v1"
      assert lab == %{"base_url" => "http://lab:11434/v1", "models" => ["m"]}

      assert {:ok, selection} = LLM.select([Ollama], "ollama-cloud/custom")
      assert selection.model_info.context_window == 65_536

      assert {:error, {:unknown_model, "ollama-cloud/gpt-oss:120b"}} =
               LLM.select([Ollama], "ollama-cloud/gpt-oss:120b")

      assert {:ok, %{provider_id: "lab"}} = LLM.select([Ollama], "lab/m")
    end

    test "malformed application configuration is reported" do
      Application.put_env(:tackle_ollama, Ollama, providers: %{"ollama" => "bad"})

      assert {:error, {:invalid_provider_settings, "ollama", "bad"}} =
               LLM.select([Ollama], "ollama/x")

      Application.put_env(:tackle_ollama, Ollama, providers: [])
      assert_raise ArgumentError, ~r/:providers to be a map/, &Ollama.default_providers/0

      assert {:error, {:adapter_callback_failed, Ollama, :default_providers, _}} =
               LLM.select([Ollama], "ollama/x")
    end
  end

  describe "custom providers" do
    test "use their own base URL, models, and keyless transport" do
      provider = gpu_box()
      parent = self()

      request = fn options ->
        send(parent, {:request, options})
        {:ok, %{status: 200, body: completion()}}
      end

      assert {:error, {:unknown_model, "gpu-box/gpt-oss:120b"}} =
               LLM.select([Ollama, provider], "gpu-box/gpt-oss:120b")

      assert {:ok, selection} = LLM.select([Ollama, provider], "gpu-box/gpt-oss:20b")
      assert selection.model_info.context_window == 131_072

      assert {:ok, result} =
               LLM.generate_with(selection, nil,
                 messages: [%{role: :user, content: "hi"}],
                 api_key: "ignored",
                 request: request
               )

      assert result.provider == "gpu-box"
      assert result.usage.provider == "gpu-box"
      assert result.provider_state == nil
      assert_receive {:request, options}
      assert options[:url] == "http://gpu:11434/v1/chat/completions"
      refute List.keyfind(options[:headers], "authorization", 0)
    end

    test "with empty settings default to a keyless local URL without models" do
      {:ok, bare} = Provider.new("bare", Ollama)
      assert Ollama.models(bare.settings) == []
      refute Ollama.local?(bare.settings)
      assert {:error, {:unknown_model, "bare/x"}} = LLM.select([bare], "bare/x")
    end

    test "collide with default providers on the same id" do
      {:ok, provider} = Provider.new("ollama", Ollama, %{"models" => ["x"]})

      assert {:error, {:duplicate_provider_id, "ollama"}} =
               LLM.select([Ollama, provider], "ollama/x")

      assert {:ok, %{provider_settings: %{"models" => ["x"]}}} =
               LLM.select([provider], "ollama/x")
    end

    test "decision selection locality follows each provider" do
      Application.put_env(:tackle_ollama, Ollama,
        providers: %{"ollama" => %{"decision_models" => ["tev1:4b"]}}
      )

      {:ok, remote} =
        Provider.new("remote-box", Ollama, %{"decision_models" => ["tev1:4b"]})

      {:ok, invalid} =
        Provider.new("odd-box", Ollama, %{"decision_models" => ["tev1:4b"], "local" => "yes"})

      providers = [Ollama, gpu_box(), remote, invalid]

      assert {:ok, %Decision.Selection{provider_id: "ollama", local: true}} =
               Decision.select(providers, "ollama/tev1:4b")

      assert {:ok, %Decision.Selection{provider_id: "gpu-box", local: true}} =
               Decision.select(providers, "gpu-box/tev1:4b")

      assert {:ok, %Decision.Selection{provider_id: "remote-box", local: false}} =
               Decision.select(providers, "remote-box/tev1:4b")

      assert {:error, {:invalid_local_flag, "odd-box", "yes"}} =
               Decision.select(providers, "odd-box/tev1:4b")

      assert {:error, {:unknown_decision_model, "ollama-cloud/tev1:4b"}} =
               Decision.select(providers, "ollama-cloud/tev1:4b")
    end

    test "keyed decisions send the provider's key to its own endpoint" do
      {:ok, provider} =
        Provider.new("hosted", Ollama, %{
          "base_url" => "https://hosted.example/v1",
          "api_key" => "required",
          "decision_models" => ["tev1:4b"]
        })

      parent = self()
      question = Decision.Question.noul("w", "Waiting?")

      request = fn options ->
        send(parent, {:request, options})

        {:ok,
         %{
           status: 200,
           body: JSON.encode!(%{"answers" => %{"w" => %{"type" => "noul", "noul" => 0.5}}})
         }}
      end

      assert {:ok, selection} = Decision.select([provider], "hosted/tev1:4b")

      assert {:ok, _result} =
               Decision.decide(selection, "state", [question],
                 api_key: "hosted-key",
                 request: request
               )

      assert_receive {:request, options}
      assert options[:url] == "https://hosted.example/v1/systemone"

      assert List.keyfind(options[:headers], "authorization", 0) ==
               {"authorization", "Bearer hosted-key"}

      assert {:error, {:missing_ollama_api_key, "hosted"}} =
               Decision.decide(selection, "state", [question],
                 request: fn _ -> flunk("unexpected HTTP request") end
               )
    end
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

    {:ok, selection} = LLM.select([Ollama], "ollama-cloud/gpt-oss:120b")

    opts = [
      api_key: "  key-value  ",
      request: request,
      messages: [%{role: :user, content: "go"}],
      tools: [
        %{name: "search", description: "Search", input_schema: @search_schema}
      ],
      reasoning_effort: :off
    ]

    assert {:ok, result} =
             LLM.generate_with(selection, [answer: [type: :string, required: true]], opts)

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

    assert body["tools"] == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "search",
                 "description" => "Search",
                 "parameters" => @search_schema
               }
             }
           ]
  end

  test "forwards every thinking level for Ollama to map" do
    parent = self()

    request = fn options ->
      send(parent, {:effort, JSON.decode!(options[:body])["reasoning_effort"]})
      into = Keyword.fetch!(options, :into)
      response = %Req.Response{status: 200, headers: %{}, body: ""}

      frames = [
        sse(%{"choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => "stop"}]}),
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

    {:ok, selection} = LLM.select([Ollama], "ollama-cloud/gpt-oss:120b")
    opts = [api_key: "key", request: request, messages: [%{role: :user, content: "go"}]]

    for level <- Thinking.levels() do
      assert {:ok, _result} =
               LLM.generate_with(selection, nil, Keyword.put(opts, :reasoning_effort, level))

      expected = if level == "off", do: "none", else: level
      assert_receive {:effort, ^expected}
    end
  end

  test "rejects unsafe keys and local-only model suffix" do
    request = fn _ -> flunk("unexpected HTTP request") end

    cloud = [provider_id: "ollama-cloud", request: request]

    assert {:error, :invalid_api_key} =
             LLM.generate_with(Ollama, nil, [model: "gpt-oss:120b", api_key: "bad\nkey"] ++ cloud)

    assert {:error, {:unsupported_model, "gpt-oss:120b:cloud"}} =
             LLM.generate_with(
               Ollama,
               nil,
               [model: "gpt-oss:120b:cloud", api_key: "key"] ++ cloud
             )
  end

  defp sse(event), do: "data: " <> JSON.encode!(event) <> "\n\n"

  defp completion do
    sse(%{"choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => "stop"}]}) <>
      sse(%{"choices" => [], "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1}}) <>
      "data: [DONE]\n\n"
  end

  defp gpu_box do
    {:ok, provider} =
      Provider.new("gpu-box", Ollama, %{
        "base_url" => "http://gpu:11434/v1",
        "api_key" => "none",
        "local" => true,
        "models" => ["gpt-oss:20b"],
        "model_info" => %{"gpt-oss:20b" => %{"context_window" => 131_072}},
        "decision_models" => ["tev1:4b"]
      })

    provider
  end

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
    assert String.starts_with?(call["id"], "ollama-generated-")
  end
end
