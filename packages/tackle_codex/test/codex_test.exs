defmodule Tackle.Plugins.CodexTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib
  alias Tackle.Lib.{Cancellation, Event, LLM, Loop, Message, ModelInfo, State, Thinking, Usage}
  alias Tackle.Lib.Compaction.Config, as: CompactionConfig
  alias Tackle.Lib.Compaction.Summary
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.Retry
  alias Tackle.Plugins.Codex
  alias Tackle.Plugins.Codex.SSE

  @search_schema %{
    "type" => "object",
    "properties" => %{"query" => %{"type" => "string", "description" => "Query"}},
    "required" => ["query"]
  }

  defmodule OverflowSummarizer do
    @behaviour Tackle.Lib.Compaction.Summarizer

    @impl true
    def summarize(_request, _opts),
      do: {:ok, %Summary{content: "checkpoint summary", usage: nil, model: "test/m"}}
  end

  defmodule OverflowCommitter do
    @behaviour Tackle.Lib.Compaction.Committer

    @impl true
    def commit(_record, _context), do: :ok
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
      {:error, :unexpected_prompt}
    end

    @impl true
    def confirm(_reference, _message), do: false

    @impl true
    def progress(reference, opts, fun) do
      send(reference, {:interaction_progress, Keyword.get(opts, :label)})
      fun.()
    end
  end

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

  defmodule SearchTool do
    use Tackle.Lib.Tool

    tool_name("search")
    description("Search documents")

    input do
      field(:query, :string, required: true)
    end

    def run(%{"query" => query}, _context), do: {:ok, %{"result" => query}}
  end

  setup do
    credentials = oauth_credentials("access-token", "refresh-token", 4_000_000_000_000)

    start_supervised!({Agent, fn -> %{Codex.adapter_id() => credentials} end},
      id: {Agent, make_ref()}
    )
    |> then(&{:ok, store: {CredentialStore, &1}})
  end

  test "exposes limits and price cards for every selectable model" do
    Enum.each(Codex.models(), fn model ->
      assert {:ok, %ModelInfo{} = info} = LLM.model_info(Codex, model)
      assert info.context_window in [128_000, 272_000]
      assert info.max_output_tokens == 128_000
      assert info.pricing.currency == "USD"
      assert info.pricing.unit_tokens == 1_000_000
    end)

    assert {:ok, %ModelInfo{} = sol} = LLM.model_info(Codex, "gpt-6-sol")
    assert sol.context_window == 272_000

    assert sol.pricing == %{
             input: 2,
             output: 10,
             cache_read: 0.2,
             cache_write: 2.5,
             currency: "USD",
             unit_tokens: 1_000_000
           }

    assert {:ok, %ModelInfo{} = luna} = LLM.model_info(Codex, "gpt-6-luna")
    assert luna.context_window == 272_000

    assert luna.pricing == %{
             input: 0.1,
             output: 0.5,
             cache_read: 0.01,
             cache_write: 0.125,
             currency: "USD",
             unit_tokens: 1_000_000
           }

    assert {:ok, nil} = LLM.model_info(Codex, "unknown")
  end

  test "translates messages and tools and returns normalized content and usage", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:request, options})

      streaming_response(options, [
        sse(%{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{"type" => "message", "content" => []}
        }),
        sse(%{"type" => "response.output_text.delta", "output_index" => 0, "delta" => "hel"}),
        "data: " <>
          JSON.encode!(%{
            "type" => "response.output_text.delta",
            "output_index" => 0,
            "delta" => "lo"
          }) <>
          "\n",
        "\n" <>
          sse(%{
            "type" => "response.completed",
            "response" => %{
              "status" => "completed",
              "model" => "gpt-5.5",
              "output" => [
                %{
                  "type" => "message",
                  "content" => [%{"type" => "output_text", "text" => "hello"}]
                }
              ],
              "usage" => %{
                "input_tokens" => 12,
                "output_tokens" => 4,
                "total_tokens" => 16,
                "input_tokens_details" => %{
                  "cached_tokens" => 2,
                  "cache_write_tokens" => 3
                },
                "output_tokens_details" => %{"reasoning_tokens" => 1}
              }
            }
          })
      ])
    end

    opts =
      Keyword.merge(base_opts(store, request),
        session_id: "session-123",
        system: "Be useful",
        reasoning_effort: "max",
        temperature: 0.3,
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

    assert {:ok, selection} = LLM.select([Codex], "openai-codex/gpt-5.5")
    assert {:ok, result} = LLM.generate_with(selection, nil, opts)
    assert result.data == %{"content" => "hello", "tool_calls" => []}
    assert result.model == "gpt-5.5"
    assert result.provider == "openai-codex"

    assert %Usage{
             input_tokens: 7,
             output_tokens: 4,
             cache_read_tokens: 2,
             cache_write_tokens: 3,
             reasoning_tokens: 1,
             cost_estimated: true,
             currency: "USD"
           } = result.usage

    assert result.usage.total_tokens == 16

    assert result.usage.raw["input_tokens_details"] == %{
             "cached_tokens" => 2,
             "cache_write_tokens" => 3
           }

    assert_in_delta result.usage.cost_breakdown.input, 0.000035, 0.0000001
    assert_in_delta result.usage.cost_breakdown.output, 0.00012, 0.0000001
    assert_in_delta result.usage.cost_breakdown.cache_read, 0.000001, 0.0000001
    assert result.usage.cost_breakdown.cache_write == 0.0
    assert_in_delta result.usage.cost, 0.000156, 0.0000001

    assert_receive {:request, request_options}
    assert request_options[:url] == "https://chatgpt.com/backend-api/codex/responses"
    assert header(request_options, "authorization") == "Bearer access-token"
    assert header(request_options, "chatgpt-account-id") == "account-123"
    assert header(request_options, "originator") == "tackle"
    assert header(request_options, "session-id") == "session-123"
    assert header(request_options, "x-client-request-id") == "session-123"

    assert {:ok, body} = JSON.decode(request_options[:body])
    assert body["model"] == "gpt-5.5"
    assert body["prompt_cache_key"] == "session-123"
    assert body["instructions"] == "Be useful"
    # gpt-5.5 has no max effort; it gets the nearest one.
    assert body["reasoning"] == %{"effort" => "xhigh", "summary" => "auto"}
    refute Map.has_key?(body, "temperature")

    assert Enum.any?(
             body["input"],
             &(&1["type"] == "function_call" and &1["call_id"] == "call-old")
           )

    assert Enum.any?(
             body["input"],
             &(&1["type"] == "function_call_output" and &1["call_id"] == "call-old")
           )

    # The definition's JSON Schema goes on the wire as it is.
    assert [%{"name" => "search", "parameters" => @search_schema, "strict" => nil}] =
             body["tools"]
  end

  test "sends every thinking level as an effort the model supports", %{store: store} do
    test_pid = self()

    request = fn options ->
      {:ok, body} = JSON.decode(options[:body])
      send(test_pid, {:reasoning, body["model"], body["reasoning"]})
      completed_response(options, "ok")
    end

    expected = %{
      "gpt-5.5" => %{"minimal" => "low", "max" => "xhigh"},
      "gpt-6-sol" => %{"minimal" => "low", "max" => "max"}
    }

    for {model, mapped} <- expected, level <- Thinking.levels() do
      opts =
        base_opts(store, request)
        |> Keyword.merge(model: model, reasoning_effort: level)

      assert {:ok, _result} = generate(nil, opts)
      assert_receive {:reasoning, ^model, reasoning}

      if level == "off" do
        assert reasoning == nil
      else
        effort = Map.get(mapped, level, level)
        assert reasoning == %{"effort" => effort, "summary" => "auto"}, "#{model} #{level}"
        assert effort in Codex.reasoning_levels(model)
      end
    end

    opts = Keyword.put(base_opts(store, request), :reasoning_effort, :none)
    assert {:ok, _result} = generate(nil, opts)
    assert_receive {:reasoning, "gpt-5.5", nil}

    opts = Keyword.put(base_opts(store, request), :reasoning_effort, "ultra")
    assert {:error, {:invalid_reasoning_effort, "ultra"}} = generate(nil, opts)
    refute_received {:reasoning, _model, _reasoning}
  end

  test "closes dangling tool calls left by a cancelled turn", %{store: store} do
    test_pid = self()

    request = fn options ->
      {:ok, body} = JSON.decode(options[:body])
      send(test_pid, {:request_input, body["input"]})

      streaming_response(options, [
        sse(%{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "continued"}]
              }
            ]
          }
        })
      ])
    end

    messages = [
      %{role: :user, content: "run both"},
      %{
        role: :assistant,
        content: nil,
        tool_calls: [
          %{id: "call-finished", name: "search", arguments: %{"query" => "one"}},
          %{id: "call-cancelled", name: "search", arguments: %{"query" => "two"}}
        ]
      },
      %{
        role: :tool,
        tool_call_id: "call-finished",
        name: "search",
        content: "finished"
      },
      %{role: :user, content: "continue"}
    ]

    opts = base_opts(store, request) |> Keyword.put(:messages, messages)

    assert {:ok, %{data: %{"content" => "continued"}}} = generate(nil, opts)
    assert_receive {:request_input, input}

    assert Enum.count(input, &(&1["type"] == "function_call_output")) == 2

    assert Enum.any?(
             input,
             &(&1 == %{
                 "type" => "function_call_output",
                 "call_id" => "call-cancelled",
                 "output" => "aborted"
               })
           )
  end

  test "sends content-part tool results as function call output items", %{store: store} do
    request = fn options ->
      {:ok, body} = JSON.decode(options[:body])
      send(self(), {:request_input, body["input"]})

      streaming_response(options, [
        sse(%{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "I can see it"}]
              }
            ]
          }
        })
      ])
    end

    messages = [
      %{role: :user, content: "what does this screenshot show?"},
      %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "call-1", name: "read", arguments: %{"path" => "shot.png"}}]
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

    opts = base_opts(store, request) |> Keyword.put(:messages, messages)

    assert {:ok, %{data: %{"content" => "I can see it"}}} = generate(nil, opts)
    assert_receive {:request_input, input}

    assert Enum.any?(
             input,
             &(&1 == %{
                 "type" => "function_call_output",
                 "call_id" => "call-1",
                 "output" => [
                   %{"type" => "input_text", "text" => "Read image shot.png (image/png)."},
                   %{
                     "type" => "input_image",
                     "image_url" => "data:image/png;base64,aGVsbG8="
                   }
                 ]
               })
           )
  end

  test "rejects a tool result with an unsupported content part", %{store: store} do
    request = fn options ->
      {:ok, body} = JSON.decode(options[:body])
      send(self(), {:request_input, body["input"]})
      streaming_response(options, [sse(%{"type" => "response.completed", "response" => %{}})])
    end

    messages = [
      %{role: :user, content: "look"},
      %{
        role: :tool,
        tool_call_id: "call-1",
        name: "read",
        content: [%{"type" => "video", "data" => "x"}]
      }
    ]

    opts = base_opts(store, request) |> Keyword.put(:messages, messages)

    assert {:error, {:unsupported_tool_content, "video"}} = generate(nil, opts)
  end

  test "streams text, reasoning, and tool argument deltas across chunk boundaries", %{
    store: store
  } do
    events = [
      sse(%{
        "type" => "response.reasoning_summary_text.delta",
        "output_index" => 1,
        "delta" => "considering tools"
      }),
      sse(%{
        "type" => "response.reasoning_text.delta",
        "output_index" => 1,
        "delta" => "private chain of thought"
      }),
      sse(%{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "search",
          "arguments" => ""
        }
      }),
      sse(%{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 0,
        "delta" => "{\"query\":"
      }),
      sse(%{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 0,
        "delta" => "\"cats\"}"
      }),
      sse(%{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "search",
          "arguments" => "{\"query\":\"cats\"}"
        }
      }),
      sse(%{
        "type" => "response.completed",
        "response" => %{
          "status" => "completed",
          "output" => [
            %{
              "type" => "function_call",
              "call_id" => "call-1",
              "name" => "search",
              "arguments" => "{\"query\":\"cats\"}"
            }
          ]
        }
      })
    ]

    wire = Enum.join(events)
    chunks = split_binary(wire, [7, 31, 3, 89])
    request = fn options -> streaming_response(options, chunks) end

    assert {:ok, result} =
             Codex.stream(nil, base_opts(store, request), fn event ->
               send(self(), {:event, event})
             end)

    assert result.data == %{
             "thinking" => "considering tools",
             "tool_calls" => [
               %{"id" => "call-1", "name" => "search", "arguments" => "{\"query\":\"cats\"}"}
             ]
           }

    assert_receive {:event, %{type: :reasoning_delta, delta: "considering tools"}}
    refute_receive {:event, %{delta: "private chain of thought"}}
    assert_receive {:event, %{type: :tool_input_delta, delta: "{\"query\":"}}
    assert_receive {:event, %{type: :tool_input_delta, delta: "\"cats\"}"}}
  end

  test "uses cached WebSocket transport by default", %{store: store} do
    test_pid = self()

    websocket_request = fn body, options, headers, event_callback ->
      send(test_pid, {:websocket_request, body, options, headers})

      parser =
        SSE.new()
        |> SSE.push_event(
          %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp-1",
              "status" => "completed",
              "model" => "gpt-5.5",
              "output" => [
                %{
                  "type" => "message",
                  "content" => [%{"type" => "output_text", "text" => "websocket"}]
                }
              ]
            }
          },
          event_callback
        )

      {:ok, %{status: 200, body: parser}}
    end

    opts =
      base_opts(store, fn _options -> flunk("unexpected SSE request") end)
      |> Keyword.delete(:transport)
      |> Keyword.put(:session_id, "ws-session")
      |> Keyword.put(:websocket_request, websocket_request)

    assert {:ok, %{data: %{"content" => "websocket"}}} = generate(nil, opts)

    assert_receive {:websocket_request, body, request_options, headers}
    assert request_options[:transport] == :auto
    assert request_options[:responses_url] == "https://chatgpt.com/backend-api/codex/responses"

    assert body["input"] == [
             %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hello"}]}
           ]

    assert header_value(headers, "openai-beta") == "responses_websockets=2026-02-06"
    assert header_value(headers, "session-id") == "ws-session"
  end

  test "auto transport falls back to SSE before WebSocket streaming starts", %{store: store} do
    request = fn options ->
      streaming_response(options, [
        sse(%{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "fallback"}]
              }
            ]
          }
        })
      ])
    end

    websocket_request = fn _body, _options, _headers, _callback ->
      {:error, {:websocket_transport_failed, :before_stream, :connection_refused}}
    end

    opts =
      base_opts(store, request)
      |> Keyword.put(:transport, :auto)
      |> Keyword.put(:websocket_request, websocket_request)

    assert {:ok, %{data: %{"content" => "fallback"}}} = generate(nil, opts)
  end

  test "auto transport does not replay over SSE when an injected WebSocket raises after streaming starts",
       %{
         store: store
       } do
    test_pid = self()

    websocket_request = fn _body, _options, _headers, callback ->
      callback.(%{type: :text_delta, delta: "partial"})
      raise "closed"
    end

    opts =
      base_opts(store, fn _options -> flunk("unexpected SSE replay") end)
      |> Keyword.put(:transport, :auto)
      |> Keyword.put(:websocket_request, websocket_request)

    assert {:error, %Error{kind: :unknown, message: "The provider request failed: closed"}} =
             Codex.stream(nil, opts, fn event -> send(test_pid, {:event, event}) end)

    assert_receive {:event, %{type: :text_delta, delta: "partial"}}
  end

  test "refreshes and retries an explicit WebSocket after a 401 upgrade", %{store: store} do
    calls = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})
    refreshed_access = jwt("websocket-account")

    request = fn options ->
      assert String.ends_with?(options[:url], "/oauth/token")

      {:ok,
       %Req.Response{
         status: 200,
         body:
           JSON.encode!(%{
             "access_token" => refreshed_access,
             "refresh_token" => "websocket-refresh",
             "expires_in" => 3_600
           })
       }}
    end

    websocket_request = fn _body, _options, headers, event_callback ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          assert header_value(headers, "authorization") == "Bearer access-token"

          {:error,
           {:websocket_transport_failed, :before_stream,
            Error.from_response(401, "unauthorized", [])}}

        1 ->
          assert header_value(headers, "authorization") == "Bearer #{refreshed_access}"

          parser =
            SSE.push_event(
              SSE.new(),
              %{
                "type" => "response.completed",
                "response" => %{
                  "status" => "completed",
                  "output" => [
                    %{
                      "type" => "message",
                      "content" => [%{"type" => "output_text", "text" => "retried"}]
                    }
                  ]
                }
              },
              event_callback
            )

          {:ok, %{status: 200, body: parser}}
      end
    end

    opts =
      base_opts(store, request)
      |> Keyword.put(:transport, :websocket_cached)
      |> Keyword.put(:websocket_request, websocket_request)

    assert {:ok, %{data: %{"content" => "retried"}}} = generate(nil, opts)
    assert Agent.get(calls, & &1) == 2
  end

  test "refreshes an expired credential and persists the rotated refresh token", %{store: store} do
    {store_module, store_agent} = store

    :ok =
      store_module.put(
        store_agent,
        Codex.adapter_id(),
        oauth_credentials("expired-access", "old-refresh", 1)
      )

    test_pid = self()
    refreshed_access = jwt("new-account")

    request = fn options ->
      send(test_pid, {:request_url, options[:url], options})

      if String.ends_with?(options[:url], "/oauth/token") do
        {:ok,
         %Req.Response{
           status: 200,
           body:
             JSON.encode!(%{
               "access_token" => refreshed_access,
               "refresh_token" => "new-refresh",
               "expires_in" => 3_600
             })
         }}
      else
        streaming_response(options, [
          sse(%{
            "type" => "response.completed",
            "response" => %{
              "status" => "completed",
              "output" => [
                %{
                  "type" => "message",
                  "content" => [%{"type" => "output_text", "text" => "refreshed"}]
                }
              ]
            }
          })
        ])
      end
    end

    assert {:ok, %{data: %{"content" => "refreshed"}}} =
             generate(nil, base_opts(store, request))

    assert_receive {:request_url, "https://auth.openai.com/oauth/token", token_options}
    assert token_options[:form][:refresh_token] == "old-refresh"

    assert_receive {:request_url, "https://chatgpt.com/backend-api/codex/responses", api_options}
    assert header(api_options, "authorization") == "Bearer #{refreshed_access}"

    assert {:ok, stored} = store_module.fetch(store_agent, Codex.adapter_id())
    assert stored["refresh_token"] == "new-refresh"
    assert stored["account_id"] == "new-account"
  end

  test "replays encrypted reasoning and Responses item ids through a tool round trip", %{
    store: store
  } do
    test_pid = self()
    call_count = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})

    request = fn options ->
      call = Agent.get_and_update(call_count, &{&1, &1 + 1})
      {:ok, body} = JSON.decode(options[:body])

      case call do
        0 ->
          streaming_response(options, [
            sse(%{
              "type" => "response.completed",
              "response" => %{
                "status" => "completed",
                "model" => "gpt-5.5-2026-09-01",
                "output" => [
                  %{
                    "type" => "reasoning",
                    "id" => "rs_1",
                    "summary" => [],
                    "content" => [%{"type" => "reasoning_text", "text" => "private reasoning"}],
                    "encrypted_content" => "opaque-reasoning"
                  },
                  %{
                    "type" => "function_call",
                    "id" => "fc_1",
                    "call_id" => "call-1",
                    "name" => "search",
                    "arguments" => "{\"query\":\"cats\"}"
                  }
                ]
              }
            })
          ])

        1 ->
          send(test_pid, {:continuation_input, body["input"]})

          streaming_response(options, [
            sse(%{
              "type" => "response.completed",
              "response" => %{
                "status" => "completed",
                "model" => "gpt-5.5",
                "output" => [
                  %{
                    "type" => "message",
                    "id" => "msg_final",
                    "role" => "assistant",
                    "status" => "completed",
                    "content" => [%{"type" => "output_text", "text" => "found cats"}]
                  }
                ]
              }
            })
          ])
      end
    end

    {:ok, selection} = LLM.select([Codex], "openai-codex/gpt-5.5")

    state =
      Lib.new(
        llm: selection,
        tools: [SearchTool],
        max_iterations: 3,
        llm_opts: [credential_store: store, request: request]
      )

    assert {:ok, final_state} = Loop.run(state, "find cats")
    assert Lib.last_answer(final_state) == "found cats"

    assert_receive {:continuation_input, input}

    assert Enum.any?(
             input,
             &(&1["type"] == "reasoning" and &1["id"] == "rs_1" and
                 &1["encrypted_content"] == "opaque-reasoning" and
                 not Map.has_key?(&1, "content"))
           )

    assert Enum.any?(
             input,
             &(&1["type"] == "function_call" and &1["id"] == "fc_1" and
                 &1["call_id"] == "call-1")
           )

    assert Enum.any?(
             input,
             &(&1["type"] == "function_call_output" and &1["call_id"] == "call-1")
           )
  end

  test "refreshes once and retries after an unauthorized response", %{store: store} do
    api_calls = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})
    refreshed_access = jwt("retry-account")

    request = fn options ->
      if String.ends_with?(options[:url], "/oauth/token") do
        {:ok,
         %Req.Response{
           status: 200,
           body:
             JSON.encode!(%{
               "access_token" => refreshed_access,
               "refresh_token" => "retry-refresh",
               "expires_in" => 3_600
             })
         }}
      else
        call = Agent.get_and_update(api_calls, &{&1, &1 + 1})

        if call == 0 do
          {:ok, %Req.Response{status: 401, body: "unauthorized"}}
        else
          assert header(options, "authorization") == "Bearer #{refreshed_access}"

          streaming_response(options, [
            sse(%{
              "type" => "response.completed",
              "response" => %{
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "message",
                    "content" => [%{"type" => "output_text", "text" => "retried"}]
                  }
                ]
              }
            })
          ])
        end
      end
    end

    assert {:ok, %{data: %{"content" => "retried"}}} =
             generate(nil, base_opts(store, request))

    assert Agent.get(api_calls, & &1) == 2
  end

  test "halts an active response stream after cancellation", %{store: store} do
    signal = Cancellation.new_signal()
    on_exit(fn -> Cancellation.delete(signal) end)

    request = fn options ->
      streaming_response(options, [
        sse(%{"type" => "response.output_text.delta", "output_index" => 0, "delta" => "one"}),
        sse(%{"type" => "response.output_text.delta", "output_index" => 0, "delta" => "two"}),
        sse(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "output" => []}
        })
      ])
    end

    opts = base_opts(store, request) |> Keyword.put(:cancellation_signal, signal)

    assert {:error, :cancelled} =
             Codex.stream(nil, opts, fn
               %{type: :text_delta, delta: "one"} -> Cancellation.cancel(signal)
               _event -> :ok
             end)
  end

  test "does not start a request after cancellation", %{store: store} do
    signal = Cancellation.new_signal()
    :ok = Cancellation.cancel(signal)
    on_exit(fn -> Cancellation.delete(signal) end)

    opts =
      base_opts(store, fn _options -> flunk("unexpected request") end)
      |> Keyword.put(:cancellation_signal, signal)

    assert {:error, :cancelled} = generate(nil, opts)
  end

  test "reports missing credentials without making a request" do
    store_agent = start_supervised!({Agent, fn -> %{} end}, id: {Agent, make_ref()})
    store = {CredentialStore, store_agent}

    assert {:error, :missing_codex_credentials} =
             generate(nil, base_opts(store, fn _options -> flunk("unexpected request") end))
  end

  test "preserves a streamed HTTP error body", %{store: store} do
    body = JSON.encode!(%{"detail" => "No tool output found for function call call-1."})

    request = fn options ->
      streaming_response(options, split_binary(body, [5, 17]), 400)
    end

    assert {:error,
            %Error{kind: :invalid_request, status: 400, details: details, message: message}} =
             generate(nil, base_opts(store, request))

    assert details == JSON.decode!(body)
    assert message =~ "No tool output found for function call call-1."
  end

  test "does not expose the stream accumulator for a bodyless HTTP error", %{store: store} do
    stream = fn _options, initial_acc, _callback ->
      {:ok, %Req.Response{status: 400, body: nil}, initial_acc}
    end

    opts = base_opts(store, fn _options -> flunk("unexpected legacy request") end)
    opts = Keyword.put(opts, :stream, stream)

    assert {:error, %Error{kind: :invalid_request, status: 400, details: ""}} =
             generate(nil, opts)
  end

  test "classifies a wire context overflow as a provider-neutral error", %{store: store} do
    body =
      JSON.encode!(%{
        "error" => %{
          "type" => "invalid_request_error",
          "code" => "context_length_exceeded",
          "message" => "Your input exceeds the context window of this model."
        }
      })

    request = fn _options -> {:ok, %Req.Response{status: 400, body: body}} end

    assert {:error, %Error{kind: :context_window_exceeded, status: 400}} =
             generate(nil, base_opts(store, request))
  end

  test "does not classify generic 4xx errors as overflow", %{store: store} do
    request = fn _options -> {:ok, %Req.Response{status: 400, body: "bad request"}} end

    assert {:error, %Error{kind: :invalid_request, status: 400, details: "bad request"}} =
             generate(nil, base_opts(store, request))
  end

  test "passes Retry-After through on a rate limit", %{store: store} do
    request = fn _options ->
      {:ok, %Req.Response{status: 429, headers: %{"retry-after" => ["17"]}, body: ""}}
    end

    assert {:error, %Error{kind: :rate_limited, status: 429, retry_after_ms: 17_000} = error} =
             generate(nil, base_opts(store, request))

    assert Retry.retryable?(error)
  end

  test "reports Req transport failures as retryable transport errors", %{store: store} do
    for reason <- [:closed, :econnrefused, :econnreset, :nxdomain] do
      request = fn _options -> {:error, %Req.TransportError{reason: reason}} end

      assert {:error, %Error{kind: :transport, details: %Req.TransportError{}} = error} =
               generate(nil, base_opts(store, request))

      assert Retry.retryable?(error)
    end

    request = fn _options -> {:error, %Req.TransportError{reason: :timeout}} end
    assert {:error, %Error{kind: :timeout}} = generate(nil, base_opts(store, request))
  end

  test "reports Mint transport failures of a WebSocket as retryable", %{store: store} do
    websocket_request = fn _body, _options, _headers, _callback ->
      {:error,
       {:websocket_transport_failed, :after_stream, %Mint.TransportError{reason: :closed}}}
    end

    opts =
      base_opts(store, fn _options -> flunk("unexpected SSE request") end)
      |> Keyword.put(:transport, :websocket)
      |> Keyword.put(:websocket_request, websocket_request)

    assert {:error, %Error{kind: :transport} = error} = generate(nil, opts)
    assert Retry.retryable?(error)
  end

  test "classifies a context overflow reported inside the stream", %{store: store} do
    request = fn options -> streaming_response(options, [overflow_event()]) end

    assert {:error, %Error{kind: :context_window_exceeded, status: nil}} =
             generate(nil, base_opts(store, request))
  end

  test "an in-stream overflow compacts and retries through the loop", %{store: store} do
    calls = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})

    request = fn options ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          streaming_response(options, [overflow_event()])

        _retry ->
          streaming_response(options, [
            sse(%{
              "type" => "response.completed",
              "response" => %{
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "message",
                    "content" => [%{"type" => "output_text", "text" => "compacted answer"}]
                  }
                ]
              }
            })
          ])
      end
    end

    {:ok, selection} = LLM.select([Codex], "openai-codex/gpt-5.5")

    compaction =
      CompactionConfig.new!(
        policy: [retain_tokens: 10],
        summarizer: OverflowSummarizer,
        committer: OverflowCommitter
      )

    state =
      Lib.new(
        llm: selection,
        retry: false,
        compaction: compaction,
        llm_opts: [credential_store: store, request: request, transport: :sse]
      )
      |> State.add_message(Message.user(String.duplicate("earlier ", 200)))
      |> State.add_message(Message.assistant(content: String.duplicate("answer ", 200)))

    test_pid = self()

    assert {:ok, final_state} =
             Loop.run(state, "hello", event_callback: &send(test_pid, {:event, &1}))

    assert Lib.last_answer(final_state) == "compacted answer"
    assert Agent.get(calls, & &1) == 2

    assert_received {:event,
                     %Event{
                       type: :compaction_retry,
                       data: %{trigger: :overflow, reason: %Error{kind: :context_window_exceeded}}
                     }}
  end

  test "login runs the device-code flow through the interaction handle" do
    access_token = jwt("device-account")
    counter = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})
    test_pid = self()

    request = fn options ->
      cond do
        String.ends_with?(options[:url], "/deviceauth/usercode") ->
          {:ok,
           %Req.Response{
             status: 200,
             body:
               JSON.encode!(%{
                 "device_auth_id" => "device-id",
                 "user_code" => "ABCD-EFGH",
                 "interval" => "0"
               })
           }}

        String.ends_with?(options[:url], "/deviceauth/token") ->
          poll = Agent.get_and_update(counter, &{&1, &1 + 1})

          if poll == 0 do
            {:ok, %Req.Response{status: 403, body: ""}}
          else
            {:ok,
             %Req.Response{
               status: 200,
               body:
                 JSON.encode!(%{
                   "authorization_code" => "device-code",
                   "code_verifier" => "device-verifier"
                 })
             }}
          end

        String.ends_with?(options[:url], "/oauth/token") ->
          {:ok,
           %Req.Response{
             status: 200,
             body:
               JSON.encode!(%{
                 "access_token" => access_token,
                 "refresh_token" => "device-refresh",
                 "expires_in" => 3_600
               })
           }}
      end
    end

    opts = [
      interaction: {Interaction, test_pid},
      request: request,
      now: 1_000,
      sleep: fn _milliseconds -> :ok end
    ]

    assert {:ok, credentials} = Codex.login(opts)
    assert credentials["access_token"] == access_token
    assert credentials["refresh_token"] == "device-refresh"
    assert_receive {:interaction_info, info}
    assert info =~ "ABCD-EFGH"
    assert_receive {:interaction_progress, "Waiting for authorization..."}
  end

  test "login requires an interaction handle" do
    assert {:error, :interaction_required} = Codex.login(request: fn _options -> :unused end)
  end

  test "usage fetches the account report with stored credentials", %{store: store} do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:usage_request, options})
      {:ok, %Req.Response{status: 200, body: JSON.encode!(%{"plan_type" => "plus"})}}
    end

    assert {:ok, %{"plan_type" => "plus"}} =
             Codex.usage(credential_store: store, request: request)

    assert_receive {:usage_request, options}
    assert options[:method] == :get
    assert options[:url] == "https://chatgpt.com/backend-api/wham/usage"
    assert header(options, "authorization") == "Bearer access-token"
  end

  test "usage surfaces provider errors", %{store: store} do
    request = fn _options -> {:ok, %Req.Response{status: 403, body: "no usage"}} end

    assert {:error, %Error{kind: :auth, status: 403, details: "no usage"}} =
             Codex.usage(credential_store: store, request: request)
  end

  describe "provider instances" do
    setup do
      agent =
        start_supervised!(
          {Agent,
           fn ->
             %{
               "codex-work" =>
                 oauth_credentials("work-access", "work-refresh", 4_000_000_000_000),
               "codex-home" => oauth_credentials("home-access", "home-refresh", 4_000_000_000_000)
             }
           end},
          id: {Agent, make_ref()}
        )

      {:ok, providers_store: {CredentialStore, agent}, agent: agent}
    end

    test "providers on one adapter use their own credentials", %{providers_store: store} do
      test_pid = self()

      request = fn options ->
        send(test_pid, {:authorization, header(options, "authorization")})
        completed_response(options, "ok")
      end

      {:ok, work} = Provider.new("codex-work", Codex)
      {:ok, home} = Provider.new("codex-home", Codex)

      opts = Keyword.delete(base_opts(store, request), :model)

      assert {:ok, selection} = LLM.select([work, home], "codex-home/gpt-5.5")
      assert {:ok, result} = LLM.generate_with(selection, nil, opts)
      assert result.provider == "codex-home"
      assert_receive {:authorization, "Bearer home-access"}

      assert {:ok, selection} = LLM.select([work, home], "codex-work/gpt-5.5")
      assert {:ok, result} = LLM.generate_with(selection, nil, opts)
      assert result.provider == "codex-work"
      assert_receive {:authorization, "Bearer work-access"}

      missing = Keyword.put(base_opts(store, request), :provider_id, "openai-codex")
      assert {:error, :missing_codex_credentials} = generate(nil, missing)
    end

    test "refresh reads and writes the provider's namespace", %{
      providers_store: store,
      agent: agent
    } do
      :ok =
        CredentialStore.put(
          agent,
          "codex-work",
          oauth_credentials("expired-work", "work-refresh", 1)
        )

      test_pid = self()
      refreshed_access = jwt("work-account")

      request = fn options ->
        if String.ends_with?(options[:url], "/oauth/token") do
          send(test_pid, {:refresh_token, options[:form][:refresh_token]})
          token_response(refreshed_access, "rotated-work-refresh")
        else
          send(test_pid, {:authorization, header(options, "authorization")})
          completed_response(options, "ok")
        end
      end

      opts = base_opts(store, request) |> Keyword.put(:provider_id, "codex-work")

      assert {:ok, %{data: %{"content" => "ok"}}} = generate(nil, opts)
      assert_receive {:refresh_token, "work-refresh"}
      assert_receive {:authorization, authorization}
      assert authorization == "Bearer #{refreshed_access}"

      stored = Agent.get(agent, & &1)
      assert stored["codex-work"]["refresh_token"] == "rotated-work-refresh"
      assert stored["codex-home"]["refresh_token"] == "home-refresh"
      refute Map.has_key?(stored, "openai-codex")
    end

    test "refreshes of different providers do not share a lock", %{
      providers_store: store,
      agent: agent
    } do
      for {id, refresh} <- [{"codex-work", "work-refresh"}, {"codex-home", "home-refresh"}] do
        :ok = CredentialStore.put(agent, id, oauth_credentials("expired", refresh, 1))
      end

      test_pid = self()

      request = fn options ->
        if String.ends_with?(options[:url], "/oauth/token") do
          refresh = options[:form][:refresh_token]

          if refresh == "work-refresh" do
            send(test_pid, {:work_refresh_blocked, self()})

            receive do
              :release -> :ok
            end
          end

          token_response(jwt(refresh), "rotated-" <> refresh)
        else
          completed_response(options, "ok")
        end
      end

      work =
        Task.async(fn ->
          generate(nil, Keyword.put(base_opts(store, request), :provider_id, "codex-work"))
        end)

      assert_receive {:work_refresh_blocked, blocked}, 1_000

      # The work refresh still holds its lock; the home refresh must not wait for it.
      home =
        Task.async(fn ->
          generate(nil, Keyword.put(base_opts(store, request), :provider_id, "codex-home"))
        end)

      assert {:ok, %{data: %{"content" => "ok"}}} = Task.await(home, 1_000)

      send(blocked, :release)
      assert {:ok, %{data: %{"content" => "ok"}}} = Task.await(work, 1_000)

      stored = Agent.get(agent, & &1)
      assert stored["codex-work"]["refresh_token"] == "rotated-work-refresh"
      assert stored["codex-home"]["refresh_token"] == "rotated-home-refresh"
    end

    test "stamps continuation state with the provider and replays it only there", %{
      providers_store: store
    } do
      test_pid = self()

      request = fn options ->
        {:ok, body} = JSON.decode(options[:body])
        send(test_pid, {:input, body["input"]})

        streaming_response(options, [
          sse(%{
            "type" => "response.completed",
            "response" => %{
              "status" => "completed",
              "output" => [
                %{
                  "type" => "message",
                  "id" => "msg_work",
                  "role" => "assistant",
                  "status" => "completed",
                  "content" => [%{"type" => "output_text", "text" => "hi"}]
                }
              ]
            }
          })
        ])
      end

      {:ok, work} = Provider.new("codex-work", Codex)
      {:ok, home} = Provider.new("codex-home", Codex)
      {:ok, work_selection} = LLM.select([work, home], "codex-work/gpt-5.5")
      {:ok, home_selection} = LLM.select([work, home], "codex-home/gpt-5.5")
      opts = base_opts(store, request)

      assert {:ok, result} = LLM.generate_with(work_selection, nil, opts)
      assert result.provider_state["provider"] == "codex-work"
      assert result.provider_state["model"] == "gpt-5.5"
      assert_receive {:input, _first_input}

      messages = [
        %{role: :user, content: "hello"},
        %{role: :assistant, content: "hi", provider_state: result.provider_state},
        %{role: :user, content: "again"}
      ]

      opts = Keyword.put(opts, :messages, messages)

      assert {:ok, _result} = LLM.generate_with(work_selection, nil, opts)
      assert_receive {:input, replayed}
      assert Enum.any?(replayed, &(&1["id"] == "msg_work"))

      assert {:ok, _result} = LLM.generate_with(home_selection, nil, opts)
      assert_receive {:input, synthesized}
      refute Enum.any?(synthesized, &(&1["id"] == "msg_work"))
      assert Enum.any?(synthesized, &(&1["id"] == "msg_tackle_1"))
    end

    test "honours the base_url setting unless :base_url is explicit", %{providers_store: store} do
      test_pid = self()

      request = fn options ->
        send(test_pid, {:url, options[:url]})
        completed_response(options, "ok")
      end

      opts =
        base_opts(store, request)
        |> Keyword.merge(
          provider_id: "codex-work",
          provider_settings: %{"base_url" => "https://proxy.test/backend-api/"}
        )

      assert {:ok, _result} = generate(nil, opts)
      assert_receive {:url, "https://proxy.test/backend-api/codex/responses"}

      explicit = Keyword.put(opts, :base_url, "https://explicit.test")
      assert {:ok, _result} = generate(nil, explicit)
      assert_receive {:url, "https://explicit.test/codex/responses"}

      invalid = Keyword.put(opts, :provider_settings, %{"base_url" => 42})

      assert {:error, {:invalid_provider_setting, "codex-work", "base_url", 42}} =
               generate(nil, invalid)
    end
  end

  # The adapter has no `generate/2`; `Tackle.Lib.LLM` streams it with a
  # callback that drops the events.
  defp generate(schema, opts), do: Codex.stream(schema, opts, fn _event -> :ok end)

  defp completed_response(options, text) do
    streaming_response(options, [
      sse(%{
        "type" => "response.completed",
        "response" => %{
          "status" => "completed",
          "output" => [
            %{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}
          ]
        }
      })
    ])
  end

  defp token_response(access_token, refresh_token) do
    {:ok,
     %Req.Response{
       status: 200,
       body:
         JSON.encode!(%{
           "access_token" => access_token,
           "refresh_token" => refresh_token,
           "expires_in" => 3_600
         })
     }}
  end

  defp base_opts(store, request) do
    [
      model: "gpt-5.5",
      messages: [%{role: :user, content: "hello"}],
      tools: [],
      credential_store: store,
      request: request,
      transport: :sse
    ]
  end

  defp oauth_credentials(access_token, refresh_token, expires_at) do
    %{
      "type" => "oauth",
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "expires_at" => expires_at,
      "account_id" => "account-123"
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

  defp overflow_event do
    sse(%{
      "type" => "response.failed",
      "response" => %{
        "status" => "failed",
        "error" => %{
          "code" => "context_length_exceeded",
          "message" => "Your input exceeds the context window of this model."
        }
      }
    })
  end

  defp header(options, name) do
    options
    |> Keyword.fetch!(:headers)
    |> header_value(name)
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
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

  defp jwt(account_id) do
    payload =
      JSON.encode!(%{
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      })

    "header.#{Base.url_encode64(payload, padding: false)}.signature"
  end
end
