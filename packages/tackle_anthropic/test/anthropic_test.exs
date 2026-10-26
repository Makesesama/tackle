defmodule Tackle.Plugins.AnthropicTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.{LLM, ModelInfo}
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.Retry
  alias Tackle.Plugins.Anthropic

  @empty_schema %{"type" => "object", "properties" => %{}, "required" => []}

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
      tools: [%{name: "read", description: "Read a file", input_schema: @empty_schema}],
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
      tools: [%{name: "read", description: "Read a file", input_schema: @empty_schema}],
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

    assert {:error, %Error{kind: :context_window_exceeded, status: 400}} =
             Anthropic.generate(nil, Keyword.merge(base, request: overflow))

    generic = fn options -> feed_chunks(options, ["{\"error\":\"boom\"}"], 400) end

    assert {:error, %Error{kind: :invalid_request, status: 400, message: message}} =
             Anthropic.generate(nil, Keyword.merge(base, request: generic))

    assert message == "The provider rejected the request (HTTP 400): boom"

    max_tokens =
      fn options ->
        feed_chunks(
          options,
          [
            ~s({"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 200000 > 64000, which exceeds the maximum allowed"}})
          ],
          400
        )
      end

    assert {:error, %Error{kind: :invalid_request}} =
             Anthropic.generate(nil, Keyword.merge(base, request: max_tokens))
  end

  test "reports overload with its Retry-After and transport failures as retryable" do
    base = [
      model: "claude-opus-5-5",
      messages: [%{role: :user, content: "hello"}],
      tools: [],
      api_key: "sk-ant-api03-test"
    ]

    overloaded = fn options ->
      feed_chunks(
        options,
        [~s({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}})],
        529,
        %{"retry-after" => ["3"]}
      )
    end

    assert {:error, %Error{kind: :overloaded, status: 529, retry_after_ms: 3_000} = error} =
             Anthropic.generate(nil, Keyword.merge(base, request: overloaded))

    assert Retry.retryable?(error)

    refused = fn _options -> {:error, %Req.TransportError{reason: :econnrefused}} end

    assert {:error, %Error{kind: :transport} = error} =
             Anthropic.generate(nil, Keyword.merge(base, request: refused))

    assert Retry.retryable?(error)
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

  describe "provider instances" do
    test "providers on one adapter use their own credentials and status" do
      store =
        start_store(%{
          "claude-work" => oauth_credentials("sk-ant-oat-work", "work-refresh", future()),
          "claude-home" => %{"type" => "api_key", "api_key" => "sk-ant-api03-home"}
        })

      test_pid = self()

      request = fn options ->
        send(test_pid, {:request, options})
        feed_chunks(options, [text_wire("ok")], 200)
      end

      {:ok, work} = Provider.new("claude-work", Anthropic)
      {:ok, home} = Provider.new("claude-home", Anthropic)
      opts = provider_opts(store, request) |> Keyword.delete(:model)

      assert {:ok, selection} = LLM.select([work, home], "claude-work/claude-opus-5-5")
      assert {:ok, %{provider: "claude-work"}} = LLM.generate_with(selection, nil, opts)
      assert_receive {:request, work_options}
      assert header(work_options, "authorization") == "Bearer sk-ant-oat-work"

      assert {:ok, selection} = LLM.select([work, home], "claude-home/claude-opus-5-5")
      assert {:ok, %{provider: "claude-home"}} = LLM.generate_with(selection, nil, opts)
      assert_receive {:request, home_options}
      assert header(home_options, "x-api-key") == "sk-ant-api03-home"

      assert {:ok, :stored} =
               Anthropic.status(credential_store: store, provider_id: "claude-work")

      expired = start_store(%{"claude-home" => oauth_credentials("a", "r", 0)})

      assert {:ok, :expired} =
               Anthropic.status(credential_store: expired, provider_id: "claude-home")

      assert {:ok, :stored} =
               Anthropic.status(credential_store: store, provider_id: "claude-home")
    end

    test "refresh reads and writes the provider's namespace" do
      {CredentialStore, agent} =
        store =
        start_store(%{
          "claude-work" => oauth_credentials("sk-ant-oat-old", "work-refresh", 0),
          "claude-home" => oauth_credentials("sk-ant-oat-home", "home-refresh", future())
        })

      test_pid = self()

      request = fn options ->
        if Keyword.has_key?(options, :into) do
          send(test_pid, {:authorization, header(options, "authorization")})
          feed_chunks(options, [text_wire("ok")], 200)
        else
          {:ok, body} = JSON.decode(options[:body])
          send(test_pid, {:refresh_token, body["refresh_token"]})
          token_response("sk-ant-oat-new", "work-refresh-2")
        end
      end

      opts = provider_opts(store, request) |> Keyword.put(:provider_id, "claude-work")

      assert {:ok, %{provider: "claude-work"}} = Anthropic.generate(nil, opts)
      assert_receive {:refresh_token, "work-refresh"}
      assert_receive {:authorization, "Bearer sk-ant-oat-new"}

      stored = Agent.get(agent, & &1)
      assert stored["claude-work"]["refresh_token"] == "work-refresh-2"
      assert stored["claude-home"]["refresh_token"] == "home-refresh"
      refute Map.has_key?(stored, "anthropic")
    end

    test "refreshes of different providers do not share a lock" do
      {CredentialStore, agent} =
        store =
        start_store(%{
          "claude-work" => oauth_credentials("work-old", "work-refresh", 0),
          "claude-home" => oauth_credentials("home-old", "home-refresh", 0)
        })

      test_pid = self()

      request = fn options ->
        if Keyword.has_key?(options, :into) do
          feed_chunks(options, [text_wire("ok")], 200)
        else
          {:ok, %{"refresh_token" => refresh}} = JSON.decode(options[:body])

          if refresh == "work-refresh" do
            send(test_pid, {:work_refresh_blocked, self()})

            receive do
              :release -> :ok
            end
          end

          token_response("access-" <> refresh, "rotated-" <> refresh)
        end
      end

      generate = fn id ->
        Task.async(fn ->
          Anthropic.generate(nil, Keyword.put(provider_opts(store, request), :provider_id, id))
        end)
      end

      work = generate.("claude-work")
      assert_receive {:work_refresh_blocked, blocked}, 1_000

      # The work refresh still holds its lock; the home refresh must not wait for it.
      assert {:ok, %{provider: "claude-home"}} = Task.await(generate.("claude-home"), 1_000)

      send(blocked, :release)
      assert {:ok, %{provider: "claude-work"}} = Task.await(work, 1_000)

      stored = Agent.get(agent, & &1)
      assert stored["claude-work"]["refresh_token"] == "rotated-work-refresh"
      assert stored["claude-home"]["refresh_token"] == "rotated-home-refresh"
    end

    test "stamps continuation state with the provider id" do
      request = fn options -> feed_chunks(options, [text_wire("ok")], 200) end

      opts =
        [api_key: "sk-ant-api03-test", provider_id: "claude-work"]
        |> Keyword.merge(provider_opts(nil, request))
        |> Keyword.delete(:credential_store)

      assert {:ok, result} = Anthropic.generate(nil, opts)
      assert result.provider == "claude-work"
      assert result.provider_state["provider"] == "claude-work"
    end

    test "only the default provider falls back to ANTHROPIC_API_KEY" do
      test_pid = self()

      request = fn options ->
        send(test_pid, {:request, header(options, "x-api-key")})
        feed_chunks(options, [text_wire("ok")], 200)
      end

      opts = provider_opts(start_store(%{}), request)
      work = Keyword.put(opts, :provider_id, "claude-work")

      with_env(
        %{"ANTHROPIC_API_KEY" => "sk-ant-api03-default", "WORK_KEY" => "sk-ant-api03-work"},
        fn ->
          assert {:ok, :stored} = Anthropic.status(opts)
          assert {:ok, %{provider: "anthropic"}} = Anthropic.generate(nil, opts)
          assert_receive {:request, "sk-ant-api03-default"}

          assert {:ok, :missing} = Anthropic.status(work)

          assert {:error, {:missing_anthropic_credentials, "claude-work"}} =
                   Anthropic.generate(nil, work)

          refute_received {:request, _key}

          # A provider names its own variable with "api_key_env".
          named = Keyword.put(work, :provider_settings, %{"api_key_env" => "WORK_KEY"})
          assert {:ok, :stored} = Anthropic.status(named)
          assert {:ok, %{provider: "claude-work"}} = Anthropic.generate(nil, named)
          assert_receive {:request, "sk-ant-api03-work"}

          invalid = Keyword.put(work, :provider_settings, %{"api_key_env" => 1})

          assert {:error, {:invalid_provider_setting, "claude-work", "api_key_env", 1}} =
                   Anthropic.status(invalid)
        end
      )
    end

    test "honours the base_url setting unless :base_url is explicit" do
      test_pid = self()

      request = fn options ->
        send(test_pid, {:url, options[:url]})
        feed_chunks(options, [text_wire("ok")], 200)
      end

      opts =
        provider_opts(nil, request)
        |> Keyword.delete(:credential_store)
        |> Keyword.merge(
          api_key: "sk-ant-api03-test",
          provider_id: "claude-proxy",
          provider_settings: %{"base_url" => "https://proxy.test/"}
        )

      assert {:ok, _result} = Anthropic.generate(nil, opts)
      assert_receive {:url, "https://proxy.test/v1/messages"}

      assert {:ok, _result} =
               Anthropic.generate(nil, Keyword.put(opts, :base_url, "https://explicit.test"))

      assert_receive {:url, "https://explicit.test/v1/messages"}

      invalid = Keyword.put(opts, :provider_settings, %{"base_url" => ""})

      assert {:error, {:invalid_provider_setting, "claude-proxy", "base_url", ""}} =
               Anthropic.generate(nil, invalid)
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

  defp provider_opts(store, request) do
    [
      model: "claude-opus-5-5",
      messages: [%{role: :user, content: "hello"}],
      tools: [],
      credential_store: store,
      token_url: "https://token.test/v1/oauth/token",
      request: request
    ]
  end

  defp oauth_credentials(access_token, refresh_token, expires_at) do
    %{
      "type" => "oauth",
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "expires_at" => expires_at
    }
  end

  defp future, do: System.system_time(:millisecond) + 3_600_000

  defp token_response(access_token, refresh_token) do
    {:ok,
     %Req.Response{
       status: 200,
       headers: %{},
       body:
         JSON.encode!(%{
           "access_token" => access_token,
           "refresh_token" => refresh_token,
           "expires_in" => 3_600
         })
     }}
  end

  defp start_store(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    {CredentialStore, agent}
  end

  defp feed_chunks(options, chunks, status, headers \\ %{}) do
    into = Keyword.fetch!(options, :into)
    initial = {%Req.Request{}, %Req.Response{status: status, headers: headers, body: ""}}

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
