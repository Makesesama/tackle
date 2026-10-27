defmodule Tackle.Plugins.Anthropic do
  @moduledoc """
  Anthropic Claude adapter for `Tackle.Lib.LLM`.

  The adapter sends provider-neutral Tackle messages and tools to the Anthropic
  Messages API. It supports two auth modes:

    * **Claude Pro/Max OAuth** — subscription credentials stored under the
      provider's credential namespace. OAuth requests carry the Claude Code
      billing/identity system blocks, betas, and user agent that Anthropic's
      classifier requires, and tool names are namespaced like MCP tools.
    * **API key** — passed explicitly, read from the credential store, or taken
      from an environment variable: the provider's `"api_key_env"` setting, or
      `ANTHROPIC_API_KEY` for the default `"anthropic"` provider only.

  Interactive login is exposed through the optional `login/1` callback and talks
  to the user through a `Tackle.Lib.Interaction` handle. `stream/3` never
  prompts or opens a browser; it refreshes expiring OAuth credentials through
  the injected `Tackle.Lib.CredentialStore` and retries one request after a
  `401`.

  OAuth credentials carry a rotating refresh token: once spent, it is invalid
  for everyone else. A refresh runs inside
  `Tackle.Lib.CredentialStore.with_lock/3` on the provider's namespace. Under
  the lock the adapter fetches the credentials again and refreshes only if they
  still need it; otherwise it uses what another process stored meanwhile. When
  the store's lock spans operating-system processes, as `Tackle.Auth.Store`'s
  does for `auth.json`, only one process spends the refresh token. A failure to
  get the lock returns `{:error, {:credential_lock_failed, reason}}`.

  ## Providers

  Several providers can share this adapter, each with its own login. The host
  passes the provider as `opts[:provider_id]` and `opts[:provider_settings]`;
  without them the adapter acts as the default `"anthropic"` provider. The
  provider id is the credential namespace, which a refresh locks;
  `Tackle.Lib.LLM` reports it as the response's `:provider` and stamps it on
  replayable `:provider_state`.

  Honoured settings: `"base_url"` (the Messages API base URL; an explicit
  `:base_url` option wins over it) and `"api_key_env"` (the environment
  variable consulted for an API key when none is stored). Only the default
  `"anthropic"` provider falls back to `ANTHROPIC_API_KEY` without
  `"api_key_env"`, so another provider never picks up its key by accident.
  Without credentials, requests fail with
  `{:error, {:missing_anthropic_credentials, provider_id}}`.

  ## Thinking levels

  `:reasoning_effort` accepts every `Tackle.Lib.Thinking` level. Adaptive
  models get the nearest effort they support (`effort_levels/1`), so `minimal`
  is `low` and `xhigh` or `max` fall back to the highest level below them.
  Older models get a thinking budget per level, `max` being the whole output
  limit. `off` sends no thinking options.
  """

  @behaviour Tackle.Lib.LLM

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.CredentialStore
  alias Tackle.Lib.Interaction
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.Thinking
  alias Tackle.Plugins.Anthropic.Convert
  alias Tackle.Plugins.Anthropic.HTTP
  alias Tackle.Plugins.Anthropic.OAuth
  alias Tackle.Plugins.Anthropic.Prompt
  alias Tackle.Plugins.Anthropic.SSE

  @adapter_id "anthropic"
  @default_base_url "https://api.anthropic.com"
  @anthropic_version "2023-06-01"
  @api_key_env "ANTHROPIC_API_KEY"

  @oauth_betas ["claude-code-20250219", "oauth-2025-04-20", "interleaved-thinking-2025-05-14"]
  @api_key_betas ["interleaved-thinking-2025-05-14"]

  @models [
    "claude-opus-5-5",
    "claude-opus-5",
    "claude-opus-4-8",
    "claude-opus-4-7",
    "claude-opus-4-6",
    "claude-opus-4-5",
    "claude-sonnet-5-5",
    "claude-sonnet-5",
    "claude-sonnet-4-6",
    "claude-sonnet-4-5",
    "claude-haiku-4-5",
    "claude-fable-5",
    "claude-fable-5-1"
  ]

  # `{context_window, max_output_tokens, {input, output, cache_read, cache_write}}`.
  # Prices are USD per million tokens.
  @model_info %{
    "claude-opus-5-5" => {1_000_000, 128_000, {4, 20, 0.2, 5}},
    "claude-opus-5" => {1_000_000, 128_000, {5, 25, 0.5, 6.25}},
    "claude-opus-4-8" => {1_000_000, 128_000, {5, 25, 0.5, 6.25}},
    "claude-opus-4-7" => {1_000_000, 128_000, {5, 25, 0.5, 6.25}},
    "claude-opus-4-6" => {1_000_000, 128_000, {5, 25, 0.5, 6.25}},
    "claude-opus-4-5" => {200_000, 64_000, {5, 25, 0.5, 6.25}},
    "claude-sonnet-5-5" => {1_000_000, 128_000, {2, 10, 0.2, 2.5}},
    "claude-sonnet-5" => {1_000_000, 128_000, {2, 10, 0.2, 2.5}},
    "claude-sonnet-4-6" => {1_000_000, 128_000, {3, 15, 0.3, 3.75}},
    "claude-sonnet-4-5" => {1_000_000, 64_000, {3, 15, 0.3, 3.75}},
    "claude-haiku-4-5" => {200_000, 64_000, {1, 5, 0.1, 1.25}},
    "claude-fable-5" => {1_000_000, 128_000, {10, 50, 1, 12.5}},
    "claude-fable-5-1" => {1_000_000, 128_000, {10, 50, 0.25, 12.5}}
  }

  # Budgets for models without adaptive thinking; `max` uses the whole
  # output limit.
  @thinking_budgets %{
    "minimal" => 1_024,
    "low" => 4_096,
    "medium" => 10_240,
    "high" => 20_480,
    "xhigh" => 32_000
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

  @doc """
  Runs the interactive login flow and returns credentials to store.

  Defaults to the Claude Pro/Max OAuth paste flow. Pass `auth: :api_key` to
  prompt for an Anthropic API key instead.
  """
  @impl true
  def login(opts) do
    with {:ok, interaction} <- interaction(opts),
         :ok <- not_cancelled(opts),
         {:ok, mode} <- auth_mode(opts) do
      case mode do
        :api_key -> api_key_login(interaction, opts)
        :oauth -> oauth_login(interaction, opts)
      end
    end
  end

  @doc "Reports whether usable Anthropic credentials are stored."
  @impl true
  def status(opts) do
    case stored_oauth(opts) do
      {:ok, credentials, _handle} ->
        {:ok, if(OAuth.expired?(credentials, opts), do: :expired, else: :stored)}

      :none ->
        case api_key_auth(opts) do
          {:ok, _auth} -> {:ok, :stored}
          {:error, {:missing_anthropic_credentials, _provider_id}} -> {:ok, :missing}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(schema, opts, event_callback) when is_function(event_callback, 1) do
    with :ok <- validate_model(opts),
         :ok <- not_cancelled(opts),
         {:ok, opts} <- Provider.put_base_url(opts, @adapter_id),
         {:ok, auth} <- resolve_auth(opts),
         result <- request_once(schema, opts, auth, event_callback) do
      retry_unauthorized(result, schema, opts, auth, event_callback)
    end
  end

  defp retry_unauthorized(
         {:error, %Error{status: 401}},
         schema,
         opts,
         %{type: :oauth, handle: handle, token: rejected},
         event_callback
       ) do
    with {:ok, credentials} <- fetch_credentials(handle, provider_id(opts)),
         {:ok, credentials} <- maybe_refresh(handle, credentials, rejected, opts) do
      auth = oauth_auth(handle, credentials)
      request_once(schema, opts, auth, event_callback)
    end
  end

  defp retry_unauthorized(result, _schema, _opts, _auth, _event_callback), do: result

  defp request_once(schema, opts, auth, event_callback) do
    with {:ok, body} <- build_request_body(schema, opts, auth),
         {:ok, response} <- send_request(body, opts, auth, event_callback) do
      response_result(response, Keyword.fetch!(opts, :model), schema, event_callback)
    end
  end

  defp send_request(body, opts, auth, event_callback) do
    signal = Keyword.get(opts, :cancellation_signal)
    is_oauth = oauth_auth?(auth)
    tool_names = Convert.tool_name_map(Keyword.get(opts, :tools, []), is_oauth)
    initial_parser = SSE.new(tool_names: tool_names, is_oauth: is_oauth)

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
      url: messages_url(opts),
      headers: headers(opts, auth),
      body: JSON.encode!(body),
      raw: true,
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 120_000)
    ]

    case HTTP.stream(request_options, initial_parser, stream, opts) do
      {:ok, %{status: status, body: body} = response} when status in 200..299 ->
        body =
          case body do
            %SSE{} = parser -> parser
            body when is_binary(body) -> SSE.push(initial_parser, body, event_callback)
            _other -> initial_parser
          end

        {:ok, Map.put(response, :body, body)}

      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp response_result(%{status: status, body: %SSE{} = parser}, model, schema, event_callback)
       when status in 200..299 do
    parser
    |> SSE.finish(event_callback)
    |> SSE.result(model, schema)
  end

  defp response_result(%{status: status, body: body} = response, _model, _schema, _callback),
    do: {:error, Error.from_response(status, body, Map.get(response, :headers))}

  defp build_request_body(schema, opts, auth) do
    model = Keyword.fetch!(opts, :model)
    is_oauth = oauth_auth?(auth)
    max_tokens = Keyword.get(opts, :max_tokens) || default_max_tokens(model)

    with {:ok, schema_instruction} <- schema_instruction(schema),
         {:ok, messages} <-
           Convert.messages(Keyword.get(opts, :messages, []), is_oauth),
         {:ok, tools} <- Convert.tools(Keyword.get(opts, :tools, []), is_oauth),
         {:ok, thinking} <- thinking_options(opts, model, max_tokens) do
      body =
        %{
          "model" => model,
          "messages" => messages,
          "max_tokens" => max_tokens,
          "stream" => true
        }
        |> maybe_put(
          "system",
          Prompt.system_blocks(Keyword.get(opts, :system), schema_instruction, is_oauth, opts)
        )
        |> maybe_put("tools", non_empty(tools))
        |> maybe_put("tool_choice", tool_choice(opts, tools))
        |> maybe_put("temperature", temperature(opts, thinking))
        |> maybe_put("top_p", top_p(opts, thinking))
        |> maybe_put("stop_sequences", stop_sequences(opts))
        |> Map.merge(thinking)

      {:ok, body}
    end
  rescue
    KeyError -> {:error, :model_required}
  end

  defp schema_instruction(nil), do: {:ok, nil}

  defp schema_instruction(%{} = schema) do
    {:ok, "Return only a JSON object matching this JSON Schema: #{JSON.encode!(schema)}"}
  end

  defp schema_instruction(_schema), do: {:error, :invalid_response_schema}

  defp thinking_options(opts, model, max_tokens) do
    case Thinking.parse(Keyword.get(opts, :reasoning_effort)) do
      {:ok, level} when level in [nil, "off"] -> {:ok, %{}}
      {:ok, level} -> {:ok, build_thinking(level, model, max_tokens, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_thinking(level, model, max_tokens, opts) do
    case effort_levels(model) do
      nil ->
        budget_tokens =
          level |> thinking_budget(max_tokens, opts) |> min(max_tokens - 1) |> max(1)

        %{
          "thinking" => %{
            "type" => "enabled",
            "budget_tokens" => budget_tokens,
            "display" => "summarized"
          }
        }

      levels ->
        %{
          "thinking" => %{"type" => "adaptive", "display" => "summarized"},
          "output_config" => %{"effort" => Thinking.nearest(level, levels)}
        }
    end
  end

  @doc """
  Returns the `output_config.effort` levels `model` accepts, or `nil` for a
  model that takes a thinking budget instead.

  Adaptive-thinking models (`*-5`, `*-4-6` and later) accept `low`,
  `medium`, and `high`; Opus 4.6 and Sonnet 4.6 add `max`, and the 5.x
  families and Opus 4.7 and later add `xhigh` and `max`.
  """
  @spec effort_levels(String.t()) :: [String.t(), ...] | nil
  def effort_levels(model) do
    id = model |> String.downcase() |> String.replace(".", "-")

    cond do
      Regex.match?(~r/claude-(?:opus|sonnet|haiku|fable|mythos)-5(?:-|$)/, id) ->
        ~w(low medium high xhigh max)

      Regex.match?(~r/claude-opus-4-(?:[7-9]|\d{2,})(?:-|$)/, id) ->
        ~w(low medium high xhigh max)

      Regex.match?(~r/claude-(?:opus|sonnet)-4-6(?:-|$)/, id) ->
        ~w(low medium high max)

      Regex.match?(~r/claude-(?:opus|sonnet|haiku|fable|mythos)-4-(?:[6-9]|\d{2,})(?:-|$)/, id) ->
        ~w(low medium high)

      true ->
        nil
    end
  end

  # `max` has no fixed budget: it is the whole output limit, less the one
  # token the API requires for the answer.
  defp thinking_budget(level, max_tokens, opts) do
    budgets =
      case Keyword.get(opts, :thinking_budgets, %{}) do
        budgets when is_map(budgets) -> budgets
        _other -> %{}
      end

    Enum.find_value(budgets, fn {key, budget} -> if to_string(key) == level, do: budget end) ||
      Map.get(@thinking_budgets, level, max_tokens - 1)
  end

  defp temperature(opts, thinking) do
    case Keyword.get(opts, :temperature) do
      nil -> nil
      _temp when map_size(thinking) > 0 -> nil
      temp -> temp
    end
  end

  defp top_p(opts, thinking) do
    case Keyword.get(opts, :top_p) do
      nil -> nil
      _value when map_size(thinking) > 0 -> nil
      value -> value
    end
  end

  defp stop_sequences(opts) do
    case Keyword.get(opts, :stop) do
      nil -> nil
      stop when is_list(stop) and stop != [] -> stop
      stop when is_binary(stop) -> [stop]
      _other -> nil
    end
  end

  defp tool_choice(opts, tools) do
    case Keyword.fetch(opts, :tool_choice) do
      {:ok, choice} -> normalize_tool_choice(choice)
      :error when tools != [] -> %{"type" => "auto"}
      :error -> nil
    end
  end

  defp normalize_tool_choice(choice) when choice in ["auto", :auto], do: %{"type" => "auto"}

  defp normalize_tool_choice(choice) when choice in ["any", "required", :any, :required],
    do: %{"type" => "any"}

  defp normalize_tool_choice(%{"type" => _type} = choice), do: choice
  defp normalize_tool_choice(%{"name" => name}), do: %{"type" => "tool", "name" => name}

  defp normalize_tool_choice(%{type: type} = choice) do
    choice
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("type", to_string(type))
  end

  defp normalize_tool_choice(_choice), do: nil

  defp default_max_tokens(model) do
    case Map.get(@model_info, model) do
      {_context_window, max_output_tokens, _pricing} -> div(max_output_tokens, 3)
      nil -> 8_192
    end
  end

  # An explicit API key wins, then stored OAuth credentials, then the API key
  # lookup every adapter shares (store, then environment).
  defp resolve_auth(opts) do
    with false <- explicit_api_key?(opts),
         {:ok, credentials, handle} <- stored_oauth(opts),
         {:ok, credentials} <- maybe_refresh(handle, credentials, nil, opts) do
      {:ok, oauth_auth(handle, credentials)}
    else
      true -> api_key_auth(opts)
      :none -> api_key_auth(opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp explicit_api_key?(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) -> String.trim(key) != ""
      _missing -> false
    end
  end

  # The stored credentials when they are an OAuth login, else `:none`.
  defp stored_oauth(opts) do
    with {:ok, handle} <- CredentialStore.from_opts(opts),
         {:ok, credentials} <- CredentialStore.fetch(handle, provider_id(opts)) do
      if OAuth.oauth_credentials?(credentials),
        do: {:ok, credentials, handle},
        else: :none
    else
      :error -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp api_key_auth(opts) do
    case Provider.api_key(opts, @adapter_id, @api_key_env) do
      {:ok, key} -> {:ok, %{type: :api_key, token: key}}
      :error -> {:error, {:missing_anthropic_credentials, provider_id(opts)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp oauth_auth(handle, credentials) do
    access_token = Map.get(credentials, "access_token") || Map.get(credentials, "access")

    %{type: :oauth, token: access_token, handle: handle, credentials: credentials}
  end

  defp maybe_refresh(handle, credentials, rejected_access_token, opts) do
    if refresh_required?(credentials, rejected_access_token, opts) do
      refresh_locked(handle, rejected_access_token, opts)
    else
      {:ok, credentials}
    end
  end

  # Refresh tokens rotate: a token spent by one process is invalid for every
  # other, and reusing it may revoke the login. The store's namespace lock
  # covers every process sharing the storage (such as several VMs sharing
  # auth.json), so only one refreshes; the others wait and then return what it
  # stored. The lock is per provider, so accounts refresh independently.
  defp refresh_locked(handle, rejected_access_token, opts) do
    CredentialStore.with_lock(handle, provider_id(opts), fn ->
      refresh_current(handle, rejected_access_token, opts)
    end)
  end

  defp refresh_current(handle, rejected_access_token, opts) do
    provider_id = provider_id(opts)

    with {:ok, current} <- fetch_credentials(handle, provider_id) do
      if refresh_required?(current, rejected_access_token, opts) do
        with {:ok, refreshed} <- OAuth.refresh(current, oauth_opts(opts)),
             :ok <- CredentialStore.put(handle, provider_id, refreshed) do
          {:ok, refreshed}
        end
      else
        {:ok, current}
      end
    end
  end

  defp refresh_required?(credentials, nil, opts),
    do: OAuth.expired?(credentials, oauth_opts(opts))

  defp refresh_required?(credentials, rejected_access_token, _opts) do
    current = Map.get(credentials, "access_token") || Map.get(credentials, "access")
    current == rejected_access_token
  end

  defp fetch_credentials(handle, provider_id) do
    case CredentialStore.fetch(handle, provider_id) do
      {:ok, credentials} -> {:ok, credentials}
      :error -> {:error, {:missing_anthropic_credentials, provider_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_id(opts), do: Provider.id(opts, @adapter_id)

  defp oauth_auth?(%{type: :oauth}), do: true
  defp oauth_auth?(_auth), do: false

  defp auth_mode(opts) do
    case Keyword.get(opts, :auth, :oauth) do
      :oauth -> {:ok, :oauth}
      :api_key -> {:ok, :api_key}
      "oauth" -> {:ok, :oauth}
      "api_key" -> {:ok, :api_key}
      other -> {:error, {:invalid_auth_mode, other}}
    end
  end

  defp api_key_login(interaction, _opts) do
    with {:ok, api_key} <-
           Interaction.prompt(interaction, label: "Anthropic API key", secret: true),
         {:ok, api_key} <- normalize_api_key(api_key) do
      {:ok, %{"type" => "api_key", "api_key" => api_key}}
    end
  end

  defp oauth_login(interaction, opts) do
    with {:ok, flow} <- OAuth.begin_authorization(opts) do
      Interaction.info(interaction, [
        "Open ",
        flow.url,
        " and sign in with your Claude Pro/Max account."
      ])

      Interaction.info(
        interaction,
        "After authorizing, paste the full callback URL or the code#state value."
      )

      case Interaction.prompt(interaction, label: "Authorization code", secret: true) do
        {:ok, input} -> OAuth.exchange_callback(flow, input, opts)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_api_key(api_key) when is_binary(api_key) do
    case String.trim(api_key) do
      "" -> {:error, :empty_api_key}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_api_key(_api_key), do: {:error, :invalid_api_key}

  defp interaction(opts) do
    case Keyword.fetch(opts, :interaction) do
      {:ok, {module, _reference} = handle} when is_atom(module) and not is_nil(module) ->
        {:ok, handle}

      _other ->
        {:error, :interaction_required}
    end
  end

  defp headers(opts, %{type: :oauth, token: token}) do
    [
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"anthropic-version", @anthropic_version},
      {"authorization", "Bearer #{token}"},
      {"anthropic-beta", Enum.join(@oauth_betas, ",")},
      {"user-agent", Prompt.user_agent(opts)},
      {"x-app", "cli"}
    ]
  end

  defp headers(_opts, %{type: :api_key, token: token}) do
    [
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"anthropic-version", @anthropic_version},
      {"x-api-key", token},
      {"anthropic-beta", Enum.join(@api_key_betas, ",")},
      {"user-agent", user_agent()}
    ]
  end

  defp messages_url(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) |> String.trim_trailing("/")

    if String.ends_with?(base_url, "/v1/messages"), do: base_url, else: base_url <> "/v1/messages"
  end

  defp oauth_opts(opts) do
    Keyword.take(opts, [
      :request,
      :token_url,
      :authorize_url,
      :client_id,
      :receive_timeout,
      :now,
      :sleep,
      :refresh_skew_ms,
      :expiry_margin_ms,
      :max_token_retries,
      :initial_retry_delay_ms,
      :max_retry_delay_ms,
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

  defp user_agent do
    version = Application.spec(:tackle_anthropic, :vsn) || ~c"0.1.0"
    "tackle-anthropic/#{List.to_string(version)}"
  end

  defp non_empty([]), do: nil
  defp non_empty(value), do: value
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
