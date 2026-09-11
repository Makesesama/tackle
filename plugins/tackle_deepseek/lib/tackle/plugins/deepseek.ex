defmodule Tackle.Plugins.DeepSeek do
  @moduledoc """
  DeepSeek Chat Completions adapter for `Tackle.Lib.LLM`.

  The adapter sends provider-neutral Tackle messages and tools to DeepSeek's
  OpenAI-compatible streaming endpoint. API keys may be supplied explicitly,
  through a host-owned `Tackle.Lib.CredentialStore`, or through the
  `DEEPSEEK_API_KEY` environment variable.
  """

  @behaviour Tackle.Lib.LLM

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.CredentialStore
  alias Tackle.Lib.Tool.Schema.JsonSchema
  alias Tackle.Plugins.DeepSeek.HTTP
  alias Tackle.Plugins.DeepSeek.SSE

  @adapter_id "deepseek"
  @default_base_url "https://api.deepseek.com"
  @models [
    "deepseek-flash",
    "deepseek-v4-flash",
    "deepseek-v4-flash-vision-exp",
    "deepseek-v4-pro"
  ]
  @reasoning_models @models

  # `{context_window, max_output_tokens, {input, output, cache_read, cache_write}}`.
  # Prices are USD per million tokens and use DeepSeek's peak rates; off-peak
  # requests are billed at half where DeepSeek offers off-peak pricing.
  @model_info %{
    "deepseek-flash" => {1_000_000, 256_000, {0.3, 1.2, 0.006, 0}},
    "deepseek-v4-flash" => {1_000_000, 384_000, {0.14, 0.28, 0.0028, 0}},
    "deepseek-v4-flash-vision-exp" => {1_000_000, 384_000, {0.14, 0.28, 0.0028, 0}},
    "deepseek-v4-pro" => {1_000_000, 384_000, {0.435, 0.87, 0.003625, 0}}
  }

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def models, do: @models

  @impl true
  def model_info(model) do
    case Map.get(@model_info, model) do
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
        nil
    end
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
         {:ok, api_key} <- api_key(opts),
         {:ok, body} <- build_request_body(schema, opts),
         {:ok, response} <- send_request(body, opts, api_key, event_callback),
         {:ok, result} <-
           response_result(response, Keyword.fetch!(opts, :model), schema, event_callback) do
      {:ok, Map.put(result, :provider, @adapter_id)}
    end
  end

  defp send_request(body, opts, api_key, event_callback) do
    signal = Keyword.get(opts, :cancellation_signal)
    initial_parser = SSE.new()

    stream = fn chunk, _response, parser ->
      parser = parser_state(parser, initial_parser)

      if Cancellation.cancelled?(signal) do
        {:halt, SSE.cancel(parser)}
      else
        {:cont, SSE.push(parser, chunk, event_callback)}
      end
    end

    request_options = [
      method: :post,
      url: chat_completions_url(opts),
      headers: headers(api_key),
      body: JSON.encode!(body),
      raw: true,
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 120_000)
    ]

    HTTP.stream(request_options, initial_parser, stream, opts)
  end

  defp response_result(%{status: status, body: body}, model, schema, event_callback)
       when status in 200..299 do
    parser =
      case body do
        %SSE{} = parser -> parser
        body when is_binary(body) -> SSE.push(SSE.new(), body, event_callback)
        _body -> SSE.new()
      end

    parser
    |> SSE.finish(event_callback)
    |> SSE.result(model, schema)
  end

  defp response_result(%{status: status, body: body}, _model, _schema, _event_callback) do
    error_body = HTTP.error_body(body)

    case classify_overflow(status, error_body) do
      :context_window_exceeded -> {:error, :context_window_exceeded}
      :other -> {:error, {:http_error, status, error_body}}
    end
  end

  # Only wire errors that unambiguously name a context/token limit are treated as
  # overflow, so the harness can run exactly one compact-and-retry. Generic
  # 4xx/5xx, rate limits, and transport failures stay unclassified.
  @overflow_markers [
    "context_length_exceeded",
    "context_window_exceeded",
    "maximum context length",
    "exceeds the context window",
    "too many tokens",
    "input is too long",
    "reduce the length of the messages"
  ]

  defp classify_overflow(status, error_body) when status in [400, 413, 422] do
    if overflow_message?(error_body), do: :context_window_exceeded, else: :other
  end

  defp classify_overflow(_status, _error_body), do: :other

  defp overflow_message?(error_body) do
    text =
      case error_body do
        body when is_binary(body) -> body
        body -> inspect(body, limit: 20, printable_limit: 4_096)
      end

    downcased = String.downcase(text)
    Enum.any?(@overflow_markers, &String.contains?(downcased, &1))
  end

  defp build_request_body(schema, opts) do
    model = Keyword.fetch!(opts, :model)

    with {:ok, tools} <- convert_tools(Keyword.get(opts, :tools, [])),
         {:ok, messages} <- convert_messages(Keyword.get(opts, :messages, []), model),
         {:ok, response_format, schema_instruction} <- response_options(schema),
         {:ok, reasoning_options} <- reasoning_options(opts) do
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
        |> maybe_put("temperature", Keyword.get(opts, :temperature))
        |> maybe_put("top_p", Keyword.get(opts, :top_p))
        |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens))
        |> maybe_put("stop", Keyword.get(opts, :stop))
        |> maybe_put("user_id", Keyword.get(opts, :user_id))
        |> Map.merge(reasoning_options)

      {:ok, body}
    end
  rescue
    KeyError -> {:error, :model_required}
  end

  defp convert_messages(messages, model) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, converted} ->
      case convert_message(message, model) do
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

  defp convert_messages(_messages, _model), do: {:error, :invalid_messages}

  defp convert_message(message, _model) when not is_map(message),
    do: {:error, :invalid_message}

  defp convert_message(message, model) do
    case normalize_role(field(message, :role)) do
      :user -> text_message("user", field(message, :content))
      :assistant -> assistant_message(message, model)
      :tool -> tool_message(message)
      role -> {:error, {:unsupported_message_role, role}}
    end
  end

  defp text_message(role, content) when is_binary(content),
    do: {:ok, %{"role" => role, "content" => content}}

  defp text_message(_role, _content), do: {:error, :invalid_message_content}

  defp assistant_message(message, model) do
    content = field(message, :content)
    tool_calls = field(message, :tool_calls) |> List.wrap()

    with :ok <- valid_optional_content(content),
         {:ok, tool_calls} <- convert_tool_calls(tool_calls) do
      if empty_content?(content) and tool_calls == [] do
        {:ok, nil}
      else
        assistant =
          %{"role" => "assistant", "content" => normalize_assistant_content(content)}
          |> maybe_put("tool_calls", non_empty(tool_calls))
          |> maybe_put_reasoning_content(message, model)

        {:ok, assistant}
      end
    end
  end

  defp tool_message(message) do
    call_id = field(message, :tool_call_id)
    content = field(message, :content)

    if is_binary(call_id) and call_id != "" and is_binary(content) do
      {:ok, %{"role" => "tool", "tool_call_id" => call_id, "content" => content}}
    else
      {:error, :invalid_tool_message}
    end
  end

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
    |> Enum.reduce_while({:ok, MapSet.new()}, fn message, {:ok, pending} ->
      role = message["role"]
      tool_calls = message["tool_calls"] || []

      cond do
        role == "assistant" and tool_calls != [] and MapSet.size(pending) == 0 ->
          ids = Enum.map(tool_calls, & &1["id"])
          next_pending = MapSet.new(ids)

          if length(ids) == MapSet.size(next_pending),
            do: {:cont, {:ok, next_pending}},
            else: {:halt, {:error, :duplicate_tool_call_id}}

        role == "tool" and MapSet.member?(pending, message["tool_call_id"]) ->
          {:cont, {:ok, MapSet.delete(pending, message["tool_call_id"])}}

        role == "tool" ->
          {:halt, {:error, {:unexpected_tool_result, message["tool_call_id"]}}}

        MapSet.size(pending) > 0 ->
          {:halt, {:error, :missing_tool_results}}

        true ->
          {:cont, {:ok, pending}}
      end
    end)
    |> case do
      {:ok, pending} ->
        if MapSet.size(pending) == 0, do: :ok, else: {:error, :missing_tool_results}

      error ->
        error
    end
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
           "parameters" => tool_json_schema(input_schema),
           "strict" => false
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

  defp response_options(nil), do: {:ok, nil, nil}

  defp response_options(schema) when is_list(schema) do
    json_schema = JsonSchema.to_json_schema(schema)
    {:ok, %{"type" => "json_object"}, schema_instruction(json_schema)}
  end

  defp response_options(%{} = schema) do
    {:ok, %{"type" => "json_object"}, schema_instruction(stringify_map_keys(schema))}
  end

  defp response_options(_schema), do: {:error, :invalid_response_schema}

  defp schema_instruction(json_schema) do
    "Return only a JSON object matching this JSON Schema: #{JSON.encode!(json_schema)}"
  end

  defp prepend_system_and_schema(messages, system, schema_instruction) do
    content =
      [system, schema_instruction]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n\n")

    if content == "", do: messages, else: [%{"role" => "system", "content" => content} | messages]
  end

  defp maybe_put_reasoning_content(message, source, model) do
    if model in @reasoning_models do
      reasoning_content = replay_reasoning_content(field(source, :provider_state), model)
      Map.put(message, "reasoning_content", reasoning_content || "")
    else
      message
    end
  end

  defp replay_reasoning_content(provider_state, model) when is_map(provider_state) do
    provider = field(provider_state, :provider)
    state_model = field(provider_state, :model)
    reasoning_content = field(provider_state, :reasoning_content)

    if provider == @adapter_id and state_model == model and is_binary(reasoning_content),
      do: reasoning_content,
      else: nil
  end

  defp replay_reasoning_content(_provider_state, _model), do: nil

  defp tool_choice(opts, tools) do
    case Keyword.fetch(opts, :tool_choice) do
      {:ok, choice} -> choice
      :error when tools != [] -> "auto"
      :error -> nil
    end
  end

  defp reasoning_options(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      nil ->
        {:ok, %{}}

      effort when effort in [:off, :none, "off", "none"] ->
        {:ok, %{"thinking" => %{"type" => "disabled"}}}

      effort when effort in [:low, :high, :max, "low", "high", "max"] ->
        {:ok,
         %{
           "thinking" => %{"type" => "enabled"},
           "reasoning_effort" => to_string(effort)
         }}

      effort ->
        {:error, {:invalid_reasoning_effort, effort}}
    end
  end

  defp api_key(opts) do
    case Keyword.get(opts, :api_key) do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, api_key}
      _missing -> stored_or_environment_api_key(opts)
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
            {:error, :invalid_deepseek_credentials}
        end

      {:ok, _invalid} ->
        {:error, :invalid_credential_store}

      :error ->
        environment_api_key()
    end
  end

  defp credential_api_key(credentials) do
    case field(credentials, :api_key) || field(credentials, :key) do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, api_key}
      _missing -> nil
    end
  end

  defp environment_api_key do
    case System.get_env("DEEPSEEK_API_KEY") do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, api_key}
      _missing -> {:error, :missing_deepseek_api_key}
    end
  end

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"user-agent", user_agent()}
    ]
  end

  defp chat_completions_url(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) |> String.trim_trailing("/")

    if String.ends_with?(base_url, "/chat/completions"),
      do: base_url,
      else: base_url <> "/chat/completions"
  end

  defp validate_model(opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} when model in @models -> :ok
      {:ok, model} -> {:error, {:unsupported_model, model}}
      :error -> {:error, :model_required}
    end
  end

  defp not_cancelled(opts) do
    if Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal)),
      do: {:error, :cancelled},
      else: :ok
  end

  defp parser_state(%SSE{} = parser, _initial), do: parser
  defp parser_state(_body, initial), do: initial
  defp normalize_role(role) when role in [:user, "user"], do: :user
  defp normalize_role(role) when role in [:assistant, "assistant"], do: :assistant
  defp normalize_role(role) when role in [:tool, "tool"], do: :tool
  defp normalize_role(role), do: role
  defp valid_optional_content(nil), do: :ok
  defp valid_optional_content(content) when is_binary(content), do: :ok
  defp valid_optional_content(_content), do: {:error, :invalid_message_content}
  defp normalize_assistant_content(nil), do: ""
  defp normalize_assistant_content(content), do: content
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
    version = Application.spec(:tackle_deepseek, :vsn) || ~c"0.1.0"
    "tackle-deepseek/#{List.to_string(version)}"
  end

  defp non_empty([]), do: nil
  defp non_empty(value), do: value
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
