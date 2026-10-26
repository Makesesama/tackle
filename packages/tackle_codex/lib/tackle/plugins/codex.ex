defmodule Tackle.Plugins.Codex do
  @moduledoc """
  OpenAI Codex adapter for `Tackle.Lib.LLM`.

  The adapter uses ChatGPT subscription OAuth credentials stored under the
  provider's credential namespace and sends provider-neutral Tackle messages
  and tools to the Codex Responses endpoint. By default it attempts
  connection-scoped WebSocket continuation and falls back to SSE before
  streaming begins. Pass `transport: :sse`, `:websocket`, or
  `:websocket_cached` to select an explicit transport.

  Authentication interaction is exposed through the optional `login/1` and
  `usage/1` callbacks: the adapter owns the device-code flow and talks to the
  user through a `Tackle.Lib.Interaction` handle supplied in `opts`. The
  underlying protocol helpers remain available through `Tackle.Plugins.Codex.OAuth`.
  `stream/3` never prompts the user.

  ## Providers

  Several providers can share this adapter, such as two ChatGPT accounts
  (`codex-work/gpt-5.5`, `codex-home/gpt-5.5`). The host passes the provider
  as `opts[:provider_id]` and `opts[:provider_settings]`; without them the
  adapter acts as the default `"openai-codex"` provider. The provider id is the
  credential namespace and part of the refresh lock. `Tackle.Lib.LLM` reports
  it as the response's `:provider` and stamps it on replayable
  `:provider_state`, so one account's state is never replayed to another.

  Structured responses use the Responses API's `json_schema` text format,
  named by the `:response_schema_name` option (default `"response"`) and
  strict only when `:strict_schema` is `true` (default `false`).

  Honoured settings: `"base_url"` (the ChatGPT backend base URL). An explicit
  `:base_url` option wins over it.
  """

  @behaviour Tackle.Lib.LLM

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.CredentialStore
  alias Tackle.Lib.Interaction
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Plugins.Codex.HTTP
  alias Tackle.Plugins.Codex.OAuth
  alias Tackle.Plugins.Codex.SSE
  alias Tackle.Plugins.Codex.WebSocket

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
    "gpt-6-astra",
    "gpt-6-luna",
    "gpt-6-sol",
    "gpt-6.1-sol"
  ]
  @model_info %{
    "gpt-5.3-codex-spark" => {128_000, {1.75, 14, 0.175, 0}},
    "gpt-5.4" => {272_000, {2.5, 15, 0.25, 0}},
    "gpt-5.4-mini" => {272_000, {0.75, 4.5, 0.075, 0}},
    "gpt-5.5" => {272_000, {5, 30, 0.5, 0}},
    "gpt-5.6-luna" => {272_000, {0.2, 1.2, 0.02, 0.25}},
    "gpt-5.6-sol" => {272_000, {5, 30, 0.5, 6.25}},
    "gpt-5.6-terra" => {272_000, {2, 12, 0.2, 2.5}},
    "gpt-6-astra" => {272_000, {10, 50, 1, 12.5}},
    "gpt-6-luna" => {272_000, {0.1, 0.5, 0.01, 0.125}},
    "gpt-6-sol" => {272_000, {2, 10, 0.2, 2.5}},
    "gpt-6.1-sol" => {272_000, {2, 10, 0.1, 2.5}}
  }

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def models, do: @models

  @impl true
  def model_info(model) do
    case Map.get(@model_info, model) do
      {context_window, {input, output, cache_read, cache_write}} ->
        %{
          context_window: context_window,
          max_output_tokens: 128_000,
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

  @doc "Closes cached WebSocket connections owned by a Tackle session."
  @spec close_session(String.t()) :: :ok
  def close_session(session_id) when is_binary(session_id),
    do: WebSocket.close_session(session_id)

  @impl true
  def login(opts) do
    with {:ok, interaction} <- interaction(opts),
         :ok <- not_cancelled(opts),
         {:ok, device} <- OAuth.request_device_code(opts),
         :ok <- announce_device(interaction, device) do
      poll_device_code(interaction, device, opts)
    end
  end

  @impl true
  def usage(opts) do
    with :ok <- not_cancelled(opts),
         {:ok, opts} <- put_base_url(opts),
         {:ok, handle} <- credential_store(opts) do
      usage_request(handle, opts)
    end
  end

  defp announce_device(interaction, device) do
    Interaction.info(interaction, [
      "Open ",
      device.verification_uri,
      " and enter code ",
      device.user_code,
      "."
    ])
  end

  defp poll_device_code(interaction, device, opts) do
    Interaction.progress(
      interaction,
      [
        label: "Waiting for authorization...",
        ok: "Authorized",
        error: fn reason -> "Authorization failed: #{inspect(reason)}" end
      ],
      fn -> OAuth.complete_device_code(device, opts) end
    )
  end

  defp usage_request(handle, opts) do
    with {:ok, credentials} <- fresh_credentials(handle, nil, opts),
         {:ok, auth} <- OAuth.access(credentials),
         result <- send_usage_request(auth, opts) do
      retry_usage_unauthorized(result, handle, credentials, opts)
    end
  end

  defp retry_usage_unauthorized({:error, %Error{status: 401}}, handle, rejected, opts) do
    rejected_access_token = rejected["access_token"] || rejected["access"]

    with {:ok, credentials} <- fresh_credentials(handle, rejected_access_token, opts),
         {:ok, auth} <- OAuth.access(credentials) do
      send_usage_request(auth, opts)
    end
  end

  defp retry_usage_unauthorized(result, _handle, _rejected, _opts), do: result

  defp send_usage_request(auth, opts) do
    request_options = [
      method: :get,
      url: usage_url(opts),
      headers: base_headers(opts, auth.access_token, auth.account_id),
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
    ]

    with {:ok, response} <- HTTP.request(request_options, opts) do
      usage_response(response)
    end
  end

  defp usage_response(%{status: status, body: body}) when status in 200..299 do
    HTTP.decode_json(body)
  end

  defp usage_response(%{status: status, body: body} = response) do
    {:error, Error.from_response(status, body, Map.get(response, :headers))}
  end

  defp usage_url(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) |> String.trim_trailing("/")

    if String.ends_with?(base_url, "/wham/usage"), do: base_url, else: base_url <> "/wham/usage"
  end

  defp interaction(opts) do
    case Keyword.fetch(opts, :interaction) do
      {:ok, {module, _reference} = handle} when is_atom(module) and not is_nil(module) ->
        {:ok, handle}

      _other ->
        {:error, :interaction_required}
    end
  end

  @impl true
  def stream(schema, opts, event_callback) when is_function(event_callback, 1) do
    with :ok <- validate_model(opts),
         :ok <- not_cancelled(opts),
         {:ok, opts} <- put_base_url(opts),
         {:ok, handle} <- credential_store(opts),
         {:ok, credentials} <- fresh_credentials(handle, nil, opts),
         result <- request_once(schema, opts, credentials, event_callback) do
      retry_unauthorized(result, schema, opts, handle, credentials, event_callback)
    end
  end

  defp retry_unauthorized(
         {:error, %Error{status: 401}},
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
           send_request(body, opts, auth.access_token, auth.account_id, event_callback) do
      response_result(response, Keyword.fetch!(opts, :model), schema, event_callback)
    end
  end

  defp send_request(body, opts, access_token, account_id, event_callback) do
    case Keyword.get(opts, :transport, :auto) do
      :sse ->
        send_sse_request(body, opts, access_token, account_id, event_callback)

      transport when transport in [:websocket, :websocket_cached] ->
        body
        |> send_websocket_request(opts, access_token, account_id, event_callback, transport)
        |> websocket_result()

      :auto ->
        case send_websocket_request(body, opts, access_token, account_id, event_callback, :auto) do
          {:error, {:websocket_transport_failed, :before_stream, _reason}} ->
            send_sse_request(body, opts, access_token, account_id, event_callback)

          result ->
            websocket_result(result)
        end

      transport ->
        {:error, {:invalid_transport, transport}}
    end
  end

  # WebSocket failures carry the phase they happened in, which only decides
  # the SSE fallback above; callers see a `Tackle.Lib.LLM.Error`.
  defp websocket_result({:error, {:websocket_transport_failed, _phase, reason}}),
    do: {:error, websocket_error(reason)}

  defp websocket_result(result), do: result

  defp websocket_error(%Error{} = error), do: error
  defp websocket_error(:cancelled), do: :cancelled

  defp websocket_error(reason)
       when reason == :invalid_websocket_event or
              (is_tuple(reason) and elem(reason, 0) == :invalid_websocket_json),
       do: Error.new(:invalid_response, details: reason)

  defp websocket_error(reason), do: Error.from_transport(reason)

  defp send_sse_request(body, opts, access_token, account_id, event_callback) do
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
      headers: sse_headers(opts, access_token, account_id),
      body: JSON.encode!(body),
      raw: true,
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 120_000)
    ]

    HTTP.stream(request_options, initial_parser, stream, opts)
  end

  defp send_websocket_request(
         body,
         opts,
         access_token,
         account_id,
         event_callback,
         transport
       ) do
    websocket_opts =
      opts
      |> Keyword.put(:transport, transport)
      |> Keyword.put(:responses_url, responses_url(opts))

    request = Keyword.get(opts, :websocket_request, &WebSocket.request/4)
    visibility = :atomics.new(1, signed: false)

    tracked_callback = fn event ->
      :atomics.put(visibility, 1, 1)
      event_callback.(event)
    end

    try do
      request.(
        body,
        websocket_opts,
        websocket_headers(opts, access_token, account_id),
        tracked_callback
      )
    catch
      kind, reason ->
        {:error,
         {:websocket_transport_failed, websocket_phase(visibility),
          Error.from_caught(kind, reason)}}
    end
    |> preserve_observed_websocket_phase(visibility)
  end

  defp preserve_observed_websocket_phase(
         {:error, {:websocket_transport_failed, :before_stream, reason}},
         visibility
       ) do
    {:error, {:websocket_transport_failed, websocket_phase(visibility), reason}}
  end

  defp preserve_observed_websocket_phase(result, _visibility), do: result

  defp websocket_phase(visibility) do
    if :atomics.get(visibility, 1) == 0, do: :before_stream, else: :after_stream
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

  defp response_result(%{status: status, body: body} = response, _model, _schema, _callback),
    do: {:error, Error.from_response(status, body, Map.get(response, :headers))}

  defp build_request_body(schema, opts) do
    with {:ok, input} <- convert_messages(Keyword.get(opts, :messages, [])),
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
        |> maybe_put("prompt_cache_key", prompt_cache_key(opts))
        |> maybe_put("reasoning", reasoning_options(opts))

      {:ok, body}
    end
  rescue
    KeyError -> {:error, :model_required}
  end

  defp convert_messages(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, acc} ->
      case convert_message(message, index) do
        {:ok, items} -> {:cont, {:ok, acc ++ items}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, close_dangling_tool_calls(items)}
      error -> error
    end)
  end

  defp convert_messages(_messages), do: {:error, :invalid_messages}

  # A cancelled turn can leave a committed assistant tool call without a tool
  # result. The Responses API rejects that history on the next prompt, so close
  # only those dangling calls with the same prompt-only marker Codex uses for
  # interrupted tools.
  defp close_dangling_tool_calls(items) do
    completed_call_ids =
      items
      |> Enum.flat_map(fn
        %{"type" => "function_call_output", "call_id" => call_id}
        when is_binary(call_id) and call_id != "" ->
          [call_id]

        _item ->
          []
      end)
      |> MapSet.new()

    Enum.flat_map(items, fn
      %{"type" => "function_call", "call_id" => call_id} = item
      when is_binary(call_id) and call_id != "" ->
        if MapSet.member?(completed_call_ids, call_id) do
          [item]
        else
          [item, %{"type" => "function_call_output", "call_id" => call_id, "output" => "aborted"}]
        end

      item ->
        [item]
    end)
  end

  defp convert_message(message, _index) when not is_map(message),
    do: {:error, :invalid_message}

  defp convert_message(message, index) do
    case normalize_role(field(message, :role)) do
      :user -> {:ok, [input_message("user", field(message, :content) || "")]}
      :assistant -> {:ok, assistant_items(message, index)}
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

  # `Tackle.Lib.LLM` passes only provider state this provider and model
  # produced, so the output items are replayed as they are.
  defp assistant_items(message, index) do
    case replay_items(field(message, :provider_state)) do
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

  defp replay_items(provider_state) when is_map(provider_state) do
    case field(provider_state, :output) do
      [_ | _] = output -> {:ok, output}
      _other -> :error
    end
  end

  defp replay_items(_provider_state), do: :error

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

    if is_binary(call_id) and call_id != "" do
      case tool_output_content(content) do
        {:ok, output} ->
          {:ok, [%{"type" => "function_call_output", "call_id" => call_id, "output" => output}]}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_tool_message}
    end
  end

  # Text-only tool results stay a plain string output. A tool that also read
  # structured content (for example an image) sends a content-item array, which
  # the Responses API accepts as a function call output body.
  defp tool_output_content(content) when is_binary(content), do: {:ok, content}

  defp tool_output_content(content) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, items} ->
      case tool_output_content_item(part) do
        {:ok, item} -> {:cont, {:ok, [item | items]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp tool_output_content(_content), do: {:error, :invalid_tool_message}

  defp tool_output_content_item(part) when is_map(part) do
    case field(part, :type) do
      "text" -> input_text_item(field(part, :text))
      "image" -> input_image_item(field(part, :media_type), field(part, :data))
      type -> {:error, {:unsupported_tool_content, type}}
    end
  end

  defp tool_output_content_item(_part), do: {:error, :invalid_tool_message}

  defp input_text_item(text) when is_binary(text) do
    {:ok, %{"type" => "input_text", "text" => text}}
  end

  defp input_text_item(_text), do: {:error, :invalid_tool_message}

  defp input_image_item(media_type, data) when is_binary(media_type) and is_binary(data) do
    {:ok, %{"type" => "input_image", "image_url" => "data:#{media_type};base64,#{data}"}}
  end

  defp input_image_item(_media_type, _data), do: {:error, :invalid_tool_message}

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
    input_schema = field(tool, :input_schema)

    if is_binary(name) and name != "" and is_binary(description) and is_map(input_schema) do
      {:ok,
       %{
         "type" => "function",
         "name" => name,
         "description" => description,
         "parameters" => input_schema,
         "strict" => nil
       }}
    else
      {:error, {:invalid_tool, name}}
    end
  end

  defp convert_tool(_tool), do: {:error, :invalid_tool}

  defp text_options(nil, opts) do
    {:ok, %{"verbosity" => Keyword.get(opts, :text_verbosity, "low")}}
  end

  defp text_options(%{} = schema, opts) do
    {:ok,
     %{
       "verbosity" => Keyword.get(opts, :text_verbosity, "low"),
       "format" => %{
         "type" => "json_schema",
         "name" => Keyword.get(opts, :response_schema_name, "response"),
         "schema" => schema,
         "strict" => Keyword.get(opts, :strict_schema, false)
       }
     }}
  end

  defp text_options(_schema, _opts), do: {:error, :invalid_response_schema}

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

  defp sse_headers(opts, access_token, account_id) do
    base_headers(opts, access_token, account_id) ++
      [
        {"openai-beta", "responses=experimental"},
        {"accept", "text/event-stream"},
        {"content-type", "application/json"}
      ]
  end

  defp websocket_headers(opts, access_token, account_id) do
    base_headers(opts, access_token, account_id) ++
      [{"openai-beta", "responses_websockets=2026-02-06"}]
  end

  defp base_headers(opts, access_token, account_id) do
    base = [
      {"authorization", "Bearer #{access_token}"},
      {"chatgpt-account-id", account_id},
      {"originator", Keyword.get(opts, :originator, "tackle")},
      {"user-agent", user_agent()}
    ]

    case prompt_cache_key(opts) do
      session_id when is_binary(session_id) and session_id != "" ->
        base ++ [{"session-id", session_id}, {"x-client-request-id", session_id}]

      _session_id ->
        base
    end
  end

  defp prompt_cache_key(opts) do
    bounded_cache_key(Keyword.get(opts, :prompt_cache_key)) ||
      bounded_cache_key(Keyword.get(opts, :session_id))
  end

  defp bounded_cache_key(value) when is_binary(value) and value != "",
    do: String.slice(value, 0, 64)

  defp bounded_cache_key(_value), do: nil

  defp responses_url(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) |> String.trim_trailing("/")

    cond do
      String.ends_with?(base_url, "/codex/responses") -> base_url
      String.ends_with?(base_url, "/codex") -> base_url <> "/responses"
      true -> base_url <> "/codex/responses"
    end
  end

  defp fresh_credentials(handle, rejected_access_token, opts) do
    with {:ok, credentials} <- fetch_credentials(handle, provider_id(opts)) do
      if refresh_required?(credentials, rejected_access_token, opts) do
        refresh_locked(handle, rejected_access_token, opts)
      else
        {:ok, credentials}
      end
    end
  end

  # The lock is per store and provider, so refreshing one account never waits
  # on (or races with) another account's refresh.
  defp refresh_locked(handle, rejected_access_token, opts) do
    lock_id = {{__MODULE__, :credential_refresh, handle, provider_id(opts)}, self()}

    case :global.trans(lock_id, fn -> refresh_current(handle, rejected_access_token, opts) end) do
      {:aborted, reason} -> {:error, {:credential_refresh_lock_failed, reason}}
      result -> result
    end
  end

  defp refresh_current(handle, rejected_access_token, opts) do
    with {:ok, current} <- fetch_credentials(handle, provider_id(opts)) do
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
         :ok <- CredentialStore.put(handle, provider_id(opts), refreshed) do
      {:ok, refreshed}
    end
  end

  defp refresh_required?(credentials, nil, opts),
    do: OAuth.expired?(credentials, oauth_opts(opts))

  defp refresh_required?(credentials, rejected_access_token, _opts) do
    current_access_token = credentials["access_token"] || credentials["access"]
    current_access_token == rejected_access_token
  end

  defp fetch_credentials(handle, provider_id) do
    case CredentialStore.fetch(handle, provider_id) do
      {:ok, %{} = credentials} -> {:ok, credentials}
      :error -> {:error, :missing_codex_credentials}
      {:error, reason} -> {:error, {:credential_store_failed, reason}}
      _other -> {:error, :invalid_codex_credentials}
    end
  end

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

  defp user_agent do
    version = Application.spec(:tackle_codex, :vsn) || ~c"0.1.0"
    "tackle-codex/#{List.to_string(version)}"
  end

  defp non_empty([]), do: nil
  defp non_empty(value), do: value
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
