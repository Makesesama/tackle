defmodule Tackle.Plugins.Ollama.ProviderTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.{Cancellation, LLM, Usage}
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
             Ollama.generate(
               nil,
               opts(request, api_key: " explicit-key ", credential_store: store)
             )

    assert_received {:authorization, {"authorization", "Bearer explicit-key"}}
    refute_received {:fetch, _}
    assert {:ok, _} = Ollama.generate(nil, opts(request, api_key: "", credential_store: store))
    assert_received {:fetch, "ollama-cloud"}
    assert_received {:authorization, {"authorization", "Bearer stored-key"}}

    assert {:ok, _} =
             Ollama.generate(nil, opts(request, credential_store: {Store, {self(), :error}}))

    assert_received {:authorization, {"authorization", "Bearer environment-key"}}
  end

  test "missing or invalid credentials and failed stores never send a request" do
    request = fn _ -> flunk("unexpected HTTP request") end
    assert {:error, :missing_ollama_api_key} = Ollama.generate(nil, opts(request))

    assert {:error, {:credential_store_failed, :unavailable}} =
             Ollama.generate(
               nil,
               opts(request, credential_store: {Store, {self(), {:error, :unavailable}}})
             )

    assert {:error, :invalid_ollama_credentials} =
             Ollama.generate(
               nil,
               opts(request, credential_store: {Store, {self(), {:ok, "invalid"}}})
             )

    for key <- ["bad\r\nkey", "bad key", "bad\tkey"] do
      assert {:error, :invalid_api_key} = Ollama.generate(nil, opts(request, api_key: key))
    end
  end

  test "login uses a secret interaction prompt and propagates failures" do
    assert {:ok, %{"api_key" => "prompt-key"}} =
             Ollama.login(interaction: {Interaction, {self(), {:ok, " prompt-key "}}})

    assert_received {:prompt, options}
    assert options[:secret]

    assert {:error, :empty_api_key} =
             Ollama.login(interaction: {Interaction, {self(), {:ok, " "}}})

    assert {:error, :cancelled} =
             Ollama.login(interaction: {Interaction, {self(), {:error, :cancelled}}})

    assert {:error, :interaction_required} = Ollama.login([])
  end

  test "native tools round-trip synthesized ids and reasoning only for matching provider/model" do
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
    assert {:ok, result} = Ollama.generate(nil, options)
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

    assert {:ok, _} = Ollama.generate(nil, Keyword.put(options, :messages, messages))
    assert_received {:body, %{"messages" => [assistant, tool]}}
    assert assistant["reasoning"] == "considering"
    assert tool["tool_call_id"] == call["id"]
    assert hd(assistant["tool_calls"])["id"] == call["id"]
    other = put_in(hd(messages), [:provider_state, "provider"], "other")

    assert {:ok, _} =
             Ollama.generate(nil, Keyword.put(options, :messages, [other, List.last(messages)]))

    assert_received {:body, %{"messages" => [assistant, _]}}
    refute Map.has_key?(assistant, "reasoning")
  end

  test "malformed or unanswered historical calls fail before HTTP" do
    request = fn _ -> flunk("unexpected request") end
    call = %{id: "old", name: "search", arguments: "{}"}

    assert {:error, {:invalid_tool_history, :missing_tool_results}} =
             Ollama.generate(
               nil,
               opts(request, api_key: "key", messages: [%{role: :assistant, tool_calls: [call]}])
             )

    assert {:error, {:invalid_tool_history, {:unexpected_tool_result, "old"}}} =
             Ollama.generate(
               nil,
               opts(request,
                 api_key: "key",
                 messages: [%{role: :tool, tool_call_id: "old", content: "found"}]
               )
             )
  end

  test "preserves bounded streamed HTTP errors and classifies only specific overflow" do
    for {status, body, expected} <- [
          {400, %{"error" => %{"message" => "bad request", "request" => "too many tokens"}},
           {:http_error, 400,
            %{"error" => %{"message" => "bad request", "request" => "too many tokens"}}}},
          {401, %{"error" => "maximum context length"},
           {:http_error, 401, %{"error" => "maximum context length"}}},
          {400, %{"error" => "maximum context length exceeded"}, :context_window_exceeded}
        ] do
      stream = fn _, initial, callback ->
        {:cont, acc} = callback.(JSON.encode!(body), %{status: status}, initial)
        {:ok, %{status: status}, acc}
      end

      assert {:error, ^expected} = Ollama.generate(nil, opts(nil, api_key: "key", stream: stream))
    end

    stream = fn _, initial, callback ->
      {:cont, acc} = callback.(String.duplicate("x", 20_000), %{status: 500}, initial)
      {:ok, %{status: 500}, acc}
    end

    assert {:error, {:http_error, 500, body}} =
             Ollama.generate(nil, opts(nil, api_key: "key", stream: stream))

    assert byte_size(body) <= 4_096
  end

  test "in-stream overflow is retriable only before output; transport errors stay errors" do
    error = sse(%{"error" => %{"message" => "maximum context length exceeded"}})

    assert {:error, :context_window_exceeded} =
             Ollama.generate(
               nil,
               opts(fn _ -> {:ok, %{status: 200, body: error}} end, api_key: "key")
             )

    request = fn _ -> {:ok, %{status: 200, body: frame(%{"content" => "partial"}) <> error}} end
    assert {:error, {:provider_error, _}} = Ollama.generate(nil, opts(request, api_key: "key"))

    assert {:error, {:request_failed, :timeout}} =
             Ollama.generate(nil, opts(fn _ -> {:error, :timeout} end, api_key: "key"))
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
             Ollama.generate(
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

  defp opts(request, extra \\ []),
    do:
      Keyword.merge(
        [model: "gpt-oss:120b", messages: [%{role: :user, content: "hello"}], request: request],
        extra
      )

  defp completion, do: frame(%{"content" => "ok"}, "stop") <> "data: [DONE]\n\n"

  defp frame(delta, finish \\ nil),
    do: sse(%{"choices" => [%{"delta" => delta, "finish_reason" => finish}]})

  defp sse(event), do: "data: #{JSON.encode!(event)}\n\n"
end
