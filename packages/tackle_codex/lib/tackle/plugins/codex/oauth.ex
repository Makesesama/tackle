defmodule Tackle.Plugins.Codex.OAuth do
  @moduledoc """
  OpenAI Codex OAuth protocol helpers.

  This module owns the provider-specific protocol while leaving interaction to
  the frontend. A frontend can either present the device-code flow with
  `request_device_code/1` and `complete_device_code/2`, or open the URL returned
  by `begin_authorization/1` and pass the callback URL to `exchange_callback/3`.

  Returned credentials are JSON-compatible maps suitable for a
  `Tackle.Lib.CredentialStore` under the `"openai-codex"` namespace.
  """

  alias Tackle.Lib.Cancellation
  alias Tackle.Plugins.Codex.HTTP
  alias Tackle.Plugins.Codex.PKCE

  @default_auth_base_url "https://auth.openai.com"
  @default_client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @default_redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid profile email offline_access"
  @device_timeout_ms 15 * 60 * 1_000
  @refresh_skew_ms 60_000

  @type credentials :: %{
          required(String.t()) => String.t() | integer()
        }

  @type authorization :: %{
          required(:url) => String.t(),
          required(:state) => String.t(),
          required(:verifier) => String.t(),
          required(:redirect_uri) => String.t()
        }

  @type device_code :: %{
          required(:device_auth_id) => String.t(),
          required(:user_code) => String.t(),
          required(:verification_uri) => String.t(),
          required(:redirect_uri) => String.t(),
          required(:interval_ms) => pos_integer(),
          required(:expires_at) => integer()
        }

  @doc "Starts an authorization-code flow with PKCE and returns the URL to open."
  @spec begin_authorization(keyword()) :: {:ok, authorization()}
  def begin_authorization(opts \\ []) do
    %{verifier: verifier, challenge: challenge} = PKCE.generate()
    state = random_url_token(16)
    redirect_uri = Keyword.get(opts, :redirect_uri, @default_redirect_uri)

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id(opts),
        "redirect_uri" => redirect_uri,
        "scope" => @scope,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "id_token_add_organizations" => "true",
        "codex_cli_simplified_flow" => "true",
        "originator" => Keyword.get(opts, :originator, "tackle")
      })

    {:ok,
     %{
       url: "#{auth_base_url(opts)}/oauth/authorize?#{query}",
       state: state,
       verifier: verifier,
       redirect_uri: redirect_uri
     }}
  end

  @doc "Validates an OAuth callback and exchanges its authorization code."
  @spec exchange_callback(authorization(), String.t() | map(), keyword()) ::
          {:ok, credentials()} | {:error, term()}
  def exchange_callback(flow, callback, opts \\ []) when is_map(flow) do
    with {:ok, params} <- callback_params(callback),
         :ok <- validate_callback_error(params),
         :ok <- validate_state(params["state"], flow[:state]),
         {:ok, code} <- required_string(params, "code"),
         {:ok, verifier} <- required_atom_string(flow, :verifier),
         {:ok, redirect_uri} <- required_atom_string(flow, :redirect_uri) do
      exchange_code(code, verifier, redirect_uri, opts)
    end
  end

  @doc "Exchanges an authorization code and PKCE verifier for stored credentials."
  @spec exchange_code(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, credentials()} | {:error, term()}
  def exchange_code(code, verifier, redirect_uri, opts \\ [])
      when is_binary(code) and is_binary(verifier) and is_binary(redirect_uri) do
    form = [
      grant_type: "authorization_code",
      client_id: client_id(opts),
      code: code,
      code_verifier: verifier,
      redirect_uri: redirect_uri
    ]

    with {:ok, token} <- token_request(form, :exchange, opts) do
      credentials_from_token(token, nil, opts)
    end
  end

  @doc "Requests a user code for OpenAI's headless Codex login flow."
  @spec request_device_code(keyword()) :: {:ok, device_code()} | {:error, term()}
  def request_device_code(opts \\ []) do
    url = "#{auth_base_url(opts)}/api/accounts/deviceauth/usercode"

    request_options =
      base_request_options(opts) ++
        [
          method: :post,
          url: url,
          headers: [{"content-type", "application/json"}],
          body: JSON.encode!(%{"client_id" => client_id(opts)})
        ]

    with :ok <- not_cancelled(opts),
         {:ok, response} <- HTTP.request(request_options, opts),
         :ok <- device_code_status(response),
         {:ok, body} <- HTTP.decode_json(response.body),
         {:ok, device_auth_id} <- required_string(body, "device_auth_id"),
         {:ok, user_code} <- required_string(body, "user_code"),
         {:ok, interval_ms} <- interval_ms(body["interval"]) do
      {:ok,
       %{
         device_auth_id: device_auth_id,
         user_code: user_code,
         verification_uri: "#{auth_base_url(opts)}/codex/device",
         redirect_uri: "#{auth_base_url(opts)}/deviceauth/callback",
         interval_ms: interval_ms,
         expires_at: now_ms(opts) + Keyword.get(opts, :device_timeout_ms, @device_timeout_ms)
       }}
    end
  rescue
    exception -> {:error, {:device_code_request_failed, Exception.message(exception)}}
  end

  @doc "Polls a requested device-code flow until authorization completes or expires."
  @spec complete_device_code(device_code(), keyword()) ::
          {:ok, credentials()} | {:error, term()}
  def complete_device_code(device, opts \\ []) when is_map(device) do
    with :ok <- validate_device(device),
         {:ok, code, verifier} <- poll_device_code(device, device.interval_ms, opts) do
      exchange_code(code, verifier, device.redirect_uri, opts)
    end
  end

  @doc "Refreshes a stored OAuth credential, including refresh-token rotation."
  @spec refresh(map(), keyword()) :: {:ok, credentials()} | {:error, term()}
  def refresh(credentials, opts \\ []) when is_map(credentials) do
    with {:ok, refresh_token} <- credential_string(credentials, "refresh_token"),
         {:ok, token} <-
           token_request(
             [
               grant_type: "refresh_token",
               refresh_token: refresh_token,
               client_id: client_id(opts)
             ],
             :refresh,
             opts
           ) do
      credentials_from_token(token, refresh_token, opts)
    end
  end

  @doc "Returns true when a credential should be refreshed before a request."
  @spec expired?(map(), keyword()) :: boolean()
  def expired?(credentials, opts \\ [])

  def expired?(credentials, opts) when is_map(credentials) do
    case credentials["expires_at"] || credentials["expires"] do
      expires_at when is_integer(expires_at) ->
        expires_at <= now_ms(opts) + Keyword.get(opts, :refresh_skew_ms, @refresh_skew_ms)

      _expires_at ->
        true
    end
  end

  def expired?(_credentials, _opts), do: true

  @doc false
  @spec access(map()) ::
          {:ok, %{access_token: String.t(), account_id: String.t()}} | {:error, term()}
  def access(credentials) when is_map(credentials) do
    with {:ok, access_token} <- credential_string(credentials, "access_token"),
         {:ok, account_id} <- credential_string(credentials, "account_id") do
      {:ok, %{access_token: access_token, account_id: account_id}}
    end
  end

  defp token_request(form, operation, opts) do
    request_options =
      base_request_options(opts) ++
        [
          method: :post,
          url: "#{auth_base_url(opts)}/oauth/token",
          form: form
        ]

    with :ok <- not_cancelled(opts),
         {:ok, response} <- HTTP.request(request_options, opts),
         :ok <- success_status(response, {:token_request_failed, operation}),
         {:ok, body} <- HTTP.decode_json(response.body),
         {:ok, access_token} <- required_string(body, "access_token"),
         {:ok, expires_in} <- positive_integer(body["expires_in"]) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: body["refresh_token"],
         expires_in: expires_in
       }}
    end
  end

  defp credentials_from_token(token, fallback_refresh_token, opts) do
    refresh_token = token.refresh_token || fallback_refresh_token

    with true <-
           (is_binary(refresh_token) and refresh_token != "") || {:error, :missing_refresh_token},
         {:ok, account_id} <- account_id(token.access_token) do
      {:ok,
       %{
         "type" => "oauth",
         "access_token" => token.access_token,
         "refresh_token" => refresh_token,
         "expires_at" => now_ms(opts) + token.expires_in * 1_000,
         "account_id" => account_id
       }}
    end
  end

  defp account_id(access_token) do
    with [_header, payload, _signature] <- String.split(access_token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- JSON.decode(decoded),
         account_id when is_binary(account_id) and account_id != "" <-
           get_in(claims, ["https://api.openai.com/auth", "chatgpt_account_id"]) do
      {:ok, account_id}
    else
      _reason -> {:error, :missing_chatgpt_account_id}
    end
  end

  defp poll_device_code(device, interval_ms, opts) do
    cond do
      cancelled?(opts) ->
        {:error, :cancelled}

      now_ms(opts) >= device.expires_at ->
        {:error, :device_code_expired}

      true ->
        case poll_device_once(device, opts) do
          {:ok, code, verifier} ->
            {:ok, code, verifier}

          :pending ->
            sleep(interval_ms, opts)
            poll_device_code(device, interval_ms, opts)

          :slow_down ->
            next_interval = interval_ms + 5_000
            sleep(next_interval, opts)
            poll_device_code(device, next_interval, opts)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp poll_device_once(device, opts) do
    url = "#{auth_base_url(opts)}/api/accounts/deviceauth/token"

    request_options =
      base_request_options(opts) ++
        [
          method: :post,
          url: url,
          headers: [{"content-type", "application/json"}],
          body:
            JSON.encode!(%{
              "device_auth_id" => device.device_auth_id,
              "user_code" => device.user_code
            })
        ]

    with {:ok, response} <- HTTP.request(request_options, opts) do
      poll_response(response)
    end
  end

  defp poll_response(%{status: status, body: body}) when status in 200..299 do
    with {:ok, decoded} <- HTTP.decode_json(body),
         {:ok, code} <- required_string(decoded, "authorization_code"),
         {:ok, verifier} <- required_string(decoded, "code_verifier") do
      {:ok, code, verifier}
    end
  end

  defp poll_response(%{status: status}) when status in [403, 404], do: :pending

  defp poll_response(%{status: status, body: body}) do
    case oauth_error_code(body) do
      "deviceauth_authorization_pending" -> :pending
      "authorization_pending" -> :pending
      "slow_down" -> :slow_down
      "expired_token" -> {:error, :device_code_expired}
      code -> {:error, {:device_code_poll_failed, status, code || HTTP.error_body(body)}}
    end
  end

  defp oauth_error_code(body) do
    case HTTP.decode_json(body) do
      {:ok, %{"error" => %{"code" => code}}} when is_binary(code) -> code
      {:ok, %{"error" => code}} when is_binary(code) -> code
      _other -> nil
    end
  end

  defp callback_params(%{} = params), do: {:ok, stringify_keys(params)}

  defp callback_params(callback) when is_binary(callback) do
    query = URI.parse(callback).query || callback

    try do
      {:ok, URI.decode_query(query)}
    rescue
      ArgumentError -> {:error, :invalid_oauth_callback}
    end
  end

  defp callback_params(_callback), do: {:error, :invalid_oauth_callback}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp validate_callback_error(%{"error" => error} = params) when is_binary(error) do
    {:error, {:oauth_callback_error, error, params["error_description"]}}
  end

  defp validate_callback_error(_params), do: :ok

  defp validate_state(state, state) when is_binary(state) and state != "", do: :ok
  defp validate_state(_actual, _expected), do: {:error, :oauth_state_mismatch}

  defp validate_device(device) do
    required = [:device_auth_id, :user_code, :redirect_uri, :interval_ms, :expires_at]

    if Enum.all?(required, &Map.has_key?(device, &1)) and
         is_integer(device.interval_ms) and device.interval_ms > 0 and
         is_integer(device.expires_at) do
      :ok
    else
      {:error, :invalid_device_code}
    end
  end

  defp device_code_status(%{status: 404}), do: {:error, :device_code_not_enabled}
  defp device_code_status(response), do: success_status(response, :device_code_request_failed)

  defp success_status(%{status: status}, _error) when status in 200..299, do: :ok

  defp success_status(%{status: status, body: body}, error),
    do: {:error, {error, status, HTTP.error_body(body)}}

  defp interval_ms(value) when is_integer(value) and value >= 0,
    do: {:ok, max(1_000, value * 1_000)}

  defp interval_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> {:ok, max(1_000, seconds * 1_000)}
      _result -> {:error, :invalid_device_poll_interval}
    end
  end

  defp interval_ms(_value), do: {:error, :invalid_device_poll_interval}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(value) when is_float(value) and value > 0, do: {:ok, trunc(value)}
  defp positive_integer(_value), do: {:error, :invalid_token_expiry}

  defp required_string(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_field, key}}
    end
  end

  defp required_atom_string(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_field, key}}
    end
  end

  defp credential_string(credentials, key) do
    fallback_key =
      case key do
        "access_token" -> "access"
        "refresh_token" -> "refresh"
        "account_id" -> "accountId"
      end

    case credentials[key] || credentials[fallback_key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_credentials, key}}
    end
  end

  defp auth_base_url(opts) do
    opts
    |> Keyword.get(:auth_base_url, @default_auth_base_url)
    |> String.trim_trailing("/")
  end

  defp client_id(opts), do: Keyword.get(opts, :client_id, @default_client_id)

  defp base_request_options(opts) do
    [
      decode_body: false,
      retry: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
    ]
  end

  defp now_ms(opts) do
    case Keyword.get(opts, :now) do
      fun when is_function(fun, 0) -> fun.()
      value when is_integer(value) -> value
      nil -> System.system_time(:millisecond)
    end
  end

  defp sleep(milliseconds, opts) do
    case Keyword.get(opts, :sleep) do
      fun when is_function(fun, 1) -> fun.(milliseconds)
      nil -> Process.sleep(milliseconds)
    end
  end

  defp cancelled?(opts) do
    Cancellation.cancelled?(Keyword.get(opts, :cancellation_signal))
  end

  defp not_cancelled(opts) do
    if cancelled?(opts), do: {:error, :cancelled}, else: :ok
  end

  defp random_url_token(bytes) do
    bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
