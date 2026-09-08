defmodule Tackle.Plugins.CodexTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib
  alias Tackle.Lib.{Cancellation, LLM, Loop}
  alias Tackle.Plugins.Codex

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
        system: "Be useful",
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

    assert {:ok, result} = Codex.generate(nil, opts)
    assert result.data == %{"content" => "hello", "tool_calls" => []}
    assert result.model == "gpt-5.5"
    assert result.provider == "openai-codex"
    assert result.usage["input_tokens"] == 7
    assert result.usage["cached_input_tokens"] == 2
    assert result.usage["cache_write_tokens"] == 3
    assert result.usage["reasoning_tokens"] == 1

    assert_receive {:request, request_options}
    assert request_options[:url] == "https://chatgpt.com/backend-api/codex/responses"
    assert header(request_options, "authorization") == "Bearer access-token"
    assert header(request_options, "chatgpt-account-id") == "account-123"
    assert header(request_options, "originator") == "tackle"

    assert {:ok, body} = JSON.decode(request_options[:body])
    assert body["model"] == "gpt-5.5"
    assert body["instructions"] == "Be useful"

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

  test "streams text, reasoning, and tool argument deltas across chunk boundaries", %{
    store: store
  } do
    events = [
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
             "tool_calls" => [
               %{"id" => "call-1", "name" => "search", "arguments" => "{\"query\":\"cats\"}"}
             ]
           }

    assert_receive {:event, %{type: :tool_input_delta, delta: "{\"query\":"}}
    assert_receive {:event, %{type: :tool_input_delta, delta: "\"cats\"}"}}
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
                 &1["encrypted_content"] == "opaque-reasoning")
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

  defp base_opts(store, request) do
    [
      model: "gpt-5.5",
      messages: [%{role: :user, content: "hello"}],
      tools: [],
      credential_store: store,
      request: request
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

  defp jwt(account_id) do
    payload =
      JSON.encode!(%{
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      })

    "header.#{Base.url_encode64(payload, padding: false)}.signature"
  end
end
