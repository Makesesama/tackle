defmodule Tackle.Plugins.DeepSeekTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.{Cancellation, LLM, ModelInfo, Usage}
  alias Tackle.Plugins.DeepSeek

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
    def info(reference, message) do
      send(reference, {:interaction_info, IO.iodata_to_binary(message)})
      :ok
    end

    @impl true
    def prompt(reference, opts) do
      send(reference, {:interaction_prompt, opts})
      Process.get(:prompt_result) || {:ok, "  prompted-key  "}
    end

    @impl true
    def confirm(_reference, _message), do: false

    @impl true
    def progress(reference, opts, fun) do
      send(reference, {:interaction_progress, Keyword.get(opts, :label)})
      fun.()
    end
  end

  setup do
    start_supervised!({Agent, fn -> %{DeepSeek.adapter_id() => %{"api_key" => "stored-key"}} end},
      id: {Agent, make_ref()}
    )
    |> then(&{:ok, store: {CredentialStore, &1}})
  end

  test "exposes selectable models with limits and price cards" do
    assert DeepSeek.adapter_id() == "deepseek"

    assert DeepSeek.models() == [
             "deepseek-flash",
             "deepseek-v4-flash",
             "deepseek-v4-flash-vision-exp",
             "deepseek-v4-pro"
           ]

    assert {:ok, %ModelInfo{} = flash} = LLM.model_info(DeepSeek, "deepseek-flash")
    assert flash.context_window == 1_000_000
    assert flash.max_output_tokens == 256_000
    assert flash.pricing.input == 0.3
    assert flash.pricing.output == 1.2
    assert flash.pricing.cache_read == 0.006
    assert flash.pricing.currency == "USD"
    assert flash.pricing.unit_tokens == 1_000_000

    Enum.each(["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"], fn model ->
      assert {:ok, %ModelInfo{} = info} = LLM.model_info(DeepSeek, model)
      assert info.context_window == 1_000_000
      assert info.max_output_tokens == 384_000
      assert info.pricing.input == 0.14
      assert info.pricing.output == 0.28
      assert info.pricing.cache_read == 0.0028
      assert info.pricing.cache_write == 0
    end)

    assert {:ok, %ModelInfo{} = pro} = LLM.model_info(DeepSeek, "deepseek-v4-pro")
    assert pro.context_window == 1_000_000
    assert pro.max_output_tokens == 384_000
    assert pro.pricing.input == 0.435
    assert pro.pricing.output == 0.87
    assert pro.pricing.cache_read == 0.003625
    assert pro.pricing.cache_write == 0

    assert {:ok, nil} = LLM.model_info(DeepSeek, "unknown")
    assert {:ok, selection} = LLM.select([DeepSeek], "deepseek/deepseek-flash")
    assert selection.model == "deepseek-flash"
    assert {:ok, pro_selection} = LLM.select([DeepSeek], "deepseek/deepseek-v4-pro")
    assert pro_selection.model == "deepseek-v4-pro"
  end

  test "translates messages and tools and normalizes DeepSeek cache usage", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:request, options})

      streaming_response(options, [
        sse(%{
          "id" => "chat-1",
          "model" => "deepseek-flash",
          "choices" => [%{"index" => 0, "delta" => %{"content" => "hel"}, "finish_reason" => nil}]
        }),
        sse(%{
          "id" => "chat-1",
          "model" => "deepseek-flash",
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "lo"}, "finish_reason" => "stop"}
          ],
          "usage" => %{
            "prompt_tokens" => 12,
            "completion_tokens" => 4,
            "total_tokens" => 16,
            "prompt_cache_hit_tokens" => 2,
            "prompt_cache_miss_tokens" => 10,
            "completion_tokens_details" => %{"reasoning_tokens" => 1}
          }
        }),
        "data: [DONE]\n\n"
      ])
    end

    opts =
      base_opts(store, request)
      |> Keyword.merge(
        system: "Be useful",
        temperature: 0.3,
        max_tokens: 2_000,
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
          %{
            name: "search",
            description: "Search documents",
            input_schema: [query: [type: :string, required: true, description: "Query"]]
          }
        ]
      )

    assert {:ok, selection} = LLM.select([DeepSeek], "deepseek/deepseek-flash")
    assert {:ok, result} = LLM.generate_with(selection, nil, opts)
    assert result.data == %{"content" => "hello", "tool_calls" => []}
    assert result.model == "deepseek-flash"
    assert result.provider == "deepseek"

    assert %Usage{
             input_tokens: 10,
             output_tokens: 4,
             cache_read_tokens: 2,
             cache_write_tokens: 0,
             reasoning_tokens: 1,
             total_tokens: 16,
             cost_estimated: true,
             currency: "USD"
           } = result.usage

    assert_receive {:request, request_options}
    assert request_options[:url] == "https://api.deepseek.com/chat/completions"
    assert header(request_options, "authorization") == "Bearer stored-key"
    assert header(request_options, "accept") == "text/event-stream"

    assert {:ok, body} = JSON.decode(request_options[:body])
    assert body["model"] == "deepseek-flash"
    assert body["stream"] == true
    assert body["stream_options"] == %{"include_usage" => true}
    assert body["temperature"] == 0.3
    assert body["max_tokens"] == 2_000

    assert [
             %{"role" => "system", "content" => "Be useful"},
             %{"role" => "user"},
             %{"role" => "assistant", "tool_calls" => [old_call]},
             %{"role" => "tool", "tool_call_id" => "call-old"}
           ] = body["messages"]

    assert old_call["function"]["arguments"] == "{\"query\":\"old\"}"
    assert Enum.at(body["messages"], 2)["content"] == ""
    assert request_options[:retry] == false

    assert [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "search",
                 "parameters" => parameters,
                 "strict" => false
               }
             }
           ] = body["tools"]

    assert parameters["required"] == ["query"]
    assert body["tool_choice"] == "auto"
  end

  test "streams reasoning and tool argument deltas across chunk boundaries", %{store: store} do
    wire =
      Enum.join([
        sse(%{
          "model" => "deepseek-v4-pro",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"reasoning_content" => "considering"},
              "finish_reason" => nil
            }
          ]
        }),
        sse(%{
          "model" => "deepseek-v4-pro",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call-1",
                    "function" => %{"name" => "search", "arguments" => "{\"query\":"}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        }),
        sse(%{
          "model" => "deepseek-v4-pro",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{"index" => 0, "function" => %{"arguments" => "\"cats\"}"}}
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{
            "prompt_tokens" => 8,
            "completion_tokens" => 5,
            "total_tokens" => 13,
            "prompt_cache_hit_tokens" => 3
          }
        }),
        "data: [DONE]\n\n"
      ])

    request = fn options -> streaming_response(options, split_binary(wire, [7, 31, 3, 89])) end
    opts = base_opts(store, request) |> Keyword.put(:model, "deepseek-v4-pro")

    assert {:ok, result} =
             DeepSeek.stream(nil, opts, fn event -> send(self(), {:event, event}) end)

    assert result.data == %{
             "thinking" => "considering",
             "tool_calls" => [
               %{"id" => "call-1", "name" => "search", "arguments" => "{\"query\":\"cats\"}"}
             ]
           }

    assert result.provider_state == %{
             "provider" => "deepseek",
             "model" => "deepseek-v4-pro",
             "reasoning_content" => "considering"
           }

    assert_receive {:event, %{type: :reasoning_delta, delta: "considering"}}
    assert_receive {:event, %{type: :tool_input_delta, delta: "{\"query\":"}}
    assert_receive {:event, %{type: :tool_input_delta, delta: "\"cats\"}"}}
    assert_receive {:event, %{type: :usage}}
  end

  test "replays V4 Pro reasoning only for the same provider and model", %{store: store} do
    test_pid = self()

    request = fn options ->
      {:ok, body} = JSON.decode(options[:body])
      send(test_pid, {:body, body})

      streaming_response(options, [
        sse(%{
          "model" => "deepseek-v4-pro",
          "choices" => [%{"delta" => %{"content" => "done"}, "finish_reason" => "stop"}]
        }),
        "data: [DONE]\n\n"
      ])
    end

    provider_state = %{
      "provider" => "deepseek",
      "model" => "deepseek-v4-pro",
      "reasoning_content" => "previous reasoning"
    }

    opts =
      base_opts(store, request)
      |> Keyword.merge(
        model: "deepseek-v4-pro",
        messages: [
          %{
            role: :assistant,
            content: nil,
            tool_calls: [
              %{id: "call-1", function: %{name: "search", arguments: "{}"}}
            ],
            provider_state: provider_state
          },
          %{role: :tool, tool_call_id: "call-1", content: "result"}
        ]
      )

    assert {:ok, _result} = DeepSeek.generate(nil, opts)
    assert_receive {:body, body}
    assert [%{"reasoning_content" => "previous reasoning"}, _tool] = body["messages"]
  end

  test "replaces structured tool content with a text note for the text-only wire format", %{
    store: store
  } do
    test_pid = self()

    request = fn options ->
      {:ok, body} = JSON.decode(options[:body])
      send(test_pid, {:body, body})

      streaming_response(options, [
        sse(%{
          "model" => "deepseek-flash",
          "choices" => [%{"delta" => %{"content" => "done"}, "finish_reason" => "stop"}]
        }),
        "data: [DONE]\n\n"
      ])
    end

    messages = [
      %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "call-1", function: %{name: "read", arguments: "{}"}}]
      },
      %{
        role: :tool,
        tool_call_id: "call-1",
        name: "read",
        content: [
          %{"type" => "text", "text" => "Read image shot.png (image/png)."},
          %{"type" => "image", "media_type" => "image/png", "data" => "aGVsbG8="}
        ]
      }
    ]

    opts =
      base_opts(store, request)
      |> Keyword.merge(model: "deepseek-flash", messages: messages)

    assert {:ok, _result} = DeepSeek.generate(nil, opts)

    assert_receive {:body, %{"messages" => [_assistant, tool]}}
    assert tool["role"] == "tool"

    assert tool["content"] ==
             "Read image shot.png (image/png).\n" <>
               "[image content omitted: this model accepts text-only tool results]"
  end

  test "replays reasoning content for flash and V4 without weakening model affinity", %{
    store: store
  } do
    test_pid = self()

    request = fn options ->
      {:ok, body} = JSON.decode(options[:body])
      send(test_pid, {:body, body})

      streaming_response(options, [
        sse(%{
          "model" => "deepseek-flash",
          "choices" => [%{"delta" => %{"content" => "done"}, "finish_reason" => "stop"}]
        }),
        "data: [DONE]\n\n"
      ])
    end

    provider_state = %{
      "provider" => "deepseek",
      "model" => "deepseek-flash",
      "reasoning_content" => "previous reasoning"
    }

    messages = [
      %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "call-1", function: %{name: "search", arguments: "{}"}}],
        provider_state: provider_state
      },
      %{role: :tool, tool_call_id: "call-1", content: "result"}
    ]

    tools = [
      %{name: "search", description: "Search", input_schema: [query: [type: :string]]}
    ]

    opts =
      base_opts(store, request)
      |> Keyword.merge(model: "deepseek-flash", messages: messages, tools: tools)

    assert {:ok, _result} = DeepSeek.generate(nil, opts)
    assert_receive {:body, %{"messages" => [assistant, _tool]}}
    assert assistant["reasoning_content"] == "previous reasoning"

    opts =
      base_opts(store, request)
      |> Keyword.merge(model: "deepseek-flash", messages: messages)

    assert {:ok, _result} = DeepSeek.generate(nil, opts)
    assert_receive {:body, %{"messages" => [assistant, _tool]}}
    assert assistant["reasoning_content"] == "previous reasoning"

    v4_messages = [
      put_in(hd(messages), [:provider_state, "model"], "deepseek-v4-flash"),
      List.last(messages)
    ]

    opts =
      base_opts(store, request)
      |> Keyword.merge(model: "deepseek-v4-flash", messages: v4_messages)

    assert {:ok, _result} = DeepSeek.generate(nil, opts)
    assert_receive {:body, %{"messages" => [assistant, _tool]}}
    assert assistant["reasoning_content"] == "previous reasoning"

    opts =
      base_opts(store, request)
      |> Keyword.merge(model: "deepseek-v4-pro", messages: messages)

    assert {:ok, _result} = DeepSeek.generate(nil, opts)
    assert_receive {:body, %{"messages" => [assistant, _tool]}}
    assert assistant["reasoning_content"] == ""
  end

  test "keeps repeated cache-prefix projections byte-identical", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:request_body, options[:body]})

      streaming_response(options, [
        sse(%{
          "model" => "deepseek-v4-flash",
          "choices" => [%{"delta" => %{"content" => "done"}, "finish_reason" => "stop"}]
        }),
        "data: [DONE]\n\n"
      ])
    end

    raw_arguments = "{ \"query\" : \"cats\" }"

    messages = [
      %{role: :user, content: "search"},
      %{
        role: :assistant,
        content: nil,
        tool_calls: [
          %{id: "call-1", function: %{name: "search", arguments: raw_arguments}}
        ],
        provider_state: %{
          "provider" => "deepseek",
          "model" => "deepseek-v4-flash",
          "reasoning_content" => "cached reasoning"
        }
      },
      %{role: :tool, tool_call_id: "call-1", content: "result"}
    ]

    opts =
      base_opts(store, request)
      |> Keyword.merge(model: "deepseek-v4-flash", system: "Stable", messages: messages)

    assert {:ok, _result} = DeepSeek.generate(nil, opts)
    assert_receive {:request_body, first}
    assert {:ok, _result} = DeepSeek.generate(nil, opts)
    assert_receive {:request_body, second}
    assert first == second

    assert {:ok, body} = JSON.decode(first)
    assert Enum.at(body["messages"], 2)["content"] == ""
    assert Enum.at(body["messages"], 2)["reasoning_content"] == "cached reasoning"

    assert get_in(body, [
             "messages",
             Access.at(2),
             "tool_calls",
             Access.at(0),
             "function",
             "arguments"
           ]) ==
             raw_arguments
  end

  test "rejects malformed or unpaired historical tool calls before requesting", %{store: store} do
    request = fn _options -> flunk("unexpected request") end

    malformed = [
      %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "call-1", function: %{name: "search", arguments: "{"}}]
      },
      %{role: :tool, tool_call_id: "call-1", content: "result"}
    ]

    assert {:error, :invalid_tool_call} =
             DeepSeek.generate(nil, Keyword.put(base_opts(store, request), :messages, malformed))

    unpaired = [%{role: :tool, tool_call_id: "call-1", content: "result"}]

    assert {:error, {:invalid_tool_history, {:unexpected_tool_result, "call-1"}}} =
             DeepSeek.generate(nil, Keyword.put(base_opts(store, request), :messages, unpaired))
  end

  test "requests JSON output and parses a structured response", %{store: store} do
    request = fn options ->
      {:ok, body} = JSON.decode(options[:body])
      assert body["response_format"] == %{"type" => "json_object"}
      assert [%{"role" => "system", "content" => instruction}, _user] = body["messages"]
      assert instruction =~ "Return only a JSON object matching this JSON Schema"
      assert instruction =~ "\"answer\""

      streaming_response(options, [
        sse(%{
          "model" => "deepseek-flash",
          "choices" => [
            %{"delta" => %{"content" => "{\"answer\":\"yes\"}"}, "finish_reason" => "stop"}
          ]
        }),
        "data: [DONE]\n\n"
      ])
    end

    assert {:ok, %{data: %{"answer" => "yes"}}} =
             DeepSeek.generate(
               [answer: [type: :string, required: true]],
               base_opts(store, request)
             )
  end

  test "maps reasoning effort to DeepSeek thinking controls", %{store: store} do
    test_pid = self()

    request = fn options ->
      {:ok, body} = JSON.decode(options[:body])
      send(test_pid, {:body, body})

      streaming_response(options, [
        sse(%{
          "choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => "stop"}]
        }),
        "data: [DONE]\n\n"
      ])
    end

    assert {:ok, _result} =
             DeepSeek.generate(
               nil,
               Keyword.put(base_opts(store, request), :reasoning_effort, :high)
             )

    assert_receive {:body,
                    %{
                      "thinking" => %{"type" => "enabled"},
                      "reasoning_effort" => "high"
                    }}

    assert {:ok, _result} =
             DeepSeek.generate(
               nil,
               Keyword.put(base_opts(store, request), :reasoning_effort, :off)
             )

    assert_receive {:body, off_body}
    assert off_body["thinking"] == %{"type" => "disabled"}
    refute Map.has_key?(off_body, "reasoning_effort")

    assert {:error, {:invalid_reasoning_effort, :extreme}} =
             DeepSeek.generate(
               nil,
               Keyword.put(base_opts(store, request), :reasoning_effort, :extreme)
             )
  end

  test "halts an active response stream after cancellation", %{store: store} do
    signal = Cancellation.new_signal()
    on_exit(fn -> Cancellation.delete(signal) end)

    request = fn options ->
      streaming_response(options, [
        sse(%{"choices" => [%{"delta" => %{"content" => "one"}, "finish_reason" => nil}]}),
        sse(%{"choices" => [%{"delta" => %{"content" => "two"}, "finish_reason" => "stop"}]})
      ])
    end

    opts =
      base_opts(store, request)
      |> Keyword.put(:cancellation_signal, signal)

    assert {:error, :cancelled} =
             DeepSeek.stream(nil, opts, fn
               %{type: :text_delta, delta: "one"} -> Cancellation.cancel(signal)
               _event -> :ok
             end)
  end

  test "validates model and credentials before requesting", %{store: store} do
    request = fn _options -> flunk("unexpected request") end

    assert {:error, {:unsupported_model, "unknown"}} =
             DeepSeek.generate(nil, Keyword.put(base_opts(store, request), :model, "unknown"))

    empty_store_agent = start_supervised!({Agent, fn -> %{} end}, id: {Agent, make_ref()})
    empty_store = {CredentialStore, empty_store_agent}

    previous = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")

    on_exit(fn ->
      if previous, do: System.put_env("DEEPSEEK_API_KEY", previous)
    end)

    assert {:error, :missing_deepseek_api_key} =
             DeepSeek.generate(nil, base_opts(empty_store, request))
  end

  test "classifies a wire context overflow as a provider-neutral error", %{store: store} do
    body =
      JSON.encode!(%{
        "error" => %{
          "message" =>
            "This model's maximum context length is 65536 tokens. However, you requested too many tokens.",
          "type" => "invalid_request_error",
          "code" => "context_length_exceeded"
        }
      })

    request = fn _options -> {:ok, %Req.Response{status: 400, body: body}} end

    assert {:error, :context_window_exceeded} = DeepSeek.generate(nil, base_opts(store, request))
  end

  test "does not classify generic 4xx errors as overflow", %{store: store} do
    request = fn _options -> {:ok, %Req.Response{status: 400, body: "bad request"}} end

    assert {:error, {:http_error, 400, "bad request"}} =
             DeepSeek.generate(nil, base_opts(store, request))
  end

  test "login prompts for an API key through the interaction handle" do
    test_pid = self()

    assert {:ok, %{"api_key" => "prompted-key"}} =
             DeepSeek.login(interaction: {Interaction, test_pid})

    assert_receive {:interaction_prompt, opts}
    assert opts[:label] =~ "API key"
    assert opts[:secret] == true
  end

  test "login rejects an empty API key" do
    Process.put(:prompt_result, {:ok, "   "})
    test_pid = self()

    assert {:error, :empty_api_key} = DeepSeek.login(interaction: {Interaction, test_pid})
  after
    Process.delete(:prompt_result)
  end

  test "login requires an interaction handle" do
    assert {:error, :interaction_required} = DeepSeek.login([])
  end

  test "usage returns the account balance for the stored key", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:balance_request, options})

      {:ok,
       %Req.Response{
         status: 200,
         body: JSON.encode!(%{"is_available" => true, "balance_infos" => []})
       }}
    end

    assert {:ok, %{"is_available" => true, "balance_infos" => []}} =
             DeepSeek.usage(credential_store: store, request: request)

    assert_receive {:balance_request, options}
    assert options[:method] == :get
    assert options[:url] == "https://api.deepseek.com/user/balance"
    assert header(options, "authorization") == "Bearer stored-key"
  end

  test "usage surfaces provider errors", %{store: store} do
    request = fn _options -> {:ok, %Req.Response{status: 401, body: "unauthorized"}} end

    assert {:error, {:http_error, 401, "unauthorized"}} =
             DeepSeek.usage(credential_store: store, request: request)
  end

  defp base_opts(store, request) do
    [
      model: "deepseek-flash",
      messages: [%{role: :user, content: "hello"}],
      tools: [],
      credential_store: store,
      request: request
    ]
  end

  defp streaming_response(options, chunks) do
    into = Keyword.fetch!(options, :into)
    initial = {%Req.Request{}, %Req.Response{status: 200, headers: %{}, body: ""}}

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
