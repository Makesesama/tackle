defmodule Tackle.Plugins.MCP.OAuth do
  @moduledoc """
  Functional OAuth helper for MCP Streamable HTTP authorization (MCP 2025-11).

  `begin/2` returns the authorization URL and PKCE/state values; the host owns
  the browser and loopback callback. `complete/3` exchanges the callback code
  and returns credentials suitable for host persistence. No credentials are
  persisted by this module.
  """

  @type request_fun :: (atom(), String.t(), [{String.t(), String.t()}], binary(), keyword() ->
                          term())

  @doc "Discovers metadata and creates a PKCE authorization request."
  @spec begin(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def begin(resource_url, opts \\ [])

  def begin(resource_url, opts) when is_binary(resource_url) do
    with {:ok, resource} <- validate_url(resource_url),
         opts <- Keyword.put(opts, :resource_url, resource),
         {:ok, req} <- requester(opts),
         {:ok, redirect_uri} <- validate_redirect(Keyword.fetch!(opts, :redirect_uri)),
         {:ok, resource_metadata} <- resource_metadata(resource, opts, req),
         {:ok, auth_metadata} <- auth_metadata(resource_metadata, opts, req),
         :ok <- validate_auth_metadata(auth_metadata, Keyword.put(opts, :resource_url, resource)),
         {:ok, client_id, client_secret} <-
           client_credentials(auth_metadata, Keyword.put(opts, :resource_url, resource), req),
         {:ok, verifier, challenge} <- pkce(),
         state <- random_token(32),
         authorization_url <-
           authorization_url(
             auth_metadata,
             client_id,
             redirect_uri,
             resource,
             state,
             challenge,
             Keyword.put_new(opts, :scope, scopes(resource_metadata))
           ) do
      {:ok,
       %{
         authorization_url: authorization_url,
         state: state,
         code_verifier: verifier,
         client_id: client_id,
         client_secret: client_secret,
         redirect_uri: redirect_uri,
         resource: resource,
         token_endpoint: auth_metadata["token_endpoint"],
         scope: Keyword.get(opts, :scope, scopes(resource_metadata)),
         request: req
       }}
    end
  rescue
    KeyError -> {:error, :missing_redirect_uri}
    exception -> {:error, {:oauth_error, Exception.message(exception)}}
  end

  def begin(_, _), do: {:error, :invalid_resource_url}

  @doc "Validates callback state and exchanges its authorization code for credentials."
  @spec complete(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete(flow, callback_state, opts \\ [])

  def complete(%{state: expected} = flow, callback_state, opts) do
    cond do
      not is_binary(callback_state) or not secure_equal(expected, callback_state) ->
        {:error, :state_mismatch}

      true ->
        exchange(flow, Keyword.get(opts, :code))
    end
  end

  def complete(_, _, _), do: {:error, :invalid_oauth_flow}

  @doc "Refreshes an OAuth credential map; returns a new map without mutating the input."
  @spec refresh(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh(credentials, opts \\ [])

  def refresh(
        %{refresh_token: token, token_endpoint: endpoint, client_id: id} = credentials,
        opts
      ) do
    with {:ok, endpoint} <- validate_url(endpoint),
         :ok <- reject_remote_loopback(endpoint, resource_url: credentials[:resource]),
         {:ok, req} <- requester(opts),
         {:ok, result} <-
           token_request(
             req,
             endpoint,
             %{
               "grant_type" => "refresh_token",
               "refresh_token" => token,
               "client_id" => id,
               "resource" => credentials[:resource]
             },
             credentials[:client_secret]
           ),
         {:ok, fields} <- token_fields(result) do
      {:ok, credentials |> Map.merge(fields) |> Map.put(:token_endpoint, endpoint)}
    end
  end

  def refresh(_, _), do: {:error, :missing_refresh_token}

  @doc "Refreshes a persisted string-keyed credential map."
  def refresh_stored(
        %{
          "refresh_token" => token,
          "token_endpoint" => endpoint,
          "client_id" => id,
          "resource" => resource
        } = credentials,
        opts
      ) do
    with {:ok, endpoint} <- validate_url(endpoint),
         :ok <- reject_remote_loopback(endpoint, resource_url: resource),
         {:ok, req} <- requester(opts),
         {:ok, response} <-
           token_request(
             req,
             endpoint,
             %{
               "grant_type" => "refresh_token",
               "refresh_token" => token,
               "client_id" => id,
               "resource" => resource
             },
             credentials["client_secret"]
           ),
         {:ok, fields} <- token_fields(response) do
      {:ok,
       Map.merge(credentials, Map.new(fields, fn {key, value} -> {to_string(key), value} end))}
    end
  end

  def refresh_stored(_, _), do: {:error, :missing_refresh_token}

  defp validate_auth_metadata(metadata, opts) do
    with {:ok, authorization} <- validate_url(metadata["authorization_endpoint"]),
         {:ok, token} <- validate_url(metadata["token_endpoint"]),
         :ok <- reject_remote_loopback(authorization, opts),
         :ok <- reject_remote_loopback(token, opts) do
      :ok
    end
  end

  defp reject_remote_loopback(url, opts) do
    uri = URI.parse(url)
    resource = URI.parse(Keyword.get(opts, :resource_url, ""))

    if uri.host in ["localhost", "127.0.0.1", "::1"] and uri.host != resource.host,
      do: {:error, :untrusted_loopback_oauth_server},
      else: :ok
  end

  defp scopes(%{"challenge_scope" => scope}) when is_binary(scope), do: scope
  defp scopes(%{"scopes_supported" => scopes}) when is_list(scopes), do: Enum.join(scopes, " ")
  defp scopes(_), do: nil

  defp exchange(flow, code) when is_binary(code) and code != "" do
    with {:ok, endpoint} <- validate_url(flow.token_endpoint),
         :ok <- reject_remote_loopback(endpoint, resource_url: flow.resource),
         {:ok, req} <- requester_from_flow(flow),
         params <- %{
           "grant_type" => "authorization_code",
           "code" => code,
           "redirect_uri" => flow.redirect_uri,
           "client_id" => flow.client_id,
           "code_verifier" => flow.code_verifier,
           "resource" => flow.resource
         },
         {:ok, result} <- token_request(req, endpoint, params, flow.client_secret),
         {:ok, fields} <- token_fields(result) do
      {:ok,
       fields
       |> Map.merge(%{
         client_id: flow.client_id,
         client_secret: flow.client_secret,
         token_endpoint: endpoint,
         resource: flow.resource
       })}
    end
  end

  defp exchange(_, _), do: {:error, :missing_authorization_code}

  defp resource_metadata(resource, _opts, req) do
    case fetch_challenge(req, resource) do
      {:ok, url, scope} ->
        with {:ok, url} <- validate_metadata_url(url, resource),
             {:ok, metadata} <- fetch_json(req, url),
             do: {:ok, Map.put(metadata, "challenge_scope", scope)}

      _ ->
        fetch_resource_well_known(req, resource)
    end
  end

  defp fetch_resource_well_known(req, resource) do
    uri = URI.parse(resource)
    paths = [uri.path || "", ""] |> Enum.uniq()

    Enum.reduce_while(paths, {:error, :metadata_request_failed}, fn path, _ ->
      url =
        URI.to_string(%{
          uri
          | path: "/.well-known/oauth-protected-resource" <> path,
            query: nil,
            fragment: nil
        })

      case fetch_json(req, url) do
        {:ok, metadata} -> {:halt, {:ok, metadata}}
        error -> {:cont, error}
      end
    end)
  end

  defp fetch_challenge(req, resource) do
    case req.(:get, resource, [], "", []) do
      {:ok, %{status: 401, headers: headers}} ->
        value =
          Enum.find_value(headers, fn {key, value} ->
            if String.downcase(key) == "www-authenticate", do: value
          end)

        with value when is_binary(value) <- value,
             [url] <- Regex.run(~r/resource_metadata="([^"]+)"/, value, capture: :all_but_first) do
          scope =
            case Regex.run(~r/scope="([^"]+)"/, value, capture: :all_but_first) do
              [scope] -> scope
              _ -> nil
            end

          {:ok, url, scope}
        else
          _ -> {:error, :missing_www_authenticate}
        end

      _ ->
        {:error, :no_challenge}
    end
  end

  defp validate_metadata_url(url, resource) do
    with {:ok, url} <- validate_url(url),
         true <- URI.parse(url).host == URI.parse(resource).host do
      {:ok, url}
    else
      _ -> {:error, :untrusted_resource_metadata_url}
    end
  end

  defp auth_metadata(%{"authorization_servers" => [auth | _]}, opts, req) do
    with {:ok, auth} <- validate_url(auth),
         :ok <- reject_remote_loopback(auth, opts) do
      metadata =
        Keyword.get(
          opts,
          :authorization_metadata_url,
          metadata_url(auth, ".well-known/oauth-authorization-server")
        )

      case fetch_json(req, metadata) do
        {:ok, m} -> {:ok, m}
        _ -> fetch_json(req, metadata_url(auth, ".well-known/openid-configuration"))
      end
    end
  end

  defp auth_metadata(_, _, _), do: {:error, :missing_authorization_server}

  defp client_credentials(metadata, opts, req) do
    case Keyword.get(opts, :client_id) do
      id when is_binary(id) and id != "" ->
        {:ok, id, Keyword.get(opts, :client_secret)}

      _ ->
        with endpoint when is_binary(endpoint) <- metadata["registration_endpoint"],
             {:ok, endpoint} <- validate_url(endpoint),
             :ok <- reject_remote_loopback(endpoint, opts),
             {:ok, response} <-
               json_request(req, :post, endpoint, %{
                 "client_name" => Keyword.get(opts, :client_name, "Tackle MCP"),
                 "redirect_uris" => [Keyword.fetch!(opts, :redirect_uri)],
                 "grant_types" => ["authorization_code", "refresh_token"],
                 "response_types" => ["code"],
                 "token_endpoint_auth_method" => "none"
               }),
             id when is_binary(id) <- response["client_id"] do
          {:ok, id, response["client_secret"]}
        else
          _ -> {:error, :client_registration_unavailable}
        end
    end
  end

  defp authorization_url(metadata, client, redirect, resource, state, challenge, opts) do
    uri = URI.parse(metadata["authorization_endpoint"])

    params =
      [
        {"response_type", "code"},
        {"client_id", client},
        {"redirect_uri", redirect},
        {"state", state},
        {"code_challenge", challenge},
        {"code_challenge_method", "S256"},
        {"resource", resource}
      ]
      |> maybe_scope(Keyword.get(opts, :scope))

    query = URI.decode_query(uri.query || "") |> Map.merge(Map.new(params)) |> URI.encode_query()
    URI.to_string(%{uri | query: query})
  end

  defp token_request(req, endpoint, params, secret) do
    params = Map.reject(params, fn {_key, value} -> is_nil(value) end)
    params = if secret, do: Map.put(params, "client_secret", secret), else: params
    body = URI.encode_query(params)

    case req.(:post, endpoint, [{"content-type", "application/x-www-form-urlencoded"}], body, []) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case JSON.decode(body) do
          {:ok, map} -> {:ok, map}
          _ -> {:error, :invalid_token_response}
        end

      {:ok, %{status: status}} ->
        {:error, {:token_request_failed, status}}

      {:error, reason} ->
        {:error, {:token_request_failed, reason}}
    end
  end

  defp token_fields(%{"access_token" => token} = response)
       when is_binary(token) and token != "" do
    ttl = response["expires_in"]
    token_type = response["token_type"]

    if (not is_nil(ttl) and (not is_integer(ttl) or ttl <= 0)) or
         (not is_nil(token_type) and
            (not is_binary(token_type) or String.downcase(token_type) != "bearer")) do
      {:error, :invalid_token_response}
    else
      fields = %{
        access_token: response["access_token"],
        token_type: response["token_type"],
        expires_in: response["expires_in"],
        refresh_token: response["refresh_token"],
        scope: response["scope"]
      }

      {:ok,
       Map.reject(fields, fn {_k, v} -> is_nil(v) end)
       |> Map.put(:expires_at, if(ttl, do: System.system_time(:second) + ttl, else: nil))}
    end
  end

  defp token_fields(_), do: {:error, :invalid_token_response}

  defp fetch_json(req, url) do
    with {:ok, url} <- validate_url(url),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           req.(:get, url, [], "", []),
         {:ok, data} when is_map(data) <- JSON.decode(body) do
      {:ok, data}
    else
      _ -> {:error, :metadata_request_failed}
    end
  end

  defp json_request(req, method, url, data) do
    case req.(method, url, [{"content-type", "application/json"}], JSON.encode!(data), []) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> JSON.decode(body)
      _ -> {:error, :registration_failed}
    end
  end

  defp requester(opts) do
    case Keyword.get(opts, :request) do
      fun when is_function(fun, 5) ->
        {:ok, fun}

      nil ->
        finch = Keyword.get(opts, :finch_name)

        if finch,
          do: {:ok, &finch_request(&1, &2, &3, &4, &5, finch)},
          else: {:error, :missing_finch_name}

      _ ->
        {:error, :invalid_request_function}
    end
  end

  defp requester_from_flow(%{request: req}) when is_function(req, 5), do: {:ok, req}
  defp requester_from_flow(_), do: {:error, :missing_request_function}

  defp finch_request(method, url, headers, body, _opts, finch) do
    request = Finch.build(method, url, headers, body)

    case Finch.request(request, finch) do
      {:ok, response} ->
        {:ok, %{status: response.status, headers: response.headers, body: response.body}}

      error ->
        error
    end
  end

  defp validate_url(value) when is_binary(value) do
    uri = URI.parse(value)
    local = uri.host in ["localhost", "127.0.0.1", "::1"]

    if is_binary(uri.host) and uri.host != "" and
         (uri.scheme == "https" or (uri.scheme == "http" and local)) and
         is_nil(uri.userinfo) and is_nil(uri.fragment) and is_nil(uri.query),
       do: {:ok, URI.to_string(uri)},
       else: {:error, {:insecure_or_invalid_url, value}}
  end

  defp validate_url(_), do: {:error, :invalid_url}

  defp validate_redirect(value) do
    with {:ok, value} <- validate_url(value),
         true <- URI.parse(value).host in ["127.0.0.1", "::1", "localhost"] do
      {:ok, value}
    else
      _ -> {:error, :invalid_loopback_redirect}
    end
  end

  defp metadata_url(base, suffix) do
    uri = URI.parse(base)
    path = String.trim_trailing(uri.path || "", "/")
    URI.to_string(%{uri | path: "/" <> suffix <> path, query: nil, fragment: nil})
  end

  defp pkce do
    verifier = random_token(32)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, verifier, challenge}
  end

  defp random_token(bytes),
    do: :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)

  defp secure_equal(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_equal(_, _), do: false
  defp maybe_scope(params, nil), do: params
  defp maybe_scope(params, scope), do: params ++ [{"scope", scope}]
end
