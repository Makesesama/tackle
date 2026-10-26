defmodule Tackle.Plugins.Ollama.ProviderTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.{Cancellation, LLM, Usage}
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Plugins.Ollama

  defmodule Store do
    @behaviour Tackle.Lib.CredentialStore
    @impl true
    def fetch({pid, result}, namespace) do
      send(pid, {:fetch, namespace})
      result
    end

    @impl true
    def put(_ref, _namespace, _credentials), do: :ok
    @impl true
    def delete(_ref, _namespace), do: :ok
  end

  defmodule Interaction do
    @behaviour Tackle.Lib.Interaction
    @impl true
    def prompt({pid, value}, opts) do
      send(pid, {:prompt, opts})
      value
    end

    @impl true
    def info(_ref, _message), do: :ok
    @impl true
    def confirm(_ref, _message), do: false
    @impl true
    def progress(_ref, _opts, fun), do: fun.()
  end

  setup do
    env = System.get_env("OLLAMA_API_KEY")
    System.delete_env("OLLAMA_API_KEY")

    on_exit(fn ->
      if env, do: System.put_env("OLLAMA_API_KEY", env), else: System.delete_env("OLLAMA_API_KEY")
    end)

    :ok
  end

  test "credentials prefer explicit keys, then stored keys, then environment" do
    System.put_env("OLLAMA_API_KEY", "environment-key")
    store = {Store, {self(), {:ok, %{"api_key" => "stored-key"}}}}

    request = fn options ->
      send(self(), {:authorization, List.keyfind(options[:headers], "authorization", 0)})
      {:ok, %{status: 200, body: completion()}}
    end

    assert {:ok, _} =
             generate(
               nil,
               opts(request, api_key: " explicit-key ", credential_store: store)
             )

    assert_received {:authorization, {"authorization", "Bearer explicit-key"}}
    refute_received {:fetch, _}
    assert {:ok, _} = generate(nil, opts(request, api_key: "", credential_store: store))
    assert_received {:fetch, "ollama-cloud"}
    assert_received {:authorization, {"authorization", "Bearer stored-key"}}

    assert {:ok, _} =
             generate(nil, opts(request, credential_store: {Store, {self(), :error}}))

    assert_received {:authorization, {"authorization", "Bearer environment-key"}}
  end

  test "missing or invalid credentials and failed stores never send a request" do
    request = fn _ -> flunk("unexpected HTTP request") end

    assert {:error, {:missing_ollama_api_key, "ollama-cloud"}} =
             generate(nil, opts(request))

    assert {:error, {:credential_store_failed, :unavailable}} =
             generate(
               nil,
               opts(request, credential_store: {Store, {self(), {:error, :unavailable}}})
             )

    assert {:error, :invalid_ollama_credentials} =
             generate(
               nil,
               opts(request, credential_store: {Store, {self(), {:ok, "invalid"}}})
             )

    for key <- ["bad\r\nkey", "bad key", "bad\tkey"] do
      assert {:error, :invalid_api_key} = generate(nil, opts(request, api_key: key))
    end
  end

  test "credentials are namespaced by provider id" do
    {:ok, provider} =
      Provider.new("ollama-work", Ollama, %{
        "base_url" => "https://ollama.com/v1",
        "api_key" => "required",
        "models" => ["gpt-oss:120b"]
      })

    System.put_env("OLLAMA_API_KEY", "environment-key")
    {:ok, selection} = LLM.select([Ollama, provider], "ollama-work/gpt-oss:120b")
    parent = self()

    request = fn options ->
      send(parent, {:authorization, List.keyfind(options[:headers], "authorization", 0)})
      {:ok, %{status: 200, body: completion()}}
    end

    store = {Store, {self(), {:ok, %{"key" => "work-key"}}}}

    assert {:ok, result} =
             LLM.generate_with(selection, nil,
               messages: [%{role: :user, content: "hi"}],
               credential_store: store,
               request: request
             )

    assert result.provider == "ollama-work"
    assert_received {:fetch, "ollama-work"}
    assert_received {:authorization, {"authorization", "Bearer work-key"}}

    # Only providers that name an environment variable read one.
    assert {:error, {:missing_ollama_api_key, "ollama-work"}} =
             LLM.generate_with(selection, nil,
               messages: [%{role: :user, content: "hi"}],
               credential_store: {Store, {self(), :error}},
               request: fn _ -> flunk("unexpected HTTP request") end
             )

    custom_env = Map.put(selection.provider_settings, "api_key_env", "OLLAMA_WORK_KEY")
    System.put_env("OLLAMA_WORK_KEY", "work-environment-key")
    on_exit(fn -> System.delete_env("OLLAMA_WORK_KEY") end)

    assert {:ok, _} =
             LLM.generate_with(%{selection | provider_settings: custom_env}, nil,
               messages: [%{role: :user, content: "hi"}],
               request: request
             )

    assert_received {:authorization, {"authorization", "Bearer work-environment-key"}}

    # An invalid "api_key" setting may hold a pasted key, so it is not echoed.
    secret = "sk-pasted-by-mistake"

    assert {:error, {:invalid_provider_settings, "ollama-work", {"api_key", :invalid}}} =
             reason =
             generate(
               nil,
               opts(nil,
                 provider_id: "ollama-work",
                 provider_settings: %{"api_key" => secret, "models" => ["gpt-oss:120b"]}
               )
             )

    refute inspect(reason) =~ secret

    assert {:error, {:invalid_provider_settings, "ollama-work", {"api_key", :invalid}}} =
             Ollama.status(
               provider_id: "ollama-work",
               provider_settings: %{"api_key" => secret}
             )

    # Malformed settings are not echoed either.
    assert {:error, {:invalid_provider_settings, "ollama-work", :not_a_map}} =
             Ollama.status(provider_id: "ollama-work", provider_settings: [api_key: secret])
  end

  test "login uses a secret interaction prompt and propagates failures" do
    cloud = [provider_id: "ollama-cloud"]

    assert {:ok, %{"api_key" => "prompt-key"}} =
             Ollama.login([interaction: {Interaction, {self(), {:ok, " prompt-key "}}}] ++ cloud)

    assert_received {:prompt, options}
    assert options[:secret]

    assert {:error, :empty_api_key} =
             Ollama.login([interaction: {Interaction, {self(), {:ok, " "}}}] ++ cloud)

    assert {:error, :cancelled} =
             Ollama.login([interaction: {Interaction, {self(), {:error, :cancelled}}}] ++ cloud)

    assert {:error, :interaction_required} = Ollama.login(cloud)
  end

  test "keyless providers need no login" do
    interaction = {Interaction, {self(), {:ok, "key"}}}

    assert {:error, {:login_not_required, "ollama"}} = Ollama.login(interaction: interaction)

    assert {:error, {:login_not_required, "gpu-box"}} =
             Ollama.login(
               interaction: interaction,
               provider_id: "gpu-box",
               provider_settings: %{"api_key" => "none"}
             )

    refute_received {:prompt, _}
    assert {:ok, :not_required} = Ollama.status([])
    assert {:ok, :not_required} = Ollama.status(provider_id: "gpu-box", provider_settings: %{})
  end

  test "status reports stored, environment, and missing keys per provider" do
    cloud = [provider_id: "ollama-cloud"]
    stored = {Store, {self(), {:ok, %{"api_key" => "stored-key"}}}}

    assert {:ok, :stored} = Ollama.status([credential_store: stored] ++ cloud)
    assert_received {:fetch, "ollama-cloud"}

    assert {:ok, :missing} = Ollama.status([credential_store: {Store, {self(), :error}}] ++ cloud)
    System.put_env("OLLAMA_API_KEY", "environment-key")
    assert {:ok, :stored} = Ollama.status([credential_store: {Store, {self(), :error}}] ++ cloud)

    assert {:error, {:credential_store_failed, :unavailable}} =
             Ollama.status([credential_store: {Store, {self(), {:error, :unavailable}}}] ++ cloud)

    work = [provider_id: "ollama-work", provider_settings: %{"api_key" => "required"}]
    assert {:ok, :missing} = Ollama.status([credential_store: {Store, {self(), :error}}] ++ work)
    assert_received {:fetch, "ollama-work"}
  end

  test "native tools round-trip synthesized ids and reasoning" do
    stream = fn options, initial, callback ->
      send(self(), {:body, JSON.decode!(options[:body])})

      wire =
        frame(%{"reasoning" => "considering"}) <>
          frame(%{
            "tool_calls" => [
              %{"index" => 0, "function" => %{"name" => "search", "arguments" => "{}"}}
            ]
          }) <>
          frame(%{}, "tool_calls") <> "data: [DONE]\n\n"

      {:cont, parser} = callback.(wire, %{status: 200}, initial)
      {:ok, %{status: 200}, parser}
    end

    options = opts(nil, api_key: "key", stream: stream)
    assert {:ok, result} = generate(nil, options)
    assert_received {:body, _}
    [call] = result.data["tool_calls"]

    messages = [
      %{
        role: :assistant,
        content: nil,
        tool_calls: [call],
        provider_state: result.provider_state
      },
      %{role: :tool, tool_call_id: call["id"], content: "found"}
    ]

    assert {:ok, _} = generate(nil, Keyword.put(options, :messages, messages))
    assert_received {:body, %{"messages" => [assistant, tool]}}
    assert assistant["reasoning"] == "considering"
    assert tool["tool_call_id"] == call["id"]
    assert hd(assistant["tool_calls"])["id"] == call["id"]
  end

  test "malformed or unanswered historical calls fail before HTTP" do
    request = fn _ -> flunk("unexpected request") end
    call = %{id: "old", name: "search", arguments: "{}"}

    assert {:error, {:invalid_tool_history, :missing_tool_results}} =
             generate(
               nil,
               opts(request, api_key: "key", messages: [%{role: :assistant, tool_calls: [call]}])
             )

    assert {:error, {:invalid_tool_history, {:unexpected_tool_result, "old"}}} =
             generate(
               nil,
               opts(request,
                 api_key: "key",
                 messages: [%{role: :tool, tool_call_id: "old", content: "found"}]
               )
             )
  end

  test "preserves bounded streamed HTTP errors and classifies only specific overflow" do
    for {status, body, kind} <- [
          {400, %{"error" => %{"message" => "bad request", "request" => "too many tokens"}},
           :invalid_request},
          {401, %{"error" => "maximum context length"}, :auth},
          {400, %{"error" => "maximum context length exceeded"}, :context_window_exceeded},
          {400, %{"error" => "the input length exceeds the context length"},
           :context_window_exceeded}
        ] do
      stream = fn _, initial, callback ->
        {:cont, acc} = callback.(JSON.encode!(body), %{status: status}, initial)
        {:ok, %{status: status}, acc}
      end

      assert {:error, %Error{kind: ^kind, status: ^status, details: ^body}} =
               generate(nil, opts(nil, api_key: "key", stream: stream))
    end

    stream = fn _, initial, callback ->
      {:cont, acc} = callback.(String.duplicate("x", 20_000), %{status: 500}, initial)
      {:ok, %{status: 500}, acc}
    end

    assert {:error, %Error{kind: :server, status: 500, details: body}} =
             generate(nil, opts(nil, api_key: "key", stream: stream))

    assert byte_size(body) <= 16_384
  end

  test "passes a rate limit's Retry-After through" do
    stream = fn _, initial, callback ->
      response = %{status: 429, headers: %{"retry-after" => ["4"]}}
      {:cont, acc} = callback.(~s({"error":"too many requests"}), response, initial)
      {:ok, response, acc}
    end

    assert {:error, %Error{kind: :rate_limited, retry_after_ms: 4_000} = error} =
             generate(nil, opts(nil, api_key: "key", stream: stream))

    assert Tackle.Lib.Retry.retryable?(error)
  end

  test "in-stream overflow is retriable only before output; transport errors stay errors" do
    error = sse(%{"error" => %{"message" => "maximum context length exceeded"}})

    assert {:error, %Error{kind: :context_window_exceeded}} =
             generate(
               nil,
               opts(fn _ -> {:ok, %{status: 200, body: error}} end, api_key: "key")
             )

    request = fn _ -> {:ok, %{status: 200, body: frame(%{"content" => "partial"}) <> error}} end

    assert {:error, %Error{kind: :invalid_response}} =
             generate(nil, opts(request, api_key: "key"))

    assert {:error, %Error{kind: :timeout}} =
             generate(nil, opts(fn _ -> {:error, :timeout} end, api_key: "key"))

    refused = fn _ -> {:error, %Req.TransportError{reason: :econnrefused}} end

    assert {:error, %Error{kind: :transport} = transport} =
             generate(nil, opts(refused, api_key: "key"))

    assert Tackle.Lib.Retry.retryable?(transport)
  end

  test "cancellation before HTTP and during streams fails without returning partial output" do
    signal = Cancellation.new_signal()
    on_exit(fn -> Cancellation.delete(signal) end)

    stream = fn _, initial, callback ->
      {:cont, acc} = callback.(frame(%{"content" => "one"}), %{status: 200}, initial)
      {:halt, acc} = callback.(frame(%{}, "stop"), %{status: 200}, acc)
      {:ok, %{status: 200}, acc}
    end

    assert {:error, :cancelled} =
             Ollama.stream(
               nil,
               opts(nil, api_key: "key", stream: stream, cancellation_signal: signal),
               fn _ -> Cancellation.cancel(signal) end
             )

    assert {:error, :cancelled} =
             generate(
               nil,
               opts(fn _ -> flunk("unexpected HTTP") end,
                 api_key: "key",
                 cancellation_signal: signal
               )
             )
  end

  test "LLM wrapper normalizes usage without inventing prices" do
    wire =
      frame(%{"content" => "ok"}, "stop") <>
        sse(%{"choices" => [], "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2}}) <>
        "data: [DONE]\n\n"

    assert {:ok, result} =
             LLM.generate_with(
               Ollama,
               nil,
               opts(fn _ -> {:ok, %{status: 200, body: wire}} end, api_key: "key")
             )

    assert %Usage{input_tokens: 5, output_tokens: 2, total_tokens: 7, cost: nil} = result.usage
  end

  # The adapter has no `generate/2`; `Tackle.Lib.LLM` streams it with a
  # callback that drops the events.
  defp generate(schema, opts), do: Ollama.stream(schema, opts, fn _event -> :ok end)

  defp opts(request, extra \\ []),
    do:
      Keyword.merge(
        [
          provider_id: "ollama-cloud",
          model: "gpt-oss:120b",
          messages: [%{role: :user, content: "hello"}],
          request: request
        ],
        extra
      )

  defp completion, do: frame(%{"content" => "ok"}, "stop") <> "data: [DONE]\n\n"

  defp frame(delta, finish \\ nil),
    do: sse(%{"choices" => [%{"delta" => delta, "finish_reason" => finish}]})

  defp sse(event), do: "data: #{JSON.encode!(event)}\n\n"
end
