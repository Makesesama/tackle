defmodule Tackle.Plugins.CodexTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib
  alias Tackle.Lib.{Cancellation, LLM, Loop, ModelInfo, Usage}
  alias Tackle.Plugins.Codex
  alias Tackle.Plugins.Codex.SSE

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
        reasoning_effort: "high",
        reasoning_summary: "auto",
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
          %{
            name: "search",
            description: "Search documents",
            input_schema: [query: [type: :string, required: true, description: "Query"]],
            definition_id: "ignored-by-provider"
          }
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
    assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}
    refute Map.has_key?(body, "temperature")

    assert Enum.any?(
             body["input"],
             &(&1["type"] == "function_call" and &1["call_id"] == "call-old")
           )

    assert Enum.any?(
             body["input"],
             &(&1["type"] == "function_call_output" and &1["call_id"] == "call-old")
           )

    assert [%{"name" => "search", "parameters" => parameters}] = body["tools"]
    assert parameters["required"] == ["query"]
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

    assert {:ok, %{data: %{"content" => "continued"}}} = Codex.generate(nil, opts)
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

    assert {:ok, %{data: %{"content" => "websocket"}}} = Codex.generate(nil, opts)

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

    assert {:ok, %{data: %{"content" => "fallback"}}} = Codex.generate(nil, opts)
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

    assert {:error, {:websocket_transport_failed, :after_stream, "closed"}} =
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
           {:websocket_transport_failed, :before_stream, {:http_error, 401, "unauthorized"}}}

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

    assert {:ok, %{data: %{"content" => "retried"}}} = Codex.generate(nil, opts)
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
             Codex.generate(nil, base_opts(store, request))

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
             Codex.generate(nil, base_opts(store, request))

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

    assert {:error, :cancelled} = Codex.generate(nil, opts)
  end

  test "reports missing credentials without making a request" do
    store_agent = start_supervised!({Agent, fn -> %{} end}, id: {Agent, make_ref()})
    store = {CredentialStore, store_agent}

    assert {:error, :missing_codex_credentials} =
             Codex.generate(nil, base_opts(store, fn _options -> flunk("unexpected request") end))
  end

  test "preserves a streamed HTTP error body", %{store: store} do
    body = JSON.encode!(%{"detail" => "No tool output found for function call call-1."})

    request = fn options ->
      streaming_response(options, split_binary(body, [5, 17]), 400)
    end

    assert {:error, {:http_error, 400, ^body}} =
             Codex.generate(nil, base_opts(store, request))
  end

  test "does not expose the stream accumulator for a bodyless HTTP error", %{store: store} do
    stream = fn _options, initial_acc, _callback ->
      {:ok, %Req.Response{status: 400, body: nil}, initial_acc}
    end

    opts = base_opts(store, fn _options -> flunk("unexpected legacy request") end)
    opts = Keyword.put(opts, :stream, stream)

    assert {:error, {:http_error, 400, ""}} = Codex.generate(nil, opts)
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

    assert {:error, :context_window_exceeded} = Codex.generate(nil, base_opts(store, request))
  end

  test "does not classify generic 4xx errors as overflow", %{store: store} do
    request = fn _options -> {:ok, %Req.Response{status: 400, body: "bad request"}} end

    assert {:error, {:http_error, 400, "bad request"}} =
             Codex.generate(nil, base_opts(store, request))
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

    assert {:error, {:http_error, 403, "no usage"}} =
             Codex.usage(credential_store: store, request: request)
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
