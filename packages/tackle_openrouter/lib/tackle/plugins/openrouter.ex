defmodule Tackle.Plugins.OpenRouter do
  @moduledoc """
  OpenRouter Chat Completions adapter for `Tackle.Lib.LLM`.

  The adapter sends provider-neutral Tackle messages and tools to OpenRouter's
  OpenAI-compatible streaming endpoint. OpenRouter model ids keep their vendor
  prefix, so a canonical model reference contains two slashes:

      {:ok, llm} = Tackle.Lib.LLM.select([Tackle.Plugins.OpenRouter], "openrouter/anthropic/claude-sonnet-5.5")

  `models/0` returns a curated catalog with limits and price cards. Hosts can
  make further OpenRouter models selectable through application configuration:

      config :tackle_openrouter,
        models: [
          "meta-llama/llama-5-maverick",
          {"mistralai/devstral-3", %{context_window: 262_144, max_output_tokens: 65_536}}
        ]

  API keys may be supplied explicitly, through a host-owned
  `Tackle.Lib.CredentialStore`, or through an environment variable (see
  "Providers"). `login/1` prompts for a key through a
  `Tackle.Lib.Interaction` handle and `usage/1` reports the key's credit usage
  and limit.

  ## Provider routing

  OpenRouter load-balances across the providers serving a model unless the
  request carries a `provider` routing object. A model can be pinned to one
  provider endpoint through configuration:

      config :tackle_openrouter,
        provider_routing: %{
          "z-ai/glm-5.3" => [only: ["mistral/zdr"], allow_fallbacks: false, zdr: true]
        }

  The provider's `"provider_routing"` setting (a map of model id to route)
  replaces the configured route for the same model, and the per-request
  `:provider_preferences` option is merged over the model's route, field by
  field.

  ## Providers

  Several providers can share this adapter, each with its own API key and
  settings. The host passes the provider as `opts[:provider_id]` and
  `opts[:provider_settings]`; without them the adapter acts as the default
  `"openrouter"` provider. The provider id is the credential namespace, the
  reported `:provider`, and the origin stamped on replayable `:provider_state`.

  Honoured settings: `"provider_routing"`, `"base_url"` (the API base URL;
  an explicit `:base_url` option wins over it), and `"api_key_env"` (the
  environment variable consulted for an API key when none is stored). Only the
  default `"openrouter"` provider falls back to `OPENROUTER_API_KEY` without
  `"api_key_env"`, so another provider never picks up its key by accident.
  Without a key, requests fail with
  `{:error, {:missing_openrouter_api_key, provider_id}}`.
  """

  @behaviour Tackle.Lib.LLM

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.CredentialStore
  alias Tackle.Lib.Interaction
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.Tool.Schema.JsonSchema
  alias Tackle.Plugins.OpenRouter.HTTP
  alias Tackle.Plugins.OpenRouter.SSE

  @adapter_id "openrouter"
  @default_base_url "https://openrouter.ai/api/v1"
  @max_session_id_bytes 256

  # `{model, context_window, max_output_tokens, {input, output, cache_read, cache_write}}`.
  # Prices are USD per million tokens from OpenRouter's model listing. Providers
  # without a separate cache-write price list 0. The usage OpenRouter reports
  # carries the billed cost, which takes precedence over these estimates.
  @catalog [
    {"anthropic/claude-opus-5.5", 1_000_000, 128_000, {4.0, 20.0, 0.2, 5.0}},
    {"anthropic/claude-sonnet-5.5", 1_000_000, 128_000, {2.0, 10.0, 0.2, 2.5}},
    {"anthropic/claude-fable-5.1", 1_000_000, 128_000, {10.0, 50.0, 0.25, 12.5}},
    {"openai/gpt-6.1-sol", 1_050_000, 128_000, {2.0, 10.0, 0.1, 2.5}},
    {"openai/gpt-6-astra", 1_050_000, 128_000, {10.0, 50.0, 1.0, 12.5}},
    {"openai/gpt-6-luna", 1_050_000, 128_000, {0.1, 0.5, 0.01, 0.125}},
    {"google/gemini-3.8-flash", 1_048_576, 65_536, {0.75, 3.75, 0.075, 0.0416667}},
    {"x-ai/grok-4.7", 500_000, 450_000, {2.0, 6.0, 0.5, 0}},
    {"deepseek/deepseek-v4.1-flash", 1_048_576, 943_718, {0.3, 1.2, 0.006, 0}},
    {"moonshotai/kimi-k3", 1_048_576, 943_718, {1.39, 14.0, 0.46, 0}},
    {"z-ai/glm-5.3", 1_048_576, 943_718, {0.06, 7.0, 0.055, 0}},
    {"qwen/qwen3.8-max-0902", 1_000_000, 131_072, {2.0, 6.0, 0.25, 2.5}}
  ]

  @catalog_models Enum.map(@catalog, &elem(&1, 0))
  @catalog_info Map.new(@catalog, fn {model, context, output, prices} ->
                  {model, {context, output, prices}}
                end)

  @reasoning_efforts ~w(minimal low medium high xhigh max)

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def models, do: Enum.uniq(@catalog_models ++ Enum.map(configured_models(), &elem(&1, 0)))

  @impl true
  def model_info(model) do
    case Map.get(@catalog_info, model) do
      {context_window, max_output_tokens, {input, output, cache_read, cache_write}} ->
        %{
          context_window: context_window,
          max_output_tokens: max_output_tokens,
          pricing: %{
            input: input,
            output: output,
            cache_read: cache_read,
            cache_write: cache_write,
            currency: "USD",
            unit_tokens: 1_000_000
          }
        }

      nil ->
        configured_models() |> List.keyfind(model, 0, {model, nil}) |> elem(1)
    end
  end

  # Entries are model ids or `{model_id, model_info}` tuples. Malformed entries
  # are kept as-is so `Tackle.Lib.LLM.select/2` reports them instead of the
  # adapter silently dropping them.
  defp configured_models do
    :tackle_openrouter
    |> Application.get_env(:models, [])
    |> List.wrap()
    |> Enum.map(fn
      {model, info} -> {model, info}
      model -> {model, nil}
    end)
  end

  @impl true
  def login(opts) do
    with {:ok, interaction} <- interaction(opts),
         {:ok, api_key} <-
           Interaction.prompt(interaction, label: "OpenRouter API key", secret: true),
         {:ok, api_key} <- normalize_api_key(api_key) do
      {:ok, %{"api_key" => api_key}}
    end
  end

  @impl true
  def usage(opts) do
    with :ok <- not_cancelled(opts),
         {:ok, opts} <- put_base_url(opts),
         {:ok, api_key} <- api_key(opts) do
      key_request(api_key, opts)
    end
  end

  defp interaction(opts) do
    case Keyword.fetch(opts, :interaction) do
      {:ok, {module, _reference} = handle} when is_atom(module) and not is_nil(module) ->
        {:ok, handle}

      _other ->
        {:error, :interaction_required}
    end
  end

  defp normalize_api_key(api_key) when is_binary(api_key) do
    case String.trim(api_key) do
      "" -> {:error, :empty_api_key}
      trimmed -> if header_safe?(trimmed), do: {:ok, trimmed}, else: {:error, :invalid_api_key}
    end
  end

  defp normalize_api_key(_api_key), do: {:error, :invalid_api_key}

  # A key with control characters or spaces would make the HTTP client raise
  # with the full `authorization` header in its error, so it is rejected before
  # any request is built.
  defp header_safe?(value), do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E))

  defp key_request(api_key, opts) do
    request_options = [
      method: :get,
      url: endpoint_url(opts, "/key"),
      headers: headers(api_key, opts, "application/json"),
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
    ]

    with {:ok, response} <- HTTP.request(request_options, opts) do
      key_response(response)
    end
  end

  defp key_response(%{status: status, body: body}) when status in 200..299 do
    case HTTP.decode_json(body) do
      {:ok, %{"data" => %{} = data}} -> {:ok, data}
      {:ok, decoded} -> {:ok, decoded}
      error -> error
    end
  end

  defp key_response(%{status: status, body: body}) do
    {:error, {:http_error, status, HTTP.error_body(body)}}
  end

  @impl true
  def generate(schema, opts) do
    perform(schema, opts, fn _event -> :ok end)
  end

  @impl true
  def stream(schema, opts, event_callback) when is_function(event_callback, 1) do
    perform(schema, opts, event_callback)
  end

  defp perform(schema, opts, event_callback) do
    with :ok <- validate_model(opts),
         :ok <- not_cancelled(opts),
         {:ok, opts} <- put_base_url(opts),
         {:ok, api_key} <- api_key(opts),
         {:ok, body} <- build_request_body(schema, opts),
         {:ok, response} <- send_request(body, opts, api_key, event_callback),
         {:ok, result} <-
           response_result(response, Keyword.fetch!(opts, :model), schema, event_callback) do
      {:ok, stamp_provider(result, provider_id(opts))}
    end
  end

  # The parser stamps replayable state with the adapter type; the provider id
  # replaces it so state is only ever replayed to the provider that produced it.
  defp stamp_provider(result, provider_id) do
    result
    |> Map.put(:provider, provider_id)
    |> Map.update(:provider_state, nil, fn
      %{} = state -> Map.put(state, "provider", provider_id)
      state -> state
    end)
  end

  defp send_request(body, opts, api_key, event_callback) do
    signal = Keyword.get(opts, :cancellation_signal)
    initial_parser = SSE.new()

    # Req streams body chunks of error responses too; those are collected as a
    # bounded raw body instead of being fed to the SSE parser.
    stream = fn chunk, response, acc ->
      cond do
        error_status?(response) ->
          {:cont, append_error_body(acc, chunk)}

        Cancellation.cancelled?(signal) ->
          {:halt, SSE.cancel(parser_state(acc, initial_parser))}

        true ->
          {:cont, SSE.push(parser_state(acc, initial_parser), chunk, event_callback)}
      end
    end

    with {:ok, encoded} <- encode_body(body) do
      request_options = [
        method: :post,
        url: endpoint_url(opts, "/chat/completions"),
        headers: headers(api_key, opts, "text/event-stream"),
        body: encoded,
        raw: true,
        retry: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 120_000)
      ]

      HTTP.stream(request_options, initial_parser, stream, opts)
    end
  end

  defp encode_body(body) do
    {:ok, JSON.encode!(body)}
  rescue
    exception -> {:error, {:invalid_request_body, Exception.message(exception)}}
  end

  @max_error_body_bytes 16_384

  defp error_status?(%{status: status}) when is_integer(status), do: status not in 200..299
  defp error_status?(_response), do: false

  defp append_error_body({:error_body, body}, chunk),
    do: {:error_body, bounded(body <> chunk)}

  defp append_error_body(_acc, chunk), do: {:error_body, bounded(chunk)}

  defp bounded(body) when byte_size(body) <= @max_error_body_bytes, do: body
  defp bounded(body), do: binary_part(body, 0, @max_error_body_bytes)

  defp response_result(%{status: status, body: body}, model, schema, event_callback)
       when status in 200..299 do
    parser =
      case body do
        %SSE{} = parser -> parser
        body when is_binary(body) -> SSE.push(SSE.new(), body, event_callback)
        _body -> SSE.new()
      end
      |> SSE.finish(event_callback)

    case SSE.result(parser, model, schema) do
      {:error, {:provider_error, error}} = failure ->
        # OpenRouter may commit a 200 before the upstream rejects the prompt;
        # an overflow reported before any output is still an overflow.
        if SSE.output?(parser) or not overflow_message?(error),
          do: failure,
          else: {:error, :context_window_exceeded}

      result ->
        result
    end
  end

  defp response_result(%{status: status, body: body}, _model, _schema, _event_callback) do
    error_body = body |> raw_error_body() |> HTTP.error_body()

    case classify_overflow(status, error_body) do
      :context_window_exceeded -> {:error, :context_window_exceeded}
      :other -> {:error, {:http_error, status, error_body}}
    end
  end

  defp raw_error_body({:error_body, body}), do: decode_error_body(body)
  defp raw_error_body(body) when is_binary(body), do: decode_error_body(body)
  defp raw_error_body(%SSE{}), do: ""
  defp raw_error_body(body), do: body

  defp decode_error_body(body) do
    case JSON.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _other -> body
    end
  end

  # Only wire errors that unambiguously name a context/token limit are treated as
  # overflow, so the harness can run exactly one compact-and-retry. Generic
  # 4xx/5xx, rate limits, insufficient credits, and transport failures stay
  # unclassified. OpenRouter relays upstream wording, so markers cover the
  # common backends it routes to. Only the error message and the relayed
  # upstream text are searched, never echoed request content.
  @overflow_markers [
    "context_length_exceeded",
    "context_window_exceeded",
    "maximum context length",
    "maximum allowed input length",
    "exceeds the context window",
    "exceeds the maximum number of tokens",
    "prompt is too long",
    "input is too long",
    "too many tokens",
    "reduce the length of the messages"
  ]

  defp classify_overflow(status, error_body) when status in [400, 413, 422] do
    if overflow_message?(error_body), do: :context_window_exceeded, else: :other
  end

  defp classify_overflow(_status, _error_body), do: :other

  defp overflow_message?(error) do
    error
    |> error_texts()
    |> Enum.any?(fn text ->
      downcased = String.downcase(text)
      Enum.any?(@overflow_markers, &String.contains?(downcased, &1))
    end)
  end

  defp error_texts(%{"error" => %{} = error}), do: error_texts(error)

  defp error_texts(%{} = error) do
    [error["code"], error["message"], get_in(error, ["metadata", "raw"])]
    |> Enum.filter(&is_binary/1)
  end

  defp error_texts(body) when is_binary(body), do: [body]
  defp error_texts(_body), do: []

  defp build_request_body(schema, opts) do
    model = Keyword.fetch!(opts, :model)

    with {:ok, tools} <- convert_tools(Keyword.get(opts, :tools, [])),
         {:ok, messages} <-
           convert_messages(Keyword.get(opts, :messages, []), provider_id(opts), model),
         {:ok, response_format, schema_instruction} <- response_options(schema),
         {:ok, reasoning} <- reasoning_options(opts),
         {:ok, provider} <- provider_preferences(opts, model),
         {:ok, cache_control} <- cache_control(opts, model) do
      messages =
        prepend_system_and_schema(messages, Keyword.get(opts, :system), schema_instruction)

      body =
        %{
          "model" => model,
          "messages" => messages,
          "stream" => true,
          "stream_options" => %{"include_usage" => true}
        }
        |> maybe_put("tools", non_empty(tools))
        |> maybe_put("tool_choice", tool_choice(opts, tools))
        |> maybe_put("response_format", response_format)
        |> maybe_put("reasoning", reasoning)
        |> maybe_put("cache_control", cache_control)
        |> maybe_put("session_id", session_id(opts))
        |> maybe_put("provider", provider)
        |> maybe_put("temperature", Keyword.get(opts, :temperature))
        |> maybe_put("top_p", Keyword.get(opts, :top_p))
        |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens))
        |> maybe_put("stop", Keyword.get(opts, :stop))
        |> maybe_put("user", Keyword.get(opts, :user_id))

      {:ok, body}
    end
  rescue
    KeyError -> {:error, :model_required}
  end

  defp convert_messages(messages, provider_id, model) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, converted} ->
      case convert_message(message, provider_id, model) do
        {:ok, nil} -> {:cont, {:ok, converted}}
        {:ok, item} -> {:cont, {:ok, [item | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} ->
        converted = Enum.reverse(converted)

        case validate_tool_history(converted) do
          :ok -> {:ok, converted}
          {:error, reason} -> {:error, {:invalid_tool_history, reason}}
        end

      error ->
        error
    end
  end

  defp convert_messages(_messages, _provider_id, _model), do: {:error, :invalid_messages}

  defp convert_message(message, _provider_id, _model) when not is_map(message),
    do: {:error, :invalid_message}

  defp convert_message(message, provider_id, model) do
    case normalize_role(field(message, :role)) do
      :user -> text_message("user", field(message, :content))
      :assistant -> assistant_message(message, provider_id, model)
      :tool -> tool_message(message)
      role -> {:error, {:unsupported_message_role, role}}
    end
  end

  defp text_message(role, content) when is_binary(content),
    do: {:ok, %{"role" => role, "content" => content}}

  defp text_message(_role, _content), do: {:error, :invalid_message_content}

  # Tool-call-only turns send `null` content: some upstreams (Anthropic among
  # them) reject an empty text block.
  defp assistant_message(message, provider_id, model) do
    content = field(message, :content)
    tool_calls = field(message, :tool_calls) |> List.wrap()

    with :ok <- valid_optional_content(content),
         {:ok, tool_calls} <- convert_tool_calls(tool_calls) do
      if empty_content?(content) and tool_calls == [] do
        {:ok, nil}
      else
        assistant =
          %{
            "role" => "assistant",
            "content" => if(empty_content?(content), do: nil, else: content)
          }
          |> maybe_put("tool_calls", non_empty(tool_calls))
          |> put_replayed_reasoning(field(message, :provider_state), provider_id, model)

        {:ok, assistant}
      end
    end
  end

  # Reasoning is replayed only when the opaque state came from this provider and
  # the same model. Structured `reasoning_details` carry signatures and
  # encrypted blocks some models require around tool calls, so they are
  # preferred over the plain-text `reasoning` field.
  defp put_replayed_reasoning(assistant, provider_state, provider_id, model)
       when is_map(provider_state) do
    if field(provider_state, :provider) == provider_id and
         field(provider_state, :model) == model do
      case {field(provider_state, :reasoning_details), field(provider_state, :reasoning)} do
        {[_ | _] = details, _reasoning} ->
          Map.put(assistant, "reasoning_details", details)

        {_details, reasoning} when is_binary(reasoning) ->
          Map.put(assistant, "reasoning", reasoning)

        _none ->
          assistant
      end
    else
      assistant
    end
  end

  defp put_replayed_reasoning(assistant, _provider_state, _provider_id, _model), do: assistant

  defp tool_message(message) do
    call_id = field(message, :tool_call_id)
    content = field(message, :content)

    if is_binary(call_id) and call_id != "" do
      case tool_text_content(content) do
        {:ok, text} -> {:ok, %{"role" => "tool", "tool_call_id" => call_id, "content" => text}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_tool_message}
    end
  end

  defp tool_text_content(content) when is_binary(content), do: {:ok, content}

  # Chat Completions tool results are text-only across OpenRouter's upstreams,
  # so structured parts (currently images) are replaced by an explicit note
  # instead of being dropped silently or failing the whole request.
  defp tool_text_content(content) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, texts} ->
      case tool_text_part(part) do
        {:ok, text} -> {:cont, {:ok, [text | texts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp tool_text_content(_content), do: {:error, :invalid_tool_message}

  defp tool_text_part(part) when is_map(part) do
    case field(part, :type) do
      "text" ->
        case field(part, :text) do
          text when is_binary(text) -> {:ok, text}
          _text -> {:error, :invalid_message_content}
        end

      "image" ->
        {:ok, "[image content omitted: this adapter sends text-only tool results]"}

      type ->
        {:error, {:unsupported_tool_content, type}}
    end
  end

  defp tool_text_part(_part), do: {:error, :invalid_tool_message}

  defp convert_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, converted} ->
      case convert_tool_call(call) do
        {:ok, item} -> {:cont, {:ok, [item | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp convert_tool_call(call) when is_map(call) do
    function = field(call, :function) || %{}
    id = field(call, :id)
    name = field(call, :name) || field(function, :name)
    arguments = field(call, :arguments) || field(function, :arguments) || %{}

    with true <- is_binary(id) and id != "",
         true <- is_binary(name) and name != "",
         {:ok, arguments} <- encode_arguments(arguments) do
      {:ok,
       %{
         "id" => id,
         "type" => "function",
         "function" => %{"name" => name, "arguments" => arguments}
       }}
    else
      _invalid -> {:error, :invalid_tool_call}
    end
  end

  defp convert_tool_call(_call), do: {:error, :invalid_tool_call}

  defp validate_tool_history(messages) do
    messages
    |> Enum.reduce_while({:ok, MapSet.new()}, &validate_tool_message/2)
    |> case do
      {:ok, pending} ->
        if MapSet.size(pending) == 0, do: :ok, else: {:error, :missing_tool_results}

      error ->
        error
    end
  end

  defp validate_tool_message(
         %{"role" => "assistant", "tool_calls" => [_ | _]} = message,
         {:ok, pending}
       ) do
    if MapSet.size(pending) == 0 do
      start_tool_calls(message["tool_calls"])
    else
      {:halt, {:error, :missing_tool_results}}
    end
  end

  defp validate_tool_message(%{"role" => "tool"} = message, {:ok, pending}) do
    tool_call_id = message["tool_call_id"]

    if MapSet.member?(pending, tool_call_id) do
      {:cont, {:ok, MapSet.delete(pending, tool_call_id)}}
    else
      {:halt, {:error, {:unexpected_tool_result, tool_call_id}}}
    end
  end

  defp validate_tool_message(_message, {:ok, pending}) do
    if MapSet.size(pending) > 0 do
      {:halt, {:error, :missing_tool_results}}
    else
      {:cont, {:ok, pending}}
    end
  end

  defp start_tool_calls(tool_calls) do
    ids = Enum.map(tool_calls, & &1["id"])
    next_pending = MapSet.new(ids)

    if length(ids) == MapSet.size(next_pending),
      do: {:cont, {:ok, next_pending}},
      else: {:halt, {:error, :duplicate_tool_call_id}}
  end

  defp convert_tools(tools) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, converted} ->
      case convert_tool(tool) do
        {:ok, item} -> {:cont, {:ok, [item | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp convert_tools(_tools), do: {:error, :invalid_tools}

  defp convert_tool(tool) when is_map(tool) do
    name = field(tool, :name)
    description = field(tool, :description)
    input_schema = field(tool, :input_schema) || []

    if is_binary(name) and name != "" and is_binary(description) and is_list(input_schema) do
      {:ok,
       %{
         "type" => "function",
         "function" => %{
           "name" => name,
           "description" => description,
           "parameters" => tool_json_schema(input_schema)
         }
       }}
    else
      {:error, {:invalid_tool, name}}
    end
  end

  defp convert_tool(_tool), do: {:error, :invalid_tool}

  defp tool_json_schema(input_schema) do
    if Keyword.keyword?(input_schema) do
      JsonSchema.to_json_schema(input_schema)
    else
      properties =
        Map.new(input_schema, fn definition ->
          name = field(definition, :name)

          schema =
            definition
            |> field(:type)
            |> normalized_type_schema()
            |> maybe_nullable(field(definition, :nullable))
            |> maybe_put("description", field(definition, :description))
            |> maybe_put("default", field(definition, :default))
            |> maybe_put("enum", field(definition, :enum))

          {name, schema}
        end)

      required =
        input_schema
        |> Enum.filter(&(field(&1, :required) == true))
        |> Enum.map(&field(&1, :name))

      %{"type" => "object", "properties" => properties, "required" => required}
    end
  end

  defp maybe_nullable(schema, true), do: Map.update!(schema, "type", &[&1, "null"])
  defp maybe_nullable(schema, _nullable), do: schema

  defp normalized_type_schema(type) when type in [:string, "string"], do: %{"type" => "string"}
  defp normalized_type_schema(type) when type in [:integer, "integer"], do: %{"type" => "integer"}

  defp normalized_type_schema(type) when type in [:float, :number, "number"],
    do: %{"type" => "number"}

  defp normalized_type_schema(type) when type in [:boolean, "boolean"], do: %{"type" => "boolean"}

  defp normalized_type_schema(type) when type in [:map, "map", "object"],
    do: %{"type" => "object"}

  defp normalized_type_schema({kind, inner}) when kind in [:list, :array],
    do: %{"type" => "array", "items" => normalized_type_schema(inner)}

  defp normalized_type_schema("array<" <> inner) do
    inner = String.slice(inner, 0, max(0, byte_size(inner) - 1))
    %{"type" => "array", "items" => normalized_type_schema(inner)}
  end

  defp normalized_type_schema(_type), do: %{"type" => "string"}

  # Structured responses request JSON-schema output, which OpenRouter forwards
  # to upstreams that support it. The schema is also stated in the system
  # instruction because upstreams without schema support drop the parameter.
  defp response_options(nil), do: {:ok, nil, nil}

  defp response_options(schema) when is_list(schema),
    do: json_schema_response(JsonSchema.to_json_schema(schema))

  defp response_options(%{} = schema), do: json_schema_response(stringify_map_keys(schema))
  defp response_options(_schema), do: {:error, :invalid_response_schema}

  defp json_schema_response(json_schema) do
    response_format = %{
      "type" => "json_schema",
      "json_schema" => %{"name" => "response", "strict" => false, "schema" => json_schema}
    }

    instruction =
      "Return only a JSON object matching this JSON Schema: #{JSON.encode!(json_schema)}"

    {:ok, response_format, instruction}
  end

  defp prepend_system_and_schema(messages, system, schema_instruction) do
    content =
      [system, schema_instruction]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n\n")

    if content == "", do: messages, else: [%{"role" => "system", "content" => content} | messages]
  end

  defp tool_choice(opts, tools) do
    case Keyword.fetch(opts, :tool_choice) do
      {:ok, choice} -> choice
      :error when tools != [] -> "auto"
      :error -> nil
    end
  end

  # OpenRouter normalizes one `reasoning.effort` vocabulary across upstreams and
  # maps unsupported levels to the nearest one the model accepts.
  defp reasoning_options(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      nil ->
        {:ok, nil}

      effort when effort in [:off, :none, "off", "none"] ->
        {:ok, %{"effort" => "none"}}

      effort when is_atom(effort) or is_binary(effort) ->
        effort = to_string(effort)

        if effort in @reasoning_efforts,
          do: {:ok, %{"effort" => effort}},
          else: {:error, {:invalid_reasoning_effort, effort}}

      effort ->
        {:error, {:invalid_reasoning_effort, effort}}
    end
  end

  # Anthropic models cache only behind explicit breakpoints. A top-level
  # `cache_control` lets OpenRouter place and advance the breakpoint itself, so
  # the message projection stays byte-identical across turns. Other upstreams
  # cache implicitly; OpenRouter's sticky routing keeps them warm.
  defp cache_control(opts, model) do
    case Keyword.get(opts, :cache_control) do
      nil ->
        if String.starts_with?(model, "anthropic/"),
          do: {:ok, %{"type" => "ephemeral"}},
          else: {:ok, nil}

      false ->
        {:ok, nil}

      %{} = cache_control ->
        {:ok, stringify_map_keys(cache_control)}

      other ->
        {:error, {:invalid_cache_control, other}}
    end
  end

  # Routing comes from three layers, later ones winning:
  #
  #   1. `config :tackle_openrouter, :provider_routing` (host/distribution);
  #   2. the provider's `"provider_routing"` setting (for the Tackle CLI, from
  #      `$TACKLE_HOME/config.json`), which replaces a model's route entirely;
  #   3. the request's `:provider_preferences`, merged over the route by field.
  defp provider_preferences(opts, model) do
    configured = Application.get_env(:tackle_openrouter, :provider_routing, %{})

    with {:ok, host_routes} <- routing_table(configured),
         {:ok, user_routes} <-
           routing_table(Map.get(Provider.settings(opts), "provider_routing", %{})),
         route = Map.get(Map.merge(host_routes, user_routes), model),
         {:ok, per_model} <- routing_map(route, {:provider_routing, model}),
         {:ok, per_request} <-
           routing_map(Keyword.get(opts, :provider_preferences), :provider_preferences) do
      case Map.merge(per_model || %{}, per_request || %{}) do
        empty when map_size(empty) == 0 -> {:ok, nil}
        preferences -> {:ok, preferences}
      end
    end
  end

  defp routing_table(%{} = routes), do: {:ok, routes}

  defp routing_table(routes) when is_list(routes) do
    if Enum.all?(routes, &match?({model, _} when is_binary(model), &1)),
      do: {:ok, Map.new(routes)},
      else: {:error, {:invalid_provider_routing, routes}}
  end

  defp routing_table(routes), do: {:error, {:invalid_provider_routing, routes}}

  defp routing_map(nil, _source), do: {:ok, nil}
  defp routing_map(%{} = preferences, _source), do: {:ok, stringify_map_keys(preferences)}

  defp routing_map(preferences, source) when is_list(preferences) do
    if Keyword.keyword?(preferences),
      do: {:ok, preferences |> Map.new() |> stringify_map_keys()},
      else: routing_error(source, preferences)
  end

  defp routing_map(preferences, source), do: routing_error(source, preferences)

  defp routing_error(:provider_preferences, value),
    do: {:error, {:invalid_provider_preferences, value}}

  defp routing_error({:provider_routing, model}, value),
    do: {:error, {:invalid_provider_routing, model, value}}

  # The stable session id is OpenRouter's sticky-routing key, which keeps
  # follow-up turns on the provider that holds the prompt cache. Ids beyond
  # OpenRouter's limit are hashed so they stay stable instead of being dropped.
  defp session_id(opts) do
    case Keyword.get(opts, :session_id) do
      id when is_binary(id) and id != "" and byte_size(id) <= @max_session_id_bytes ->
        id

      id when is_binary(id) and id != "" ->
        :crypto.hash(:sha256, id) |> Base.encode16(case: :lower)

      _other ->
        nil
    end
  end

  # Keys from every source are trimmed and must be header-safe; see
  # `header_safe?/1`. An empty explicit key falls through to the next source.
  defp api_key(opts) do
    case Keyword.get(opts, :api_key) do
      api_key when is_binary(api_key) ->
        if String.trim(api_key) == "",
          do: stored_or_environment_api_key(opts),
          else: normalize_api_key(api_key)

      _missing ->
        stored_or_environment_api_key(opts)
    end
  end

  defp stored_or_environment_api_key(opts) do
    case Keyword.fetch(opts, :credential_store) do
      {:ok, {module, _reference} = handle} when is_atom(module) ->
        case CredentialStore.fetch(handle, provider_id(opts)) do
          {:ok, credentials} when is_map(credentials) ->
            credential_api_key(credentials) || environment_api_key(opts)

          :error ->
            environment_api_key(opts)

          {:error, reason} ->
            {:error, {:credential_store_failed, reason}}

          _other ->
            {:error, :invalid_openrouter_credentials}
        end

      {:ok, _invalid} ->
        {:error, :invalid_credential_store}

      :error ->
        environment_api_key(opts)
    end
  end

  defp credential_api_key(credentials) do
    case field(credentials, :api_key) || field(credentials, :key) do
      api_key when is_binary(api_key) ->
        if String.trim(api_key) == "", do: nil, else: normalize_api_key(api_key)

      _missing ->
        nil
    end
  end

  defp environment_api_key(opts) do
    with {:ok, name} <- api_key_env(opts) do
      case name && System.get_env(name) do
        api_key when is_binary(api_key) ->
          if String.trim(api_key) == "",
            do: {:error, {:missing_openrouter_api_key, provider_id(opts)}},
            else: normalize_api_key(api_key)

        nil ->
          {:error, {:missing_openrouter_api_key, provider_id(opts)}}
      end
    end
  end

  # The environment variable holding the provider's API key: its
  # `"api_key_env"` setting, else `OPENROUTER_API_KEY` for the default provider
  # only, so another provider never picks up that key by accident.
  defp api_key_env(opts) do
    case Map.fetch(Provider.settings(opts), "api_key_env") do
      {:ok, name} when is_binary(name) and name != "" ->
        {:ok, name}

      {:ok, other} ->
        {:error, {:invalid_provider_setting, provider_id(opts), "api_key_env", other}}

      :error ->
        {:ok, if(provider_id(opts) == @adapter_id, do: "OPENROUTER_API_KEY")}
    end
  end

  # App attribution is opt-in: hosts pass `:app_url` and `:app_title` to
  # appear in OpenRouter's rankings; nothing identifying is sent by default.
  defp headers(api_key, opts, accept) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", accept},
      {"user-agent", user_agent()}
    ]
    |> maybe_header("http-referer", Keyword.get(opts, :app_url))
    |> maybe_header("x-title", Keyword.get(opts, :app_title))
  end

  defp maybe_header(headers, name, value) when is_binary(value) and value != "",
    do: headers ++ [{name, value}]

  defp maybe_header(headers, _name, _value), do: headers

  defp provider_id(opts), do: Provider.id(opts, @adapter_id)

  # An explicit `:base_url` option wins over the provider's `"base_url"` setting.
  defp put_base_url(opts) do
    case Map.fetch(Provider.settings(opts), "base_url") do
      {:ok, url} when is_binary(url) and url != "" ->
        {:ok, Keyword.put_new(opts, :base_url, url)}

      {:ok, other} ->
        {:error, {:invalid_provider_setting, provider_id(opts), "base_url", other}}

      :error ->
        {:ok, opts}
    end
  end

  defp endpoint_url(opts, path) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) |> String.trim_trailing("/")

    if String.ends_with?(base_url, path), do: base_url, else: base_url <> path
  end

  defp validate_model(opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} when is_binary(model) ->
        if model in models(), do: :ok, else: {:error, {:unsupported_model, model}}

      {:ok, model} ->
        {:error, {:unsupported_model, model}}

      :error ->
        {:error, :model_required}
    end
  end

  defp not_cancelled(opts) do
    if Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal)),
      do: {:error, :cancelled},
      else: :ok
  end

  defp parser_state(%SSE{} = parser, _initial), do: parser
  defp parser_state(_acc, initial), do: initial
  defp normalize_role(role) when role in [:user, "user"], do: :user
  defp normalize_role(role) when role in [:assistant, "assistant"], do: :assistant
  defp normalize_role(role) when role in [:tool, "tool"], do: :tool
  defp normalize_role(role), do: role
  defp valid_optional_content(nil), do: :ok
  defp valid_optional_content(content) when is_binary(content), do: :ok
  defp valid_optional_content(_content), do: {:error, :invalid_message_content}
  defp empty_content?(content), do: content in [nil, ""]

  defp encode_arguments(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, %{} = _arguments} -> {:ok, arguments}
      _invalid -> {:error, :invalid_tool_call_arguments}
    end
  end

  defp encode_arguments(%{} = arguments), do: {:ok, JSON.encode!(arguments)}
  defp encode_arguments(_arguments), do: {:error, :invalid_tool_call_arguments}

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp stringify_map_keys(map) do
    Map.new(map, fn
      {key, %{} = value} -> {to_string(key), stringify_map_keys(value)}
      {key, value} when is_list(value) -> {to_string(key), Enum.map(value, &stringify_value/1)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_value(%{} = value), do: stringify_map_keys(value)
  defp stringify_value(value), do: value

  defp user_agent do
    version = Application.spec(:tackle_openrouter, :vsn) || ~c"0.1.0"
    "tackle-openrouter/#{List.to_string(version)}"
  end

  defp non_empty([]), do: nil
  defp non_empty(value), do: value
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
