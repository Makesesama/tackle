defmodule Tackle.Plugins.Anthropic.OAuth do
  @moduledoc """
  Anthropic Claude Pro/Max OAuth protocol helpers.

  This module owns the provider-specific protocol while leaving interaction to
  the frontend. A frontend opens the URL from `begin_authorization/1`, then
  passes the pasted callback URL (or `code#state` value) to
  `exchange_callback/3`. The default redirect URI is Anthropic's remote
  callback, so no local web server is required.

  Returned credentials are JSON-compatible maps suitable for a
  `Tackle.Lib.CredentialStore` under the provider's id, which is `"anthropic"`
  for the default provider.
  """

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.LLM.Error
  alias Tackle.Plugins.Anthropic.HTTP
  alias Tackle.Plugins.Anthropic.PKCE

  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @authorize_url "https://claude.ai/oauth/authorize"
  @token_url "https://platform.claude.com/v1/oauth/token"
  @default_redirect_uri "https://platform.claude.com/oauth/code/callback"

  @scopes [
    "org:create_api_key",
    "user:profile",
    "user:inference",
    "user:sessions:claude_code",
    "user:mcp_servers",
    "user:file_upload"
  ]

  @oauth_token_marker "sk-ant-oat"
  @max_token_retries 2
  @initial_retry_delay_ms 5_000
  @max_retry_delay_ms 30_000
  @expiry_margin_ms 300_000

  @type credentials :: %{required(String.t()) => String.t() | integer()}

  @type authorization :: %{
          required(:url) => String.t(),
          required(:state) => String.t(),
          required(:verifier) => String.t(),
          required(:redirect_uri) => String.t()
        }

  @doc "Returns true when an access token is a Claude Pro/Max OAuth token."
  @spec is_oauth_token(term()) :: boolean()
  def is_oauth_token(token) when is_binary(token),
    do: String.contains?(token, @oauth_token_marker)

  def is_oauth_token(_token), do: false

  @doc "Starts an authorization-code flow with PKCE and returns the URL to open."
  @spec begin_authorization(keyword()) :: {:ok, authorization()}
  def begin_authorization(opts \\ []) do
    %{verifier: verifier, challenge: challenge} = PKCE.generate()
    state = random_state()
    redirect_uri = Keyword.get(opts, :redirect_uri, @default_redirect_uri)

    query =
      URI.encode_query(%{
        "code" => "true",
        "client_id" => client_id(opts),
        "response_type" => "code",
        "redirect_uri" => redirect_uri,
        "scope" => Enum.join(@scopes, " "),
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state
      })

    {:ok,
     %{
       url: "#{authorize_url(opts)}?#{query}",
       state: state,
       verifier: verifier,
       redirect_uri: redirect_uri
     }}
  end

  @doc """
  Validates an OAuth callback input and exchanges its authorization code.

  `callback` may be the full redirect URL, a `code#state` value, or a raw query
  string.
  """
  @spec exchange_callback(authorization(), String.t() | map(), keyword()) ::
          {:ok, credentials()} | {:error, term()}
  def exchange_callback(flow, callback, opts \\ []) when is_map(flow) do
    with {:ok, %{code: code, state: state}} <- parse_callback(callback),
         :ok <- validate_state(state, flow[:state]),
         {:ok, verifier} <- required_string(flow, :verifier),
         {:ok, redirect_uri} <- required_string(flow, :redirect_uri) do
      exchange_code(code, state, verifier, redirect_uri, opts)
    end
  end

  @doc "Exchanges an authorization code and PKCE verifier for credentials."
  @spec exchange_code(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, credentials()} | {:error, term()}
  def exchange_code(code, state, verifier, redirect_uri, opts \\ [])
      when is_binary(code) and is_binary(state) and is_binary(verifier) and
             is_binary(redirect_uri) do
    body = %{
      "grant_type" => "authorization_code",
      "client_id" => client_id(opts),
      "code" => code,
      "state" => state,
      "redirect_uri" => redirect_uri,
      "code_verifier" => verifier
    }

    with {:ok, token} <- token_request(body, :exchange, opts) do
      credentials_from_token(token, nil, opts)
    end
  end

  @doc "Refreshes a stored OAuth credential, including refresh-token rotation."
  @spec refresh(map(), keyword()) :: {:ok, credentials()} | {:error, term()}
  def refresh(credentials, opts \\ []) when is_map(credentials) do
    with {:ok, refresh_token} <- credential_string(credentials, ["refresh_token"]) do
      body = %{
        "grant_type" => "refresh_token",
        "client_id" => client_id(opts),
        "refresh_token" => refresh_token
      }

      with {:ok, token} <- token_request(body, :refresh, opts) do
        credentials_from_token(token, refresh_token, opts)
      end
    end
  end

  @doc "Returns true when a credential should be refreshed before a request."
  @spec expired?(map(), keyword()) :: boolean()
  def expired?(credentials, opts \\ [])

  def expired?(credentials, opts) when is_map(credentials) do
    case credentials["expires_at"] || credentials["expires"] do
      expires_at when is_integer(expires_at) ->
        expires_at <= now_ms(opts) + Keyword.get(opts, :refresh_skew_ms, 0)

      _expires_at ->
        true
    end
  end

  def expired?(_credentials, _opts), do: true

  @doc false
  @spec access(map()) :: {:ok, %{access_token: String.t()}} | {:error, term()}
  def access(credentials) when is_map(credentials) do
    with {:ok, access_token} <- credential_string(credentials, ["access_token", "access"]) do
      {:ok, %{access_token: access_token}}
    end
  end

  @doc false
  @spec oauth_credentials?(map()) :: boolean()
  def oauth_credentials?(credentials) when is_map(credentials) do
    case credential_string(credentials, ["access_token", "access"]) do
      {:ok, _token} -> true
      _missing -> false
    end
  end

  def oauth_credentials?(_credentials), do: false

  @doc false
  @spec api_key(map()) :: {:ok, String.t()} | :error
  def api_key(credentials) when is_map(credentials) do
    case credential_string(credentials, ["api_key", "key"]) do
      {:ok, key} -> {:ok, key}
      _missing -> :error
    end
  end

  def api_key(_credentials), do: :error

  defp token_request(body, operation, opts) do
    request_options = [
      method: :post,
      url: token_url(opts),
      headers: [
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ],
      body: JSON.encode!(body),
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
    ]

    with :ok <- not_cancelled(opts),
         {:ok, response} <- request_with_retry(request_options, operation, opts, 0),
         {:ok, decoded} <- HTTP.decode_json(response.body) do
      {:ok, decoded}
    end
  end

  defp request_with_retry(request_options, operation, opts, attempt) do
    max_retries = Keyword.get(opts, :max_token_retries, @max_token_retries)

    with :ok <- not_cancelled(opts),
         {:ok, response} <- HTTP.request(request_options, opts) do
      if success?(response) do
        {:ok, response}
      else
        maybe_retry(request_options, response, operation, opts, attempt, max_retries)
      end
    end
  end

  defp maybe_retry(request_options, response, operation, opts, attempt, max_retries) do
    status = Map.get(response, :status)
    should_retry = HTTP.header(response, "x-should-retry")

    retryable? = status == 429 or (is_integer(status) and status >= 500)

    if retryable? and should_retry != "false" and attempt < max_retries do
      sleep(opts, retry_delay(response, opts, attempt))
      request_with_retry(request_options, operation, opts, attempt + 1)
    else
      {:error,
       {:token_request_failed, operation, status, HTTP.error_body(Map.get(response, :body))}}
    end
  end

  defp retry_delay(response, opts, attempt) do
    case Error.retry_after_ms(Map.get(response, :headers) || %{}) do
      ms when is_integer(ms) ->
        min(ms, Keyword.get(opts, :max_retry_delay_ms, @max_retry_delay_ms))

      nil ->
        backoff(opts, attempt)
    end
  end

  defp backoff(opts, attempt) do
    Keyword.get(opts, :initial_retry_delay_ms, @initial_retry_delay_ms) * Integer.pow(2, attempt)
  end

  defp credentials_from_token(token, fallback_refresh_token, opts) do
    with {:ok, access_token} <- required_string(token, "access_token"),
         {:ok, expires_in} <- positive_integer(Map.get(token, "expires_in")) do
      refresh_token =
        case Map.get(token, "refresh_token") do
          value when is_binary(value) and value != "" -> value
          _missing -> fallback_refresh_token
        end

      if is_binary(refresh_token) and refresh_token != "" do
        margin = Keyword.get(opts, :expiry_margin_ms, @expiry_margin_ms)

        {:ok,
         %{
           "type" => "oauth",
           "access_token" => access_token,
           "refresh_token" => refresh_token,
           "expires_at" => now_ms(opts) + expires_in * 1_000 - margin
         }}
      else
        {:error, :missing_refresh_token}
      end
    end
  end

  defp parse_callback(%{} = params) do
    with {:ok, code} <- required_string(params, "code"),
         {:ok, state} <- required_string(params, "state") do
      {:ok, %{code: code, state: state}}
    end
  end

  defp parse_callback(input) when is_binary(input) do
    case String.trim(input) do
      "" ->
        {:error, :invalid_oauth_callback}

      text ->
        from_url(text) || from_fragment(text) || from_query(text) ||
          {:error, :invalid_oauth_callback}
    end
  end

  defp parse_callback(_input), do: {:error, :invalid_oauth_callback}

  defp from_url(text) do
    case URI.parse(text) do
      %URI{query: query} when is_binary(query) ->
        from_query(query)

      _uri ->
        nil
    end
  end

  defp from_fragment(text) do
    case String.split(text, "#", parts: 2) do
      [code, state] when code != "" and state != "" -> {:ok, %{code: code, state: state}}
      _parts -> nil
    end
  end

  defp from_query(query) do
    case URI.decode_query(query) do
      %{"code" => code, "state" => state} when code != "" and state != "" ->
        {:ok, %{code: code, state: state}}

      _params ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp validate_state(state, expected) do
    if is_binary(expected) and state == expected,
      do: :ok,
      else: {:error, :oauth_state_mismatch}
  end

  defp success?(%{status: status}) when is_integer(status), do: status in 200..299
  defp success?(_response), do: false

  defp required_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing_field, key}}
    end
  end

  defp required_string(_map, key), do: {:error, {:missing_field, key}}

  defp credential_string(credentials, keys) do
    case Enum.find_value(keys, fn key -> Map.get(credentials, key) end) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :missing_credential}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_expires_in}

  defp not_cancelled(opts) do
    if Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal)),
      do: {:error, :cancelled},
      else: :ok
  end

  defp authorize_url(opts), do: Keyword.get(opts, :authorize_url, @authorize_url)
  defp token_url(opts), do: Keyword.get(opts, :token_url, @token_url)
  defp client_id(opts), do: Keyword.get(opts, :client_id, @client_id)

  defp random_state do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp now_ms(opts) do
    case Keyword.get(opts, :now) do
      fun when is_function(fun, 0) -> fun.()
      ms when is_integer(ms) -> ms
      _missing -> System.system_time(:millisecond)
    end
  end

  defp sleep(opts, ms) do
    case Keyword.get(opts, :sleep) do
      fun when is_function(fun, 1) -> fun.(ms)
      _missing -> Process.sleep(ms)
    end
  end
end
