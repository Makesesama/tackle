defmodule Tackle.Plugins.Codex do
  @moduledoc """
  OpenAI Codex adapter for `Tackle.Lib.LLM`.

  The adapter uses ChatGPT subscription OAuth credentials stored under the
  `"openai-codex"` credential namespace and sends provider-neutral Tackle
  messages and tools to the Codex Responses SSE endpoint.

  Authentication interaction is exposed separately through
  `Tackle.Plugins.Codex.OAuth`; `generate/2` and `stream/3` never prompt the
  user.
  """

  @behaviour Tackle.Lib.LLM

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.CredentialStore
  alias Tackle.Lib.Tool.Schema.JsonSchema
  alias Tackle.Plugins.Codex.HTTP
  alias Tackle.Plugins.Codex.OAuth
  alias Tackle.Plugins.Codex.SSE

  @adapter_id "openai-codex"
  @default_base_url "https://chatgpt.com/backend-api"
  @models [
    "gpt-5.3-codex-spark",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.5",
    "gpt-5.6-luna",
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-6-astra"
  ]

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def models, do: @models

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
         {:ok, handle} <- credential_store(opts),
         {:ok, credentials} <- fresh_credentials(handle, nil, opts),
         result <- request_once(schema, opts, credentials, event_callback) do
      retry_unauthorized(result, schema, opts, handle, credentials, event_callback)
    end
  end

  defp retry_unauthorized(
         {:error, {:http_error, 401, _body}},
         schema,
         opts,
         handle,
         rejected_credentials,
         event_callback
       ) do
    rejected_access_token = rejected_credentials["access_token"] || rejected_credentials["access"]

    with {:ok, credentials} <- fresh_credentials(handle, rejected_access_token, opts) do
      request_once(schema, opts, credentials, event_callback)
    end
  end

  defp retry_unauthorized(result, _schema, _opts, _handle, _credentials, _event_callback),
    do: result

  defp request_once(schema, opts, credentials, event_callback) do
    with {:ok, auth} <- OAuth.access(credentials),
         {:ok, body} <- build_request_body(schema, opts),
         {:ok, response} <-
           send_request(body, opts, auth.access_token, auth.account_id, event_callback),
         {:ok, result} <-
           response_result(response, Keyword.fetch!(opts, :model), schema, event_callback) do
      {:ok, Map.put(result, :provider, @adapter_id)}
    end
  end

  defp send_request(body, opts, access_token, account_id, event_callback) do
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
      url: responses_url(opts),
      headers: headers(opts, access_token, account_id),
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
    {:error, {:http_error, status, HTTP.error_body(body)}}
  end

  defp build_request_body(schema, opts) do
    with {:ok, input} <-
           convert_messages(Keyword.get(opts, :messages, []), Keyword.fetch!(opts, :model)),
         {:ok, tools} <- convert_tools(Keyword.get(opts, :tools, [])),
         {:ok, text} <- text_options(schema, opts) do
      body =
        %{
          "model" => Keyword.fetch!(opts, :model),
          "store" => false,
          "stream" => true,
          "instructions" => Keyword.get(opts, :system) || "You are a helpful assistant.",
          "input" => input,
          "text" => text,
          "include" => ["reasoning.encrypted_content"],
          "tool_choice" => Keyword.get(opts, :tool_choice, "auto"),
          "parallel_tool_calls" => Keyword.get(opts, :parallel_tool_calls, true)
        }
        |> maybe_put("tools", non_empty(tools))
        |> maybe_put("service_tier", Keyword.get(opts, :service_tier))
        |> maybe_put("prompt_cache_key", Keyword.get(opts, :prompt_cache_key))
        |> maybe_put("reasoning", reasoning_options(opts))

      {:ok, body}
    end
  rescue
    KeyError -> {:error, :model_required}
  end

  defp convert_messages(messages, model) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, acc} ->
      case convert_message(message, index, model) do
        {:ok, items} -> {:cont, {:ok, acc ++ items}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp convert_messages(_messages, _model), do: {:error, :invalid_messages}

  defp convert_message(message, _index, _model) when not is_map(message),
    do: {:error, :invalid_message}

  defp convert_message(message, index, model) do
    case normalize_role(field(message, :role)) do
      :user -> {:ok, [input_message("user", field(message, :content) || "")]}
      :assistant -> {:ok, assistant_items(message, index, model)}
      :tool -> tool_output(message)
      role -> {:error, {:unsupported_message_role, role}}
    end
  end

  defp normalize_role(role) when role in [:user, "user"], do: :user
  defp normalize_role(role) when role in [:assistant, "assistant"], do: :assistant
  defp normalize_role(role) when role in [:tool, "tool"], do: :tool
  defp normalize_role(role), do: role

  defp input_message(role, content) when is_binary(content) do
    %{"role" => role, "content" => [%{"type" => "input_text", "text" => content}]}
  end

  defp assistant_items(message, index, model) do
    case replay_items(field(message, :provider_state), model) do
      {:ok, items} -> items
      :error -> synthetic_assistant_items(message, index)
    end
  end

  defp synthetic_assistant_items(message, index) do
    content_items =
      case field(message, :content) do
        content when is_binary(content) and content != "" ->
          [
            %{
              "type" => "message",
              "role" => "assistant",
              "status" => "completed",
              "id" => "msg_tackle_#{index}",
              "content" => [%{"type" => "output_text", "text" => content, "annotations" => []}]
            }
          ]

        _content ->
          []
      end

    calls =
      message
      |> field(:tool_calls)
      |> List.wrap()
      |> Enum.map(&function_call_item/1)

    content_items ++ calls
  end

  defp replay_items(provider_state, model) when is_map(provider_state) do
    provider = field(provider_state, :provider)
    state_model = field(provider_state, :model)
    output = field(provider_state, :output)

    if provider == @adapter_id and state_model == model and is_list(output) and output != [] do
      {:ok, output}
    else
      :error
    end
  end

  defp replay_items(_provider_state, _model), do: :error

  defp function_call_item(call) do
    function = field(call, :function) || %{}
    id = field(call, :id)
    name = field(call, :name) || field(function, :name)
    arguments = field(call, :arguments) || field(function, :arguments) || %{}

    %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => encode_arguments(arguments)
    }
  end

  defp tool_output(message) do
    call_id = field(message, :tool_call_id)
    content = field(message, :content) || ""

    if is_binary(call_id) and call_id != "" and is_binary(content) do
      {:ok, [%{"type" => "function_call_output", "call_id" => call_id, "output" => content}]}
    else
      {:error, :invalid_tool_message}
    end
  end

  defp convert_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      case convert_tool(tool) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
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
         "name" => name,
         "description" => description,
         "parameters" => tool_json_schema(input_schema),
         "strict" => nil
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

  defp normalized_type_schema("string"), do: %{"type" => "string"}
  defp normalized_type_schema("integer"), do: %{"type" => "integer"}
  defp normalized_type_schema("number"), do: %{"type" => "number"}
  defp normalized_type_schema("boolean"), do: %{"type" => "boolean"}
  defp normalized_type_schema(type) when type in ["map", "object"], do: %{"type" => "object"}

  defp normalized_type_schema("array<" <> inner) do
    inner = String.slice(inner, 0, max(0, byte_size(inner) - 1))
    %{"type" => "array", "items" => normalized_type_schema(inner)}
  end

  defp normalized_type_schema(_type), do: %{"type" => "string"}

  defp text_options(nil, opts) do
    {:ok, %{"verbosity" => Keyword.get(opts, :text_verbosity, "low")}}
  end

  defp text_options(schema, opts) do
    with {:ok, json_schema} <- json_schema(schema) do
      {:ok,
       %{
         "verbosity" => Keyword.get(opts, :text_verbosity, "low"),
         "format" => %{
           "type" => "json_schema",
           "name" => Keyword.get(opts, :response_schema_name, "response"),
           "schema" => json_schema,
           "strict" => Keyword.get(opts, :strict_schema, false)
         }
       }}
    end
  end

  defp json_schema(schema) when is_list(schema), do: {:ok, JsonSchema.to_json_schema(schema)}
  defp json_schema(%{} = schema), do: {:ok, stringify_map_keys(schema)}
  defp json_schema(_schema), do: {:error, :invalid_response_schema}

  defp reasoning_options(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      nil ->
        nil

      effort ->
        %{
          "effort" => to_string(effort),
          "summary" => Keyword.get(opts, :reasoning_summary, "auto")
        }
    end
  end

  defp headers(opts, access_token, account_id) do
    base = [
      {"authorization", "Bearer #{access_token}"},
      {"chatgpt-account-id", account_id},
      {"originator", Keyword.get(opts, :originator, "tackle")},
      {"user-agent", user_agent()},
      {"openai-beta", "responses=experimental"},
      {"accept", "text/event-stream"},
      {"content-type", "application/json"}
    ]

    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        base ++ [{"session-id", session_id}, {"x-client-request-id", session_id}]

      _session_id ->
        base
    end
  end

  defp responses_url(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) |> String.trim_trailing("/")

    cond do
      String.ends_with?(base_url, "/codex/responses") -> base_url
      String.ends_with?(base_url, "/codex") -> base_url <> "/responses"
      true -> base_url <> "/codex/responses"
    end
  end

  defp fresh_credentials(handle, rejected_access_token, opts) do
    with {:ok, credentials} <- fetch_credentials(handle) do
      if refresh_required?(credentials, rejected_access_token, opts) do
        refresh_locked(handle, rejected_access_token, opts)
      else
        {:ok, credentials}
      end
    end
  end

  defp refresh_locked(handle, rejected_access_token, opts) do
    lock_id = {{__MODULE__, :credential_refresh, handle}, self()}

    case :global.trans(lock_id, fn -> refresh_current(handle, rejected_access_token, opts) end) do
      {:aborted, reason} -> {:error, {:credential_refresh_lock_failed, reason}}
      result -> result
    end
  end

  defp refresh_current(handle, rejected_access_token, opts) do
    with {:ok, current} <- fetch_credentials(handle) do
      refresh_or_return(current, handle, rejected_access_token, opts)
    end
  end

  defp refresh_or_return(current, handle, rejected_access_token, opts) do
    if refresh_required?(current, rejected_access_token, opts) do
      refresh_and_store(current, handle, opts)
    else
      {:ok, current}
    end
  end

  defp refresh_and_store(current, handle, opts) do
    with {:ok, refreshed} <- OAuth.refresh(current, oauth_opts(opts)),
         :ok <- CredentialStore.put(handle, @adapter_id, refreshed) do
      {:ok, refreshed}
    end
  end

  defp refresh_required?(credentials, nil, opts),
    do: OAuth.expired?(credentials, oauth_opts(opts))

  defp refresh_required?(credentials, rejected_access_token, _opts) do
    current_access_token = credentials["access_token"] || credentials["access"]
    current_access_token == rejected_access_token
  end

  defp fetch_credentials(handle) do
    case CredentialStore.fetch(handle, @adapter_id) do
      {:ok, %{} = credentials} -> {:ok, credentials}
      :error -> {:error, :missing_codex_credentials}
      {:error, reason} -> {:error, {:credential_store_failed, reason}}
      _other -> {:error, :invalid_codex_credentials}
    end
  end

  defp credential_store(opts) do
    case Keyword.fetch(opts, :credential_store) do
      {:ok, {module, _reference} = handle} when is_atom(module) -> {:ok, handle}
      _result -> {:error, :credential_store_required}
    end
  end

  defp oauth_opts(opts) do
    Keyword.take(opts, [
      :request,
      :auth_base_url,
      :client_id,
      :receive_timeout,
      :now,
      :refresh_skew_ms,
      :cancellation_signal
    ])
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

  defp encode_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_arguments(arguments), do: JSON.encode!(arguments)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

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
    version = Application.spec(:tackle_codex, :vsn) || ~c"0.1.0"
    "tackle-codex/#{List.to_string(version)}"
  end

  defp non_empty([]), do: nil
  defp non_empty(value), do: value
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
