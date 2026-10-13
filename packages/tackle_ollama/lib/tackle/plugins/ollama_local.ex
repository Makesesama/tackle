defmodule Tackle.Plugins.OllamaLocal do
  @moduledoc """
  Adapter for a local Ollama server, implementing `Tackle.Lib.LLM` and
  `Tackle.Lib.Decision`.

  Chat requests go to Ollama's OpenAI-compatible `/chat/completions` endpoint
  through the same transport as `Tackle.Plugins.Ollama`, but under the adapter
  id `"ollama"` and without an API key or authorization header. Decision
  requests go to Ollama's System One endpoint (`/systemone`), which answers
  typed questions with decision models such as `tev1:4b`.

  Nothing is discovered from the server: chat and decision models are
  selectable only when the host configures them.

      config :tackle_ollama, Tackle.Plugins.OllamaLocal,
        base_url: "http://localhost:11434/v1",
        models: ["qwen3:8b", {"gpt-oss:20b", %{context_window: 131_072}}],
        decision_models: ["tev1:4b"]

      {:ok, llm} = Tackle.Lib.LLM.select([Tackle.Plugins.OllamaLocal], "ollama/qwen3:8b")
      {:ok, decision} = Tackle.Lib.Decision.select([Tackle.Plugins.OllamaLocal], "ollama/tev1:4b")

  Model entries are ids or `{id, model_info}` tuples, like the `:models` option
  of `Tackle.Plugins.Ollama`; `model_info/1` returns the configured chat model
  metadata.

  ## Base URL

  The OpenAI-compatible base URL (default `http://localhost:11434/v1`) is
  resolved per request, first match wins:

    1. the `:base_url` request option;
    2. `opts[:provider_options]["ollama"]["base_url"]` (the harness passes
       `config.json` `"provider_options"` here);
    3. the `:base_url` application configuration above;
    4. the default.

  ## Decision options

  `decide/2` honours `:cancellation_signal` (an in-flight request is abandoned
  and `{:error, :cancelled}` returned) and `:receive_timeout` (default 60,000 ms;
  a model may need to load on first use).

  The adapter declares its decision models local (`local?/0` is `true`): they
  run on a server the user hosts, so hosts may leave their usage out of token
  budgets. That assumes the base URL points at a self-hosted server; a base
  URL that reaches a paid endpoint is still treated as local.
  """

  @behaviour Tackle.Lib.LLM
  @behaviour Tackle.Lib.Decision

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Decision.{Answer, Question, Request, Result}
  alias Tackle.Plugins.Ollama
  alias Tackle.Plugins.Ollama.HTTP

  @adapter_id "ollama"
  @default_base_url "http://localhost:11434/v1"
  @default_decision_timeout 60_000
  @max_error_body_bytes 16_384

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def models, do: configured_ids(:models)

  @impl true
  def model_info(model) do
    case List.keyfind(configured_entries(:models), model, 0) do
      {^model, info} -> info
      nil -> nil
    end
  end

  @impl Tackle.Lib.Decision
  def decision_models, do: configured_ids(:decision_models)

  @impl Tackle.Lib.Decision
  def local?, do: true

  @impl true
  def generate(schema, opts), do: chat(schema, opts, fn _event -> :ok end)

  @impl true
  def stream(schema, opts, event_callback) when is_function(event_callback, 1),
    do: chat(schema, opts, event_callback)

  defp chat(schema, opts, event_callback) do
    with {:ok, base_url} <- base_url(opts) do
      Ollama.chat(profile(), schema, Keyword.put(opts, :base_url, base_url), event_callback)
    end
  end

  defp profile do
    %{
      adapter_id: @adapter_id,
      models: &models/0,
      base_url: &Keyword.fetch!(&1, :base_url),
      api_key: :none,
      user_agent: "tackle-ollama"
    }
  end

  @impl true
  def decide(%Request{} = request, opts) when is_list(opts) do
    with :ok <- Request.validate(request),
         :ok <- validate_decision_model(request.model),
         :ok <- not_cancelled(opts),
         {:ok, base_url} <- base_url(opts),
         {:ok, body} <- encode_decision_request(request),
         {:ok, response} <- send_decision(base_url, body, opts),
         :ok <- not_cancelled(opts) do
      decision_result(response, request)
    end
  end

  defp validate_decision_model(model) do
    if model in decision_models(), do: :ok, else: {:error, {:unsupported_model, model}}
  end

  defp encode_decision_request(request) do
    {:ok, request |> Request.to_json_map() |> JSON.encode!()}
  rescue
    exception -> {:error, {:invalid_request_body, Exception.message(exception)}}
  end

  defp send_decision(base_url, body, opts) do
    [
      method: :post,
      url: Ollama.endpoint_url(base_url, "/systemone"),
      headers: [
        {"content-type", "application/json"},
        {"accept", "application/json"},
        {"user-agent", Ollama.user_agent("tackle-ollama")}
      ],
      body: body,
      decode_body: false,
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_decision_timeout)
    ]
    |> HTTP.request(opts)
  end

  defp decision_result(%{status: status, body: body}, request) when status in 200..299 do
    with {:ok, decoded} <- decode_success_body(body),
         {:ok, answers} <- parse_answers(decoded["answers"], request.questions) do
      model = if is_binary(decoded["model"]), do: decoded["model"], else: request.model
      usage = if is_map(decoded["usage"]), do: decoded["usage"], else: nil
      {:ok, %Result{model: model, answers: answers, usage: usage}}
    end
  end

  defp decision_result(%{status: status, body: body}, _request),
    do: {:error, {:http_error, status, error_body(body)}}

  defp decode_success_body(%{} = body), do: {:ok, body}

  defp decode_success_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _invalid -> {:error, {:invalid_decision_response, :invalid_json}}
    end
  end

  defp decode_success_body(_body), do: {:error, {:invalid_decision_response, :invalid_json}}

  defp error_body(body) when is_binary(body) do
    bounded =
      if byte_size(body) <= @max_error_body_bytes,
        do: body,
        else: binary_part(body, 0, @max_error_body_bytes)

    case JSON.decode(bounded) do
      {:ok, %{} = decoded} -> decoded
      _other -> HTTP.error_body(bounded)
    end
  end

  defp error_body(body), do: HTTP.error_body(body)

  # Every requested question must be answered with its own type; answers to
  # questions that were not asked are ignored.
  defp parse_answers(%{} = answers, questions) do
    Enum.reduce_while(questions, {:ok, %{}}, fn question, {:ok, parsed} ->
      case parse_answer(Map.get(answers, question.name), question) do
        {:ok, answer} -> {:cont, {:ok, Map.put(parsed, question.name, answer)}}
        {:error, detail} -> {:halt, {:error, {:invalid_decision_response, detail}}}
      end
    end)
  end

  defp parse_answers(_answers, _questions),
    do: {:error, {:invalid_decision_response, :missing_answers}}

  defp parse_answer(nil, %Question{name: name}), do: {:error, {:missing_answer, name}}

  defp parse_answer(
         %{"type" => "choice", "choice" => choice} = answer,
         %Question{type: :choice} = q
       )
       when is_binary(choice) do
    if Map.has_key?(q.criteria, choice) do
      {:ok,
       %Answer{
         type: :choice,
         choice: choice,
         probabilities: probabilities(answer["probabilities"], & &1),
         confidence: number_or_nil(answer["confidence"])
       }}
    else
      {:error, {:unknown_choice, q.name, choice}}
    end
  end

  defp parse_answer(%{"type" => "noul", "noul" => noul} = answer, %Question{type: :noul})
       when is_number(noul) and noul >= 0 and noul <= 1 do
    {:ok, %Answer{type: :noul, noul: noul / 1, confidence: number_or_nil(answer["confidence"])}}
  end

  defp parse_answer(%{"type" => "score"} = answer, %Question{type: :score} = q) do
    probabilities = probabilities(answer["probabilities"], &level_key/1)

    case answer["score"] || expected_level(probabilities) do
      score when is_number(score) ->
        {:ok,
         %Answer{
           type: :score,
           score: score,
           probabilities: probabilities,
           confidence: number_or_nil(answer["confidence"])
         }}

      _missing ->
        {:error, {:invalid_answer, q.name}}
    end
  end

  defp parse_answer(_answer, %Question{name: name}), do: {:error, {:invalid_answer, name}}

  defp probabilities(%{} = probabilities, key_fun) do
    for {key, value} <- probabilities, is_number(value), into: %{}, do: {key_fun.(key), value}
  end

  defp probabilities(_probabilities, _key_fun), do: %{}

  # Score levels are zero-based; level keys sent as "0", "1", ... become integers.
  defp level_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {level, ""} when level >= 0 -> level
      _other -> key
    end
  end

  defp level_key(key), do: key

  # Ollama defines a score as the probability-weighted average of the levels.
  defp expected_level(probabilities) do
    levels = Enum.filter(probabilities, fn {level, _p} -> is_integer(level) end)

    if levels == [],
      do: nil,
      else: Enum.reduce(levels, 0.0, fn {level, p}, sum -> sum + level * p end)
  end

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil

  defp base_url(opts) do
    with {:ok, from_options} <- provider_base_url(opts) do
      case Keyword.get(opts, :base_url) || from_options || configured_base_url() do
        url when is_binary(url) and url != "" -> {:ok, url}
        nil -> {:ok, @default_base_url}
        invalid -> {:error, {:invalid_base_url, invalid}}
      end
    end
  end

  defp provider_base_url(opts) do
    case Keyword.get(opts, :provider_options) do
      %{@adapter_id => %{} = settings} ->
        case Map.get(settings, "base_url") do
          nil -> {:ok, nil}
          url when is_binary(url) and url != "" -> {:ok, url}
          _invalid -> {:error, {:invalid_provider_options, settings}}
        end

      %{@adapter_id => settings} ->
        {:error, {:invalid_provider_options, settings}}

      _none ->
        {:ok, nil}
    end
  end

  defp configured_base_url, do: Keyword.get(config(), :base_url)

  defp not_cancelled(opts) do
    if Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal)),
      do: {:error, :cancelled},
      else: :ok
  end

  defp configured_ids(key), do: configured_entries(key) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  # Malformed entries are kept as-is so selection reports them instead of the
  # adapter silently dropping them.
  defp configured_entries(key) do
    config()
    |> Keyword.get(key, [])
    |> List.wrap()
    |> Enum.map(fn
      {model, info} -> {model, info}
      model -> {model, nil}
    end)
  end

  defp config do
    case Application.get_env(:tackle_ollama, __MODULE__, []) do
      config when is_list(config) -> config
      _invalid -> []
    end
  end
end
