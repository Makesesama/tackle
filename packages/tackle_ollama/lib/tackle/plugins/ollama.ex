defmodule Tackle.Plugins.Ollama do
  @moduledoc """
  Ollama Chat Completions adapter for `Tackle.Lib.LLM`.

  The adapter sends provider-neutral Tackle messages and tools to Ollama's
  OpenAI-compatible streaming endpoint. Select an Ollama Cloud model by its catalog id, without a `:cloud` suffix:

      {:ok, llm} = Tackle.Lib.LLM.select([Tackle.Plugins.Ollama], "ollama-cloud/gpt-oss:120b")

  `models/0` returns a small curated catalog. Hosts can
  make further Ollama models selectable through application configuration:

      config :tackle_ollama,
        models: [
          "gemma4:31b",
          {"gpt-oss:120b", %{context_window: 131_072}}
        ]

  API keys may be supplied explicitly, through a host-owned
  `Tackle.Lib.CredentialStore`, or through the `OLLAMA_API_KEY`
  environment variable. `login/1` prompts for a key through a
  `Tackle.Lib.Interaction` handle. No account usage API is exposed.

  The Chat Completions transport is shared with `Tackle.Plugins.OllamaLocal`,
  which talks to a local Ollama server under its own adapter identity.
  """

  @behaviour Tackle.Lib.LLM

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.CredentialStore
  alias Tackle.Lib.Interaction
  alias Tackle.Lib.Tool.Schema.JsonSchema
  alias Tackle.Plugins.Ollama.HTTP
  alias Tackle.Plugins.Ollama.SSE

  @adapter_id "ollama-cloud"
  @default_base_url "https://ollama.com/v1"

  @catalog_models ["gpt-oss:120b", "gpt-oss:20b", "kimi-k3", "deepseek-v4.1-flash", "glm-5.3"]

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def models, do: Enum.uniq(@catalog_models ++ Enum.map(configured_models(), &elem(&1, 0)))

  @impl true
  def model_info(model) do
    case List.keyfind(configured_models(), model, 0) do
      {^model, info} -> info
      nil -> nil
    end
  end

  # Entries are model ids or `{model_id, model_info}` tuples. Malformed entries
  # are kept as-is so `Tackle.Lib.LLM.select/2` reports them instead of the
  # adapter silently dropping them.
  defp configured_models do
    :tackle_ollama
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
           Interaction.prompt(interaction, label: "Ollama API key", secret: true),
         {:ok, api_key} <- normalize_api_key(api_key) do
      {:ok, %{"api_key" => api_key}}
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
    if Enum.any?(:binary.bin_to_list(api_key), &(&1 < 0x20 or &1 == 0x7F)) do
      {:error, :invalid_api_key}
    else
      case String.trim(api_key) do
        "" -> {:error, :empty_api_key}
        trimmed -> if header_safe?(trimmed), do: {:ok, trimmed}, else: {:error, :invalid_api_key}
      end
    end
  end

  defp normalize_api_key(_api_key), do: {:error, :invalid_api_key}

  # A key with control characters or spaces would make the HTTP client raise
  # with the full `authorization` header in its error, so it is rejected before
  # any request is built.
  defp header_safe?(value), do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E))

  @impl true
  def generate(schema, opts) do
    perform(schema, opts, fn _event -> :ok end)
  end

  @impl true
  def stream(schema, opts, event_callback) when is_function(event_callback, 1) do
    perform(schema, opts, event_callback)
  end

  defp perform(schema, opts, event_callback),
    do: chat(cloud_profile(), schema, opts, event_callback)

  defp cloud_profile do
    %{
      adapter_id: @adapter_id,
      models: &models/0,
      base_url: &Keyword.get(&1, :base_url, @default_base_url),
      api_key: :required,
      user_agent: "tackle-ollama-cloud"
    }
  end

  @typedoc """
  The provider identity a Chat Completions request runs under.

    * `:adapter_id` - reported as the result `:provider`, used for reasoning
      replay, generated tool-call ids, and the credential namespace.
    * `:models` - returns the selectable adapter-local model ids.
    * `:base_url` - resolves the OpenAI-compatible base URL from request options.
    * `:api_key` - `:required` sends a bearer key; `:none` sends no
      authorization header.
    * `:user_agent` - user-agent product name; the package version is appended.
  """
  @type profile :: %{
          adapter_id: String.t(),
          models: (-> [String.t()]),
          base_url: (keyword() -> String.t()),
          api_key: :required | :none,
          user_agent: String.t()
        }

  @doc false
  # Shared Chat Completions entrypoint for the Ollama adapters in this package.
  @spec chat(profile(), keyword() | map() | nil, keyword(), (map() -> any())) ::
          {:ok, map()} | {:error, term()}
  def chat(profile, schema, opts, event_callback) when is_function(event_callback, 1) do
    with :ok <- validate_model(profile, opts),
         :ok <- not_cancelled(opts),
         {:ok, api_key} <- profile_api_key(profile, opts),
         {:ok, body} <- build_request_body(profile, schema, opts),
         {:ok, response} <- send_request(profile, body, opts, api_key, event_callback),
         :ok <- not_cancelled(opts),
         {:ok, result} <-
           response_result(
             response,
             {profile.adapter_id, Keyword.fetch!(opts, :model)},
             schema,
             event_callback
           ) do
      {:ok, Map.put(result, :provider, profile.adapter_id)}
    end
  end

  defp profile_api_key(%{api_key: :required}, opts), do: api_key(opts)
  defp profile_api_key(%{api_key: :none}, _opts), do: {:ok, nil}

  defp send_request(profile, body, opts, api_key, event_callback) do
    signal = Keyword.get(opts, :cancellation_signal)
    initial_parser = SSE.new(profile.adapter_id)

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
        url: endpoint_url(profile.base_url.(opts), "/chat/completions"),
        headers: headers(profile, api_key),
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

  # `identity` is the `{adapter_id, requested_model}` of the request.
  defp response_result(%{status: status, body: body}, {adapter_id, model}, schema, event_callback)
       when status in 200..299 do
    parser =
      case body do
        %SSE{} = parser -> parser
        body when is_binary(body) -> SSE.push(SSE.new(adapter_id), body, event_callback)
        _body -> SSE.new(adapter_id)
      end
      |> SSE.finish(event_callback)

    case SSE.result(parser, model, schema) do
      {:error, {:provider_error, error}} = failure ->
        # Ollama may commit a 200 before the upstream rejects the prompt;
        # an overflow reported before any output is still an overflow.
        if SSE.output?(parser) or not overflow_message?(error),
          do: failure,
          else: {:error, :context_window_exceeded}

      result ->
        result
    end
  end

  defp response_result(%{status: status, body: body}, _identity, _schema, _event_callback) do
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
  # unclassified. Ollama relays upstream wording, so markers cover the
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

  defp error_texts(%{"error" => error}) when is_map(error) or is_binary(error),
    do: error_texts(error)

  defp error_texts(%{} = error) do
    [error["code"], error["message"]]
    |> Enum.filter(&is_binary/1)
  end

  defp error_texts(body) when is_binary(body), do: [body]
  defp error_texts(_body), do: []

  defp build_request_body(profile, schema, opts) do
    model = Keyword.fetch!(opts, :model)
    replay = {profile.adapter_id, model}

    with {:ok, tools} <- convert_tools(Keyword.get(opts, :tools, [])),
         {:ok, messages} <- convert_messages(Keyword.get(opts, :messages, []), replay),
         {:ok, response_format, schema_instruction} <- response_options(schema),
         {:ok, reasoning} <- reasoning_options(opts) do
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
        |> maybe_put("reasoning_effort", reasoning)
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

  # `replay` is the `{adapter_id, model}` whose reasoning may be replayed.
  defp convert_messages(messages, replay) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, converted} ->
      case convert_message(message, replay) do
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

  defp convert_messages(_messages, _replay), do: {:error, :invalid_messages}

  defp convert_message(message, _replay) when not is_map(message),
    do: {:error, :invalid_message}

  defp convert_message(message, replay) do
    case normalize_role(field(message, :role)) do
      :user -> text_message("user", field(message, :content))
      :assistant -> assistant_message(message, replay)
      :tool -> tool_message(message)
      role -> {:error, {:unsupported_message_role, role}}
    end
  end

  defp text_message(role, content) when is_binary(content),
    do: {:ok, %{"role" => role, "content" => content}}

  defp text_message(_role, _content), do: {:error, :invalid_message_content}

  # Tool-call-only assistant turns have no text content.
  defp assistant_message(message, replay) do
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
          |> put_replayed_reasoning(field(message, :provider_state), replay)

        {:ok, assistant}
      end
    end
  end

  # Replay reasoning only for this adapter and the same requested model.
  defp put_replayed_reasoning(assistant, provider_state, {adapter_id, model})
       when is_map(provider_state) do
    if field(provider_state, :provider) == adapter_id and
         field(provider_state, :model) == model do
      case field(provider_state, :reasoning) do
        reasoning when is_binary(reasoning) ->
          Map.put(assistant, "reasoning", reasoning)

        _none ->
          assistant
      end
    else
      assistant
    end
  end

  defp put_replayed_reasoning(assistant, _provider_state, _replay), do: assistant

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

  # Chat Completions tool results are text-only across Ollama's upstreams,
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

  # Structured responses request JSON-schema output, which Ollama forwards
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

  # Named levels are model-defined; let Ollama interpret them.
  defp reasoning_options(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      nil ->
        {:ok, nil}

      effort when effort in [:off, :none, "off", "none"] ->
        {:ok, "none"}

      effort when is_atom(effort) or is_binary(effort) ->
        value = to_string(effort)

        if value == "",
          do: {:error, {:invalid_reasoning_effort, effort}},
          else: {:ok, value}

      effort ->
        {:error, {:invalid_reasoning_effort, effort}}
    end
  end

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
        case CredentialStore.fetch(handle, @adapter_id) do
          {:ok, credentials} when is_map(credentials) ->
            credential_api_key(credentials) || environment_api_key()

          :error ->
            environment_api_key()

          {:error, reason} ->
            {:error, {:credential_store_failed, reason}}

          _other ->
            {:error, :invalid_ollama_credentials}
        end

      {:ok, _invalid} ->
        {:error, :invalid_credential_store}

      :error ->
        environment_api_key()
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

  defp environment_api_key do
    case System.get_env("OLLAMA_API_KEY") do
      api_key when is_binary(api_key) ->
        if String.trim(api_key) == "",
          do: {:error, :missing_ollama_api_key},
          else: normalize_api_key(api_key)

      nil ->
        {:error, :missing_ollama_api_key}
    end
  end

  defp headers(profile, api_key) do
    authorization = if api_key, do: [{"authorization", "Bearer #{api_key}"}], else: []

    authorization ++
      [
        {"content-type", "application/json"},
        {"accept", "text/event-stream"},
        {"user-agent", user_agent(profile.user_agent)}
      ]
  end

  @doc false
  # Joins an OpenAI-compatible base URL and an endpoint path, accepting a base
  # URL that already ends with the path.
  @spec endpoint_url(String.t(), String.t()) :: String.t()
  def endpoint_url(base_url, path) do
    base_url = String.trim_trailing(base_url, "/")

    if String.ends_with?(base_url, path), do: base_url, else: base_url <> path
  end

  defp validate_model(profile, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} when is_binary(model) ->
        if model in profile.models.(), do: :ok, else: {:error, {:unsupported_model, model}}

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

  @doc false
  # `product/version` user agent for requests from this package.
  @spec user_agent(String.t()) :: String.t()
  def user_agent(product) do
    version = Application.spec(:tackle_ollama, :vsn) || ~c"0.1.0"
    "#{product}/#{List.to_string(version)}"
  end

  defp non_empty([]), do: nil
  defp non_empty(value), do: value
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
