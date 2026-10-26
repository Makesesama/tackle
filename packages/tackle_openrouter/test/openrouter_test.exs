defmodule Tackle.Plugins.OpenRouterTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.{Cancellation, LLM, ModelInfo, Thinking, Usage}
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Plugins.OpenRouter

  @model "openai/gpt-6-luna"
  @claude "anthropic/claude-sonnet-5.5"

  @search_schema %{
    "type" => "object",
    "properties" => %{"query" => %{"type" => "string", "description" => "Query"}},
    "required" => ["query"]
  }

  defmodule CredentialStore do
    @behaviour Tackle.Lib.CredentialStore

    @impl true
    def fetch(agent, namespace), do: Agent.get(agent, &Map.fetch(&1, namespace))

    @impl true
    def put(agent, namespace, credentials) do
      Agent.update(agent, &Map.put(&1, namespace, credentials))
    end

    @impl true
    def delete(agent, namespace), do: Agent.update(agent, &Map.delete(&1, namespace))
  end

  defmodule Interaction do
    @behaviour Tackle.Lib.Interaction

    @impl true
    def info(_reference, _message), do: :ok

    @impl true
    def prompt(reference, opts) do
      send(reference, {:interaction_prompt, opts})
      Process.get(:prompt_result) || {:ok, "  prompted-key  "}
    end

    @impl true
    def confirm(_reference, _message), do: false

    @impl true
    def progress(_reference, _opts, fun), do: fun.()
  end

  setup do
    agent =
      start_supervised!(
        {Agent, fn -> %{OpenRouter.adapter_id() => %{"api_key" => "stored-key"}} end},
        id: {Agent, make_ref()}
      )

    {:ok, store: {CredentialStore, agent}}
  end

  describe "model catalog" do
    test "exposes vendor-prefixed models with limits and price cards" do
      assert OpenRouter.adapter_id() == "openrouter"
      assert @claude in OpenRouter.models()
      assert @model in OpenRouter.models()
      assert OpenRouter.models() == Enum.uniq(OpenRouter.models())

      assert {:ok, %ModelInfo{} = info} = LLM.model_info(OpenRouter, @claude)
      assert info.context_window == 1_000_000
      assert info.max_output_tokens == 128_000
      assert info.pricing.input == 2.0
      assert info.pricing.output == 10.0
      assert info.pricing.cache_read == 0.2
      assert info.pricing.cache_write == 2.5
      assert info.pricing.currency == "USD"
      assert info.pricing.unit_tokens == 1_000_000

      Enum.each(OpenRouter.models(), fn model ->
        assert {:ok, %ModelInfo{}} = LLM.model_info(OpenRouter, model)
      end)

      assert {:ok, selection} = LLM.select([OpenRouter], "openrouter/" <> @claude)
      assert selection.adapter == OpenRouter
      assert selection.model == @claude
      assert {:error, {:unknown_model, _ref}} = LLM.select([OpenRouter], "openrouter/nope/nope")
    end

    test "adds configured models with optional metadata" do
      Application.put_env(:tackle_openrouter, :models, [
        "vendor/plain",
        {"vendor/described", %{context_window: 32_000, max_output_tokens: 8_000}}
      ])

      assert "vendor/plain" in OpenRouter.models()
      assert "vendor/described" in OpenRouter.models()
      assert {:ok, nil} = LLM.model_info(OpenRouter, "vendor/plain")

      assert {:ok, %ModelInfo{context_window: 32_000, max_output_tokens: 8_000}} =
               LLM.model_info(OpenRouter, "vendor/described")

      assert {:ok, %{model: "vendor/plain"}} = LLM.select([OpenRouter], "openrouter/vendor/plain")
    after
      Application.delete_env(:tackle_openrouter, :models)
    end
  end

  test "translates messages and tools and reports billed usage", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:request, options})

      streaming_response(options, [
        ": OPENROUTER PROCESSING\n\n",
        sse(chunk(@model, %{"content" => "hel"})),
        sse(chunk(@model, %{"content" => "lo"}, "stop")),
        # OpenRouter repeats the finish reason on the usage-only frame.
        sse(
          chunk(@model, %{"content" => "", "role" => "assistant"}, "stop")
          |> Map.put("usage", %{
            "prompt_tokens" => 12,
            "completion_tokens" => 4,
            "total_tokens" => 16,
            "cost" => 0.00042,
            "prompt_tokens_details" => %{"cached_tokens" => 2, "cache_write_tokens" => 3},
            "completion_tokens_details" => %{"reasoning_tokens" => 1}
          })
        ),
        "data: [DONE]\n\n"
      ])
    end

    opts =
      base_opts(store, request)
      |> Keyword.merge(
        system: "Be useful",
        session_id: "session-1",
        user_id: "user-1",
        temperature: 0.3,
        max_tokens: 2_000,
        provider_preferences: %{"order" => ["openai"]},
        messages: [
          %{role: :user, content: "search"},
          %{
            role: :assistant,
            content: nil,
            tool_calls: [
              %{
                id: "call-old",
                type: "function",
                function: %{name: "search", arguments: "{\"query\":\"old\"}"}
              }
            ]
          },
          %{role: :tool, tool_call_id: "call-old", name: "search", content: "old result"}
        ],
        tools: [
          %{name: "search", description: "Search documents", input_schema: @search_schema}
        ]
      )

    assert {:ok, selection} = LLM.select([OpenRouter], "openrouter/" <> @model)
    assert {:ok, result} = LLM.generate_with(selection, nil, opts)
    assert result.data == %{"content" => "hello", "tool_calls" => []}
    assert result.model == @model
    assert result.provider == "openrouter"

    assert %Usage{
             input_tokens: 7,
             output_tokens: 4,
             cache_read_tokens: 2,
             cache_write_tokens: 3,
             reasoning_tokens: 1,
             total_tokens: 16,
             cost: 0.00042,
             currency: "USD"
           } = result.usage

    refute result.usage.cost_estimated
    # The billed cost has no price-card breakdown that would not add up to it.
    assert result.usage.cost_breakdown == nil

    assert_receive {:request, request_options}
    assert request_options[:url] == "https://openrouter.ai/api/v1/chat/completions"
    assert request_options[:retry] == false
    assert header(request_options, "authorization") == "Bearer stored-key"
    assert header(request_options, "accept") == "text/event-stream"
    assert header(request_options, "http-referer") == nil
    assert header(request_options, "x-title") == nil

    assert {:ok, body} = JSON.decode(request_options[:body])
    assert body["model"] == @model
    assert body["stream"] == true
    assert body["session_id"] == "session-1"
    assert body["user"] == "user-1"
    assert body["temperature"] == 0.3
    assert body["max_tokens"] == 2_000
    assert body["provider"] == %{"order" => ["openai"]}
    refute Map.has_key?(body, "cache_control")
    refute Map.has_key?(body, "reasoning")

    assert [
             %{"role" => "system", "content" => "Be useful"},
             %{"role" => "user", "content" => "search"},
             %{"role" => "assistant", "content" => nil, "tool_calls" => [old_call]},
             %{"role" => "tool", "tool_call_id" => "call-old", "content" => "old result"}
           ] = body["messages"]

    assert old_call["function"]["arguments"] == "{\"query\":\"old\"}"

    assert [
             %{
               "type" => "function",
               "function" => %{"name" => "search", "parameters" => @search_schema}
             }
           ] = body["tools"]

    assert body["tool_choice"] == "auto"
  end

  test "enables automatic prompt caching for Anthropic models", %{store: store} do
    test_pid = self()
    request = capture_body(test_pid, @claude)

    assert {:ok, _result} =
             generate(nil, base_opts(store, request) |> Keyword.put(:model, @claude))

    assert_receive {:body, body}
    assert body["cache_control"] == %{"type" => "ephemeral"}

    opts = base_opts(store, request) |> Keyword.merge(model: @claude, cache_control: false)
    assert {:ok, _result} = generate(nil, opts)
    assert_receive {:body, body}
    refute Map.has_key?(body, "cache_control")

    opts = Keyword.put(opts, :cache_control, %{type: "ephemeral", ttl: "1h"})
    assert {:ok, _result} = generate(nil, opts)
    assert_receive {:body, body}
    assert body["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}

    assert {:error, {:invalid_cache_control, :yes}} =
             generate(nil, Keyword.put(opts, :cache_control, :yes))
  end

  test "sends attribution headers only when configured", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:request, options})
      streaming_response(options, [sse(chunk(@model, %{"content" => "ok"}, "stop")), done()])
    end

    opts =
      base_opts(store, request)
      |> Keyword.merge(app_url: "https://example.test", app_title: "Example")

    assert {:ok, _result} = generate(nil, opts)
    assert_receive {:request, options}
    assert header(options, "http-referer") == "https://example.test"
    assert header(options, "x-title") == "Example"
  end

  test "streams reasoning, reasoning details, and tool arguments across chunk boundaries", %{
    store: store
  } do
    wire =
      Enum.join([
        sse(
          chunk(@claude, %{
            "reasoning" => "consider",
            "reasoning_details" => [
              %{"type" => "reasoning.text", "text" => "consider", "index" => 0, "format" => "f"}
            ]
          })
        ),
        sse(
          chunk(@claude, %{
            "reasoning" => "ing",
            "reasoning_details" => [
              %{"type" => "reasoning.text", "text" => "ing", "signature" => "sig", "index" => 0}
            ]
          })
        ),
        sse(
          chunk(@claude, %{
            "reasoning_details" => [
              %{"type" => "reasoning.encrypted", "data" => "opaque", "index" => 1}
            ]
          })
        ),
        sse(
          chunk(@claude, %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call-1",
                "function" => %{"name" => "search", "arguments" => "{\"query\":"}
              }
            ]
          })
        ),
        sse(
          chunk(
            @claude,
            %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\"cats\"}"}}]},
            "tool_calls"
          )
        ),
        sse(
          chunk(@claude, %{"content" => ""}, "tool_calls")
          |> Map.put("usage", %{"prompt_tokens" => 8, "completion_tokens" => 5})
        ),
        done()
      ])

    request = fn options -> streaming_response(options, split_binary(wire, [7, 31, 3, 89])) end
    opts = base_opts(store, request) |> Keyword.put(:model, @claude)

    assert {:ok, result} =
             OpenRouter.stream(nil, opts, fn event -> send(self(), {:event, event}) end)

    assert result.data == %{
             "thinking" => "considering",
             "tool_calls" => [
               %{"id" => "call-1", "name" => "search", "arguments" => "{\"query\":\"cats\"}"}
             ]
           }

    assert result.provider_state == %{
             "reasoning" => "considering",
             "reasoning_details" => [
               %{
                 "type" => "reasoning.text",
                 "text" => "considering",
                 "signature" => "sig",
                 "index" => 0,
                 "format" => "f"
               },
               %{"type" => "reasoning.encrypted", "data" => "opaque", "index" => 1}
             ]
           }

    assert_receive {:event, %{type: :reasoning_delta, delta: "consider"}}
    assert_receive {:event, %{type: :reasoning_delta, delta: "ing"}}
    assert_receive {:event, %{type: :tool_input_delta, delta: "{\"query\":", tool_name: "search"}}
    assert_receive {:event, %{type: :tool_input_delta, delta: "\"cats\"}"}}
    assert_receive {:event, %{type: :usage}}
  end

  test "replays reasoning only for the same provider and model", %{store: store} do
    test_pid = self()
    request = capture_body(test_pid, @claude)
    details = [%{"type" => "reasoning.encrypted", "data" => "opaque"}]

    history = fn provider_state ->
      [
        %{role: :user, content: "go"},
        %{
          role: :assistant,
          content: "",
          tool_calls: [%{id: "call-1", function: %{name: "search", arguments: "{}"}}],
          provider_state: provider_state
        },
        %{role: :tool, tool_call_id: "call-1", content: "result"}
      ]
    end

    run = fn provider_state ->
      opts =
        base_opts(store, request)
        |> Keyword.merge(model: @claude, messages: history.(provider_state))

      assert {:ok, _result} = LLM.generate_with(selection(opts), nil, opts)
      assert_receive {:body, body}
      Enum.at(body["messages"], 1)
    end

    state = %{"provider" => "openrouter", "model" => @claude, "reasoning" => "text"}

    assert %{"reasoning_details" => ^details} =
             assistant = run.(Map.put(state, "reasoning_details", details))

    refute Map.has_key?(assistant, "reasoning")
    assert %{"reasoning" => "text"} = run.(state)

    for foreign <- [
          %{state | "model" => "anthropic/claude-opus-5.5"},
          %{state | "provider" => "anthropic"},
          %{state | "provider" => "openrouter-work"},
          nil
        ] do
      assistant = run.(foreign)
      refute Map.has_key?(assistant, "reasoning")
      refute Map.has_key?(assistant, "reasoning_details")
    end
  end

  describe "provider instances" do
    setup %{store: {CredentialStore, agent}} do
      Agent.update(agent, fn credentials ->
        Map.merge(credentials, %{
          "openrouter-work" => %{"api_key" => "work-key"},
          "openrouter-home" => %{"api_key" => "home-key"}
        })
      end)
    end

    test "only the default provider falls back to OPENROUTER_API_KEY" do
      test_pid = self()

      request = fn options ->
        send(test_pid, {:authorization, header(options, "authorization")})
        streaming_response(options, [sse(chunk(@model, %{"content" => "ok"}, "stop")), done()])
      end

      empty = start_supervised!({Agent, fn -> %{} end}, id: {Agent, make_ref()})
      opts = base_opts({CredentialStore, empty}, request)
      work = Keyword.put(opts, :provider_id, "openrouter-work")

      with_env(%{"OPENROUTER_API_KEY" => "default-key", "WORK_KEY" => "work-key"}, fn ->
        assert {:ok, %{provider: "openrouter"}} = LLM.generate_with(selection(opts), nil, opts)
        assert_receive {:authorization, "Bearer default-key"}

        assert {:error, {:missing_openrouter_api_key, "openrouter-work"}} =
                 generate(nil, work)

        refute_received {:authorization, _header}

        # A provider names its own variable with "api_key_env".
        named = Keyword.put(work, :provider_settings, %{"api_key_env" => "WORK_KEY"})

        assert {:ok, %{provider: "openrouter-work"}} =
                 LLM.generate_with(selection(named), nil, named)

        assert_receive {:authorization, "Bearer work-key"}

        invalid = Keyword.put(work, :provider_settings, %{"api_key_env" => ""})

        assert {:error, {:invalid_provider_setting, "openrouter-work", "api_key_env", ""}} =
                 generate(nil, invalid)
      end)
    end

    test "providers on one adapter use their own API keys", %{store: store} do
      test_pid = self()

      request = fn options ->
        send(test_pid, {:authorization, header(options, "authorization")})
        streaming_response(options, [sse(chunk(@model, %{"content" => "ok"}, "stop")), done()])
      end

      {:ok, work} = Provider.new("openrouter-work", OpenRouter)
      {:ok, home} = Provider.new("openrouter-home", OpenRouter)
      opts = base_opts(store, request) |> Keyword.delete(:model)

      assert {:ok, selection} = LLM.select([work, home], "openrouter-home/" <> @model)
      assert {:ok, %{provider: "openrouter-home"}} = LLM.generate_with(selection, nil, opts)
      assert_receive {:authorization, "Bearer home-key"}

      assert {:ok, selection} = LLM.select([work, home], "openrouter-work/" <> @model)
      assert {:ok, %{provider: "openrouter-work"}} = LLM.generate_with(selection, nil, opts)
      assert_receive {:authorization, "Bearer work-key"}

      key_request = fn options ->
        send(test_pid, {:authorization, header(options, "authorization")})
        {:ok, %Req.Response{status: 200, body: JSON.encode!(%{"data" => %{}})}}
      end

      assert {:ok, %{}} =
               OpenRouter.usage(
                 credential_store: store,
                 request: key_request,
                 provider_id: "openrouter-work"
               )

      assert_receive {:authorization, "Bearer work-key"}
    end

    test "stamps reasoning state with the provider id and replays it only there", %{
      store: store
    } do
      test_pid = self()

      request = fn options ->
        send(test_pid, {:body, JSON.decode!(options[:body])})

        streaming_response(options, [
          sse(chunk(@claude, %{"reasoning" => "thought"})),
          sse(chunk(@claude, %{"content" => "ok"}, "stop")),
          done()
        ])
      end

      work_opts =
        base_opts(store, request)
        |> Keyword.merge(model: @claude, provider_id: "openrouter-work")

      assert {:ok, result} = LLM.generate_with(selection(work_opts), nil, work_opts)
      assert result.provider_state["provider"] == "openrouter-work"
      assert result.provider_state["model"] == @claude
      assert_receive {:body, _first}

      messages = [
        %{role: :user, content: "go"},
        %{role: :assistant, content: "ok", provider_state: result.provider_state},
        %{role: :user, content: "again"}
      ]

      replay_opts = Keyword.put(work_opts, :messages, messages)
      assert {:ok, _} = LLM.generate_with(selection(replay_opts), nil, replay_opts)

      assert_receive {:body, body}
      assert %{"reasoning" => "thought"} = Enum.at(body["messages"], 1)

      home_opts = Keyword.merge(work_opts, provider_id: "openrouter-home", messages: messages)
      assert {:ok, _} = LLM.generate_with(selection(home_opts), nil, home_opts)
      assert_receive {:body, body}
      refute Map.has_key?(Enum.at(body["messages"], 1), "reasoning")
    end

    test "honours the base_url setting unless :base_url is explicit", %{store: store} do
      test_pid = self()

      request = fn options ->
        send(test_pid, {:url, options[:url]})
        streaming_response(options, [sse(chunk(@model, %{"content" => "ok"}, "stop")), done()])
      end

      opts =
        base_opts(store, request)
        |> Keyword.merge(
          provider_id: "openrouter-work",
          provider_settings: %{"base_url" => "https://proxy.test/api/v1/"}
        )

      assert {:ok, _} = generate(nil, opts)
      assert_receive {:url, "https://proxy.test/api/v1/chat/completions"}

      assert {:ok, _} =
               generate(nil, Keyword.put(opts, :base_url, "https://explicit.test"))

      assert_receive {:url, "https://explicit.test/chat/completions"}

      invalid = Keyword.put(opts, :provider_settings, %{"base_url" => nil})

      assert {:error, {:invalid_provider_setting, "openrouter-work", "base_url", nil}} =
               generate(nil, invalid)
    end
  end

  test "keeps repeated request projections byte-identical", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:raw_body, options[:body]})
      streaming_response(options, [sse(chunk(@claude, %{"content" => "ok"}, "stop")), done()])
    end

    opts =
      base_opts(store, request)
      |> Keyword.merge(
        model: @claude,
        system: "stable",
        session_id: "s",
        messages: [
          %{role: :user, content: "a"},
          %{
            role: :assistant,
            content: "b",
            tool_calls: [%{id: "c", function: %{name: "t", arguments: "{\"z\":1,\"a\":2}"}}]
          },
          %{role: :tool, tool_call_id: "c", content: "r"}
        ]
      )

    assert {:ok, _} = generate(nil, opts)
    assert {:ok, _} = generate(nil, opts)
    assert_receive {:raw_body, first}
    assert_receive {:raw_body, second}
    assert first == second
    assert first =~ ~s({\\"z\\":1,\\"a\\":2})
  end

  test "replaces image tool content with a text note", %{store: store} do
    test_pid = self()
    request = capture_body(test_pid, @model)

    opts =
      base_opts(store, request)
      |> Keyword.put(:messages, [
        %{role: :user, content: "look"},
        %{role: :assistant, tool_calls: [%{id: "c", function: %{name: "shot", arguments: %{}}}]},
        %{
          role: :tool,
          tool_call_id: "c",
          content: [
            %{"type" => "text", "text" => "captured"},
            %{"type" => "image", "media_type" => "image/png", "data" => "iVBOR"}
          ]
        }
      ])

    assert {:ok, _result} = generate(nil, opts)
    assert_receive {:body, body}
    tool = List.last(body["messages"])
    assert tool["content"] =~ "captured\n[image content omitted"
    refute tool["content"] =~ "iVBOR"
  end

  test "rejects malformed or unpaired historical tool calls before requesting", %{store: store} do
    request = fn _options -> flunk("must not request") end

    unpaired = [
      %{role: :assistant, tool_calls: [%{id: "c", function: %{name: "t", arguments: "{}"}}]},
      %{role: :user, content: "next"}
    ]

    assert {:error, {:invalid_tool_history, :missing_tool_results}} =
             generate(
               nil,
               base_opts(store, request) |> Keyword.put(:messages, unpaired)
             )

    malformed = [
      %{role: :assistant, tool_calls: [%{id: "c", function: %{name: "t", arguments: "[]"}}]}
    ]

    assert {:error, :invalid_tool_call} =
             generate(
               nil,
               base_opts(store, request) |> Keyword.put(:messages, malformed)
             )
  end

  test "requests JSON-schema output and parses a structured response", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:body, JSON.decode!(options[:body])})

      streaming_response(options, [
        sse(chunk(@model, %{"content" => "{\"answer\":"})),
        sse(chunk(@model, %{"content" => "42}"}, "stop")),
        done()
      ])
    end

    # `Tackle.Lib.LLM` converts the keyword schema to JSON Schema.
    schema = [answer: [type: :integer, required: true]]
    opts = base_opts(store, request)
    assert {:ok, result} = LLM.generate_with(selection(opts), schema, opts)
    assert result.data == %{"answer" => 42}

    assert_receive {:body, body}

    assert %{"type" => "json_schema", "json_schema" => %{"name" => "response", "schema" => s}} =
             body["response_format"]

    assert s["required"] == ["answer"]
    assert [%{"role" => "system", "content" => instruction} | _] = body["messages"]
    assert instruction =~ "JSON Schema"
  end

  test "maps reasoning effort to OpenRouter's unified reasoning parameter", %{store: store} do
    test_pid = self()
    request = capture_body(test_pid, @model)

    levels = for level <- Thinking.levels(), level != "off", do: {level, level}
    atoms = [low: "low", high: "high", max: "max", off: "none"]

    for {effort, expected} <- levels ++ atoms ++ [{"off", "none"}, {"none", "none"}] do
      opts = base_opts(store, request) |> Keyword.put(:reasoning_effort, effort)
      assert {:ok, _result} = generate(nil, opts)
      assert_receive {:body, %{"reasoning" => %{"effort" => ^expected}}}
    end

    for invalid <- ["extreme", 3] do
      assert {:error, {:invalid_reasoning_effort, _}} =
               generate(
                 nil,
                 base_opts(store, request) |> Keyword.put(:reasoning_effort, invalid)
               )
    end
  end

  describe "stream validation" do
    test "surfaces a mid-stream provider error on a committed response", %{store: store} do
      request = fn options ->
        error = %{"code" => "server_error", "message" => "Provider disconnected"}

        streaming_response(options, [
          sse(chunk(@model, %{"content" => "partial"})),
          sse(chunk(@model, %{"content" => ""}, "error") |> Map.put("error", error)),
          done()
        ])
      end

      assert {:error, %Error{kind: :server, details: %{"code" => "server_error"}} = error} =
               generate(nil, base_opts(store, request))

      assert Tackle.Lib.Retry.retryable?(error)
    end

    test "rejects output after the finish reason", %{store: store} do
      request = fn options ->
        streaming_response(options, [
          sse(chunk(@model, %{"content" => "done"}, "stop")),
          sse(chunk(@model, %{"content" => "more"})),
          done()
        ])
      end

      assert {:error, %Error{kind: :invalid_response, details: :data_after_finish_reason}} =
               generate(nil, base_opts(store, request))
    end

    test "reports truncated and unterminated streams", %{store: store} do
      length = fn options ->
        streaming_response(options, [sse(chunk(@model, %{"content" => "x"}, "length")), done()])
      end

      assert {:error, %Error{kind: :invalid_response, details: {:incomplete_response, "length"}}} =
               generate(nil, base_opts(store, length))

      no_done = fn options ->
        streaming_response(options, [sse(chunk(@model, %{"content" => "x"}, "stop"))])
      end

      assert {:error, %Error{kind: :transport, details: :stream_ended_without_done}} =
               generate(nil, base_opts(store, no_done))

      no_finish = fn options ->
        streaming_response(options, [sse(chunk(@model, %{"content" => "x"})), done()])
      end

      assert {:error, %Error{kind: :transport, details: :stream_ended_without_finish_reason}} =
               generate(nil, base_opts(store, no_finish))
    end

    test "treats a call without argument fragments as an empty object", %{store: store} do
      request = fn options ->
        streaming_response(options, [
          sse(
            chunk(
              @model,
              %{"tool_calls" => [%{"index" => 0, "id" => "c", "function" => %{"name" => "now"}}]},
              "tool_calls"
            )
          ),
          done()
        ])
      end

      assert {:ok, %{data: %{"tool_calls" => [%{"arguments" => "{}"}]}}} =
               generate(nil, base_opts(store, request))
    end

    test "rejects malformed reasoning details", %{store: store} do
      for detail <- [%{"text" => "no type"}, "not a map", %{"type" => "reasoning.encrypted"}] do
        request = fn options ->
          streaming_response(options, [
            sse(chunk(@model, %{"reasoning_details" => [detail]}, "stop")),
            done()
          ])
        end

        assert {:error, %Error{kind: :invalid_response, details: :invalid_reasoning_details}} =
                 generate(nil, base_opts(store, request))
      end
    end

    test "keeps distinct reasoning blocks and unknown detail types apart", %{store: store} do
      details = [
        [%{"type" => "reasoning.text", "text" => "a", "index" => 0}],
        [%{"type" => "reasoning.text", "text" => "b", "signature" => "s0", "index" => 0}],
        [%{"type" => "reasoning.text", "text" => "c", "signature" => "s1", "index" => 1}],
        [%{"type" => "reasoning.future", "payload" => "x"}]
      ]

      request = fn options ->
        frames = Enum.map(details, &sse(chunk(@model, %{"reasoning_details" => &1})))
        streaming_response(options, frames ++ [sse(chunk(@model, %{}, "stop")), done()])
      end

      assert {:ok, %{provider_state: %{"reasoning_details" => replay}}} =
               generate(nil, base_opts(store, request))

      assert replay == [
               %{"type" => "reasoning.text", "text" => "ab", "signature" => "s0", "index" => 0},
               %{"type" => "reasoning.text", "text" => "c", "signature" => "s1", "index" => 1},
               %{"type" => "reasoning.future", "payload" => "x"}
             ]
    end

    test "rejects a changed finish reason after the terminal frame", %{store: store} do
      request = fn options ->
        streaming_response(options, [
          sse(chunk(@model, %{"content" => "done"}, "stop")),
          sse(chunk(@model, %{"content" => ""}, "length")),
          done()
        ])
      end

      assert {:error, %Error{kind: :invalid_response, details: :data_after_finish_reason}} =
               generate(nil, base_opts(store, request))
    end

    test "ignores a null error field", %{store: store} do
      request = fn options ->
        streaming_response(options, [
          sse(chunk(@model, %{"content" => "ok"}, "stop") |> Map.put("error", nil)),
          done()
        ])
      end

      assert {:ok, %{data: %{"content" => "ok"}}} =
               generate(nil, base_opts(store, request))
    end

    test "classifies an overflow on a committed stream only before any output", %{store: store} do
      error = %{"code" => 400, "message" => "prompt is too long: 2000000 tokens > 1000000"}

      before_output = fn options ->
        streaming_response(options, [
          ": OPENROUTER PROCESSING\n\n",
          sse(chunk(@model, %{}, "error") |> Map.put("error", error)),
          done()
        ])
      end

      assert {:error, %Error{kind: :context_window_exceeded}} =
               generate(nil, base_opts(store, before_output))

      after_output = fn options ->
        streaming_response(options, [
          sse(chunk(@model, %{"content" => "partial"})),
          sse(chunk(@model, %{}, "error") |> Map.put("error", error)),
          done()
        ])
      end

      assert {:error, %Error{kind: :invalid_response, details: ^error}} =
               generate(nil, base_opts(store, after_output))
    end
  end

  test "halts an active response stream after cancellation", %{store: store} do
    signal = Cancellation.new_signal()
    on_exit(fn -> Cancellation.delete(signal) end)
    test_pid = self()

    request = fn options ->
      streaming_response(options, [
        sse(chunk(@model, %{"content" => "one"})),
        sse(chunk(@model, %{"content" => "two"}, "stop")),
        done()
      ])
    end

    opts = base_opts(store, request) |> Keyword.put(:cancellation_signal, signal)

    assert {:error, :cancelled} =
             OpenRouter.stream(nil, opts, fn
               %{type: :text_delta, delta: "one"} -> Cancellation.cancel(signal)
               event -> send(test_pid, {:event, event})
             end)

    refute_received {:event, %{type: :text_delta, delta: "two"}}
  end

  test "validates model and credentials before requesting", %{store: store} do
    request = fn _options -> flunk("must not request") end

    assert {:error, {:unsupported_model, "nope/nope"}} =
             generate(
               nil,
               base_opts(store, request) |> Keyword.put(:model, "nope/nope")
             )

    assert {:error, :model_required} =
             generate(nil, base_opts(store, request) |> Keyword.delete(:model))

    previous = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")

    try do
      assert {:error, {:missing_openrouter_api_key, "openrouter"}} =
               generate(
                 nil,
                 base_opts(store, request) |> Keyword.delete(:credential_store)
               )
    after
      if previous, do: System.put_env("OPENROUTER_API_KEY", previous)
    end
  end

  test "prefers an explicit API key over stored credentials", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:request, options})
      streaming_response(options, [sse(chunk(@model, %{"content" => "ok"}, "stop")), done()])
    end

    opts = base_opts(store, request) |> Keyword.put(:api_key, "explicit-key")
    assert {:ok, _result} = generate(nil, opts)
    assert_receive {:request, options}
    assert header(options, "authorization") == "Bearer explicit-key"
  end

  test "classifies a wire context overflow as a provider-neutral error", %{store: store} do
    request = fn _options ->
      body = %{
        "error" => %{
          "code" => 400,
          "message" =>
            "This endpoint's maximum context length is 1000 tokens. However, you requested about 2000 tokens"
        }
      }

      {:ok, %Req.Response{status: 400, body: body}}
    end

    assert {:error, %Error{kind: :context_window_exceeded}} =
             generate(nil, base_opts(store, request))
  end

  test "does not classify generic errors as overflow", %{store: store} do
    for status <- [400, 402, 429] do
      request = fn _options ->
        {:ok, %Req.Response{status: status, body: %{"error" => %{"message" => "nope"}}}}
      end

      assert {:error, %Error{status: ^status, kind: kind}} =
               generate(nil, base_opts(store, request))

      refute kind == :context_window_exceeded
    end

    # Request text echoed elsewhere in the error must not look like an overflow.
    echoed = fn _options ->
      body = %{
        "error" => %{"message" => "Invalid tool schema"},
        "request" => %{"description" => "fails when there are too many tokens"}
      }

      {:ok, %Req.Response{status: 400, body: body}}
    end

    assert {:error, %Error{kind: :invalid_request, status: 400}} =
             generate(nil, base_opts(store, echoed))
  end

  test "reads error bodies streamed with a non-2xx status", %{store: store} do
    overflow =
      JSON.encode!(%{
        "error" => %{
          "code" => 400,
          "message" => "This endpoint's maximum context length is 1000 tokens."
        }
      })

    {head, tail} = String.split_at(overflow, 40)

    for wire <- [[overflow], [overflow <> "\n"], [head, tail]] do
      request = fn options -> streaming_response(options, wire, 400) end

      assert {:error, %Error{kind: :context_window_exceeded}} =
               generate(nil, base_opts(store, request))
    end

    credits = JSON.encode!(%{"error" => %{"code" => 402, "message" => "Insufficient credits"}})
    request = fn options -> streaming_response(options, [credits <> "\n"], 402) end

    assert {:error,
            %Error{
              kind: :quota_exceeded,
              status: 402,
              details: %{"error" => %{"message" => "Insufficient credits"}}
            }} =
             generate(nil, base_opts(store, request))

    request = fn options -> streaming_response(options, ["upstream exploded"], 502) end

    assert {:error,
            %Error{
              kind: :server,
              status: 502,
              message: "The provider failed (HTTP 502): upstream exploded"
            }} =
             generate(nil, base_opts(store, request))
  end

  test "normalizes API keys from every source and rejects unsafe ones", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:authorization, header(options, "authorization")})
      streaming_response(options, [sse(chunk(@model, %{"content" => "ok"}, "stop")), done()])
    end

    opts = base_opts(store, request)
    assert {:ok, _} = generate(nil, Keyword.put(opts, :api_key, " k1\n"))
    assert_receive {:authorization, "Bearer k1"}

    {CredentialStore, agent} = store
    Agent.update(agent, &Map.put(&1, "openrouter", %{"api_key" => "k2\r\n"}))
    assert {:ok, _} = generate(nil, opts)
    assert_receive {:authorization, "Bearer k2"}

    unsafe = "sk-or-secret\nInjected: header"

    assert {:error, :invalid_api_key} =
             generate(nil, Keyword.put(opts, :api_key, unsafe))

    Agent.update(agent, &Map.put(&1, "openrouter", %{"api_key" => unsafe}))
    assert {:error, :invalid_api_key} = generate(nil, opts)
  end

  test "validates provider preferences and hashes over-long session ids", %{store: store} do
    test_pid = self()
    request = capture_body(test_pid, @model)

    assert {:error, {:invalid_provider_preferences, "openai"}} =
             generate(
               nil,
               base_opts(store, request) |> Keyword.put(:provider_preferences, "openai")
             )

    assert {:ok, _} =
             generate(
               nil,
               base_opts(store, request) |> Keyword.put(:provider_preferences, order: ["openai"])
             )

    assert_receive {:body, %{"provider" => %{"order" => ["openai"]}}}

    long_id = String.duplicate("s", 300)

    opts =
      base_opts(store, request)
      |> Keyword.merge(session_id: long_id, provider_preferences: %{order: ["openai"]})

    assert {:ok, _} = generate(nil, opts)
    assert_receive {:body, body}
    assert body["provider"] == %{"order" => ["openai"]}
    assert body["session_id"] == :crypto.hash(:sha256, long_id) |> Base.encode16(case: :lower)
  end

  describe "per-model provider routing" do
    setup do
      on_exit(fn -> Application.delete_env(:tackle_openrouter, :provider_routing) end)
    end

    test "pins a configured model to its provider endpoint", %{store: store} do
      Application.put_env(:tackle_openrouter, :provider_routing, %{
        "z-ai/glm-5.3" => [only: ["mistral/zdr"], allow_fallbacks: false, zdr: true]
      })

      test_pid = self()
      glm = capture_body(test_pid, "z-ai/glm-5.3")

      assert {:ok, _} =
               generate(
                 nil,
                 base_opts(store, glm) |> Keyword.put(:model, "z-ai/glm-5.3")
               )

      assert_receive {:body, body}

      assert body["provider"] == %{
               "only" => ["mistral/zdr"],
               "allow_fallbacks" => false,
               "zdr" => true
             }

      # Models without a route keep OpenRouter's default load balancing.
      assert {:ok, _} = generate(nil, base_opts(store, capture_body(test_pid, @model)))
      assert_receive {:body, body}
      refute Map.has_key?(body, "provider")
    end

    test "lets request preferences override individual routed fields", %{store: store} do
      Application.put_env(:tackle_openrouter, :provider_routing, [
        {@model, %{only: ["openai"], allow_fallbacks: false}}
      ])

      opts =
        base_opts(store, capture_body(self(), @model))
        |> Keyword.put(:provider_preferences, %{"allow_fallbacks" => true, "sort" => "latency"})

      assert {:ok, _} = generate(nil, opts)
      assert_receive {:body, body}

      assert body["provider"] == %{
               "only" => ["openai"],
               "allow_fallbacks" => true,
               "sort" => "latency"
             }
    end

    test "reads user routes from provider settings over configured ones", %{store: store} do
      Application.put_env(:tackle_openrouter, :provider_routing, %{
        "z-ai/glm-5.3" => %{only: ["z-ai"], sort: "price"},
        @model => %{only: ["openai"]}
      })

      settings = %{
        "provider_routing" => %{
          "z-ai/glm-5.3" => %{"only" => ["mistral/zdr"], "allow_fallbacks" => false}
        }
      }

      opts =
        base_opts(store, capture_body(self(), "z-ai/glm-5.3"))
        |> Keyword.merge(model: "z-ai/glm-5.3", provider_settings: settings)

      assert {:ok, _} = generate(nil, opts)
      assert_receive {:body, body}
      # The user's route replaces the configured one for that model.
      assert body["provider"] == %{"only" => ["mistral/zdr"], "allow_fallbacks" => false}

      # Configured routes stay the defaults for models the settings leave out.
      other =
        Keyword.merge(opts, model: @model, request: capture_body(self(), @model))

      assert {:ok, _} = generate(nil, other)
      assert_receive {:body, body}
      assert body["provider"] == %{"only" => ["openai"]}

      bad = Keyword.put(opts, :provider_settings, %{"provider_routing" => "mistral"})
      assert {:error, {:invalid_provider_routing, "mistral"}} = generate(nil, bad)
    end

    test "rejects malformed routing configuration before requesting", %{store: store} do
      request = fn _options -> flunk("must not request") end

      Application.put_env(:tackle_openrouter, :provider_routing, %{@model => "openai"})

      assert {:error, {:invalid_provider_routing, @model, "openai"}} =
               generate(nil, base_opts(store, request))

      Application.put_env(:tackle_openrouter, :provider_routing, :openai)

      assert {:error, {:invalid_provider_routing, :openai}} =
               generate(nil, base_opts(store, request))
    end
  end

  test "returns an error for options that cannot be encoded", %{store: store} do
    request = fn _options -> flunk("must not request") end
    opts = base_opts(store, request) |> Keyword.put(:stop, {:not, :json})

    assert {:error, {:invalid_request_body, _message}} = generate(nil, opts)
  end

  describe "account flows" do
    test "login prompts for an API key through the interaction handle" do
      assert {:ok, %{"api_key" => "prompted-key"}} =
               OpenRouter.login(interaction: {Interaction, self()})

      assert_receive {:interaction_prompt, opts}
      assert opts[:secret] == true
    end

    test "login rejects an empty API key and requires an interaction handle" do
      Process.put(:prompt_result, {:ok, "   "})
      assert {:error, :empty_api_key} = OpenRouter.login(interaction: {Interaction, self()})
      assert {:error, :interaction_required} = OpenRouter.login([])
    after
      Process.delete(:prompt_result)
    end

    test "usage returns the key's credit report", %{store: store} do
      test_pid = self()
      data = %{"label" => "tackle", "usage" => 1.5, "limit" => 10, "limit_remaining" => 8.5}

      request = fn options ->
        send(test_pid, {:key_request, options})
        {:ok, %Req.Response{status: 200, body: JSON.encode!(%{"data" => data})}}
      end

      assert {:ok, ^data} = OpenRouter.usage(credential_store: store, request: request)
      assert_receive {:key_request, options}
      assert options[:method] == :get
      assert options[:url] == "https://openrouter.ai/api/v1/key"
      assert header(options, "authorization") == "Bearer stored-key"
    end

    test "usage surfaces provider errors", %{store: store} do
      request = fn _options -> {:ok, %Req.Response{status: 401, body: "unauthorized"}} end

      assert {:error, %Error{kind: :auth, status: 401, details: "unauthorized"}} =
               OpenRouter.usage(credential_store: store, request: request)
    end
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)
    System.put_env(vars)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  # The adapter has no `generate/2`; `Tackle.Lib.LLM` streams it with a
  # callback that drops the events.
  defp generate(schema, opts), do: OpenRouter.stream(schema, opts, fn _event -> :ok end)

  # The LLM boundary calls an adapter through a selection: here the provider
  # and model the options name.
  defp selection(opts) do
    id = Keyword.get(opts, :provider_id, "openrouter")
    {:ok, provider} = Provider.new(id, OpenRouter, Keyword.get(opts, :provider_settings, %{}))
    {:ok, selection} = LLM.select([provider], id <> "/" <> Keyword.fetch!(opts, :model))
    selection
  end

  defp base_opts(store, request) do
    [
      model: @model,
      messages: [%{role: :user, content: "hello"}],
      tools: [],
      credential_store: store,
      request: request
    ]
  end

  defp capture_body(test_pid, model) do
    fn options ->
      send(test_pid, {:body, JSON.decode!(options[:body])})
      streaming_response(options, [sse(chunk(model, %{"content" => "ok"}, "stop")), done()])
    end
  end

  defp chunk(model, delta, finish_reason \\ nil) do
    %{
      "id" => "gen-1",
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }
  end

  defp streaming_response(options, chunks, status \\ 200) do
    into = Keyword.fetch!(options, :into)
    initial = {%Req.Request{}, %Req.Response{status: status, headers: %{}, body: ""}}

    {_request, response} =
      Enum.reduce_while(chunks, initial, fn chunk, pair ->
        case into.({:data, chunk}, pair) do
          {:cont, next_pair} -> {:cont, next_pair}
          {:halt, next_pair} -> {:halt, next_pair}
        end
      end)

    {:ok, response}
  end

  defp sse(event), do: "data: #{JSON.encode!(event)}\n\n"
  defp done, do: "data: [DONE]\n\n"

  defp header(options, name) do
    options
    |> Keyword.fetch!(:headers)
    |> Enum.find_value(fn {key, value} -> if key == name, do: value end)
  end

  defp split_binary(binary, sizes) do
    {chunks, rest} =
      Enum.map_reduce(sizes, binary, fn size, remaining ->
        size = min(size, byte_size(remaining))
        <<chunk::binary-size(^size), rest::binary>> = remaining
        {chunk, rest}
      end)

    chunks ++ [rest]
  end
end
