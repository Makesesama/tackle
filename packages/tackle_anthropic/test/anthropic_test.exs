defmodule Tackle.Plugins.AnthropicTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.{LLM, ModelInfo}
  alias Tackle.Plugins.Anthropic

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
      text = IO.iodata_to_binary(message)
      send(reference, {:interaction_info, text})

      case Regex.run(~r/[?&]state=([A-Za-z0-9]+)/, text) do
        [_, state] -> Process.put(:oauth_state, state)
        _no_match -> :ok
      end

      :ok
    end

    @impl true
    def prompt(reference, opts) do
      send(reference, {:interaction_prompt, opts})

      case Process.get(:prompt_result) do
        nil -> {:ok, "auth-code##{Process.get(:oauth_state)}"}
        result -> result
      end
    end

    @impl true
    def confirm(_reference, _message), do: false

    @impl true
    def progress(reference, opts, fun) do
      send(reference, {:interaction_progress, Keyword.get(opts, :label)})
      fun.()
    end
  end

  test "exposes the Anthropic catalog with limits and price cards" do
    assert Anthropic.adapter_id() == "anthropic"
    assert "claude-opus-5-5" in Anthropic.models()

    assert {:ok, %ModelInfo{} = opus} = LLM.model_info(Anthropic, "claude-opus-5-5")
    assert opus.context_window == 1_000_000
    assert opus.max_output_tokens == 128_000
    assert opus.pricing.input == 4
    assert opus.pricing.output == 20
    assert opus.pricing.cache_read == 0.2
    assert opus.pricing.cache_write == 5
    assert opus.pricing.currency == "USD"

    assert {:ok, %ModelInfo{} = haiku} = LLM.model_info(Anthropic, "claude-haiku-4-5")
    assert haiku.context_window == 200_000
    assert haiku.max_output_tokens == 64_000

    assert {:ok, nil} = LLM.model_info(Anthropic, "unknown")
    assert {:ok, selection} = LLM.select([Anthropic], "anthropic/claude-opus-5-5")
    assert selection.model == "claude-opus-5-5"
  end

  test "generates with an API key and translates messages, tools, and system" do
    test_pid = self()

    request = fn options ->
      send(test_pid, {:request, options})
      feed_chunks(options, [text_wire("cli")], 200)
    end

    opts = [
      model: "claude-opus-5-5",
      messages: [%{role: :user, content: "hello"}],
      tools: [%{name: "read", description: "Read a file", input_schema: []}],
      system: "Be useful",
      temperature: 0.3,
      max_tokens: 4_096,
      api_key: "sk-ant-api03-test",
      request: request
    ]

    assert {:ok, result} = Anthropic.generate(nil, opts)
    assert result.data["content"] == "cli"
    assert result.provider == "anthropic"

    assert_receive {:request, request_options}
    assert request_options[:url] == "https://api.anthropic.com/v1/messages"
    assert header(request_options, "x-api-key") == "sk-ant-api03-test"
    assert header(request_options, "anthropic-version") == "2023-06-01"
    assert header(request_options, "anthropic-beta") == "interleaved-thinking-2025-05-14"
    assert header(request_options, "authorization") == nil

    assert {:ok, body} = JSON.decode(request_options[:body])
    assert body["model"] == "claude-opus-5-5"
    assert body["max_tokens"] == 4_096
    assert body["stream"] == true
    assert body["temperature"] == 0.3
    refute Map.has_key?(body, "thinking")

    assert [%{"type" => "text", "text" => "Be useful", "cache_control" => _}] = body["system"]
    assert [%{"name" => "read"}] = body["tools"]
    assert body["tool_choice"] == %{"type" => "auto"}
  end

  test "uses OAuth credentials with Claude Code headers and namespaced tools" do
    store =
      start_store(%{
        "anthropic" => %{
          "type" => "oauth",
          "access_token" => "sk-ant-oat-1",
          "refresh_token" => "refresh-1",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        }
      })

    test_pid = self()

    request = fn options ->
      send(test_pid, {:request, options})
      feed_chunks(options, [text_wire("ok")], 200)
    end

    opts = [
      model: "claude-opus-5-5",
      messages: [%{role: :user, content: "hello"}],
      tools: [%{name: "read", description: "Read a file", input_schema: []}],
      system: "Be useful",
      credential_store: store,
      request: request
    ]

    assert {:ok, result} = Anthropic.generate(nil, opts)
    assert result.data["content"] == "ok"

    assert_receive {:request, request_options}
    assert header(request_options, "authorization") == "Bearer sk-ant-oat-1"
    assert header(request_options, "x-api-key") == nil
    assert header(request_options, "x-app") == "cli"
    assert header(request_options, "user-agent") == "claude-cli/2.1.280 (external, cli)"

    assert header(request_options, "anthropic-beta") ==
             "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14"

    assert {:ok, body} = JSON.decode(request_options[:body])
    assert [billing, identity, host] = body["system"]
    assert billing["text"] =~ "x-anthropic-billing-header:"
    assert identity["text"] =~ "You are a Claude agent"
    assert host["text"] == "Be useful"
    assert [%{"name" => "Read"}] = body["tools"]
  end

  test "refreshes OAuth credentials and retries once after a 401" do
    store =
      start_store(%{
        "anthropic" => %{
          "type" => "oauth",
          "access_token" => "sk-ant-oat-old",
          "refresh_token" => "refresh-1",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        }
      })

    test_pid = self()

    request = fn options ->
      cond do
        not Keyword.has_key?(options, :into) ->
          send(test_pid, {:token_request, options})

          {:ok,
           %Req.Response{
             status: 200,
             headers: %{},
             body:
               JSON.encode!(%{
                 "access_token" => "sk-ant-oat-new",
                 "refresh_token" => "refresh-2",
                 "expires_in" => 3_600
               })
           }}

        Process.get(:messages_attempts, 0) == 0 ->
          Process.put(:messages_attempts, 1)
          send(test_pid, {:rejected, options})
          feed_chunks(options, ["{\"error\":{\"message\":\"token expired\"}}"], 401)

        true ->
          send(test_pid, {:retry, options})
          feed_chunks(options, [text_wire("retried")], 200)
      end
    end

    opts = [
      model: "claude-opus-5-5",
      messages: [%{role: :user, content: "hello"}],
      tools: [],
      credential_store: store,
      token_url: "https://token.test/v1/oauth/token",
      request: request
    ]

    assert {:ok, result} = Anthropic.generate(nil, opts)
    assert result.data["content"] == "retried"

    assert_receive {:rejected, rejected_options}
    assert header(rejected_options, "authorization") == "Bearer sk-ant-oat-old"

    assert_receive {:token_request, token_options}
    assert token_options[:url] == "https://token.test/v1/oauth/token"
    assert {:ok, token_body} = JSON.decode(token_options[:body])
    assert token_body["grant_type"] == "refresh_token"
    assert token_body["refresh_token"] == "refresh-1"

    assert_receive {:retry, retry_options}
    assert header(retry_options, "authorization") == "Bearer sk-ant-oat-new"

    assert {:ok, %{"access_token" => "sk-ant-oat-new", "refresh_token" => "refresh-2"}} =
             Tackle.Lib.CredentialStore.fetch(store, "anthropic")
  end

  test "classifies context overflow but not generic provider errors" do
    overflow = fn options ->
      feed_chunks(
        options,
        [
          "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 250000 tokens > 200000 maximum\"}}"
        ],
        400
      )
    end

    base = [
      model: "claude-opus-5-5",
      messages: [%{role: :user, content: "hello"}],
      tools: [],
      api_key: "sk-ant-api03-test"
    ]

    assert {:error, :context_window_exceeded} =
             Anthropic.generate(nil, Keyword.merge(base, request: overflow))

    generic = fn options -> feed_chunks(options, ["{\"error\":\"boom\"}"], 400) end

    assert {:error, {:http_error, 400, _body}} =
             Anthropic.generate(nil, Keyword.merge(base, request: generic))
  end

  test "login prompts for an API key" do
    Process.put(:prompt_result, {:ok, "  sk-ant-api03-key  "})

    assert {:ok, credentials} =
             Anthropic.login(auth: :api_key, interaction: {Interaction, self()})

    assert credentials == %{"type" => "api_key", "api_key" => "sk-ant-api03-key"}
    assert_receive {:interaction_prompt, opts}
    assert opts[:label] == "Anthropic API key"
    assert opts[:secret] == true
  end

  test "login runs the OAuth paste flow" do
    Process.delete(:prompt_result)
    Process.delete(:oauth_state)

    request = fn _options ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: %{},
         body:
           JSON.encode!(%{
             "access_token" => "sk-ant-oat-1",
             "refresh_token" => "refresh-1",
             "expires_in" => 3_600
           })
       }}
    end

    assert {:ok, credentials} =
             Anthropic.login(
               auth: :oauth,
               interaction: {Interaction, self()},
               token_url: "https://token.test/v1/oauth/token",
               request: request
             )

    assert credentials["access_token"] == "sk-ant-oat-1"
    assert_receive {:interaction_info, info}
    assert info =~ "claude.ai/oauth/authorize"
    assert_receive {:interaction_prompt, _opts}
  end

  test "status reports stored, expired, and missing credentials" do
    future = System.system_time(:millisecond) + 3_600_000

    stored =
      start_store(%{
        "anthropic" => %{
          "type" => "oauth",
          "access_token" => "sk-ant-oat-1",
          "refresh_token" => "r1",
          "expires_at" => future
        }
      })

    assert {:ok, :stored} = Anthropic.status(credential_store: stored)

    expired =
      start_store(%{
        "anthropic" => %{
          "type" => "oauth",
          "access_token" => "sk-ant-oat-1",
          "refresh_token" => "r1",
          "expires_at" => 0
        }
      })

    assert {:ok, :expired} = Anthropic.status(credential_store: expired)

    api_key = start_store(%{"anthropic" => %{"type" => "api_key", "api_key" => "sk-ant-api03-x"}})
    assert {:ok, :stored} = Anthropic.status(credential_store: api_key)

    assert {:ok, :stored} = Anthropic.status(api_key: "sk-ant-api03-explicit")

    empty = start_store(%{})
    assert {:ok, :missing} = Anthropic.status(credential_store: empty)
  end

  defp start_store(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    {CredentialStore, agent}
  end

  defp feed_chunks(options, chunks, status) do
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

  defp text_wire(text) do
    sse("message_start", %{
      "message" => %{"model" => "claude-opus-5-5", "usage" => %{"input_tokens" => 5}}
    }) <>
      sse("content_block_delta", %{
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      }) <>
      sse("message_delta", %{
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 2}
      }) <>
      sse("message_stop", %{})
  end

  defp sse(type, payload) do
    payload = Map.put(payload, "type", type)
    "event: #{type}\ndata: #{JSON.encode!(payload)}\n\n"
  end

  defp header(options, name) do
    options
    |> Keyword.fetch!(:headers)
    |> Enum.find_value(fn {key, value} -> if key == name, do: value end)
  end
end
