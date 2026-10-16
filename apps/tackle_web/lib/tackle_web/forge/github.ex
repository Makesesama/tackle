defmodule Tackle.Web.Forge.GitHub do
  @moduledoc """
  `Tackle.Web.Forge` for GitHub, as a GitHub App (docs/TACKLE_WEB_PLAN.md
  §7.1).

  The app authenticates as itself with a JWT signed by its private key
  (RS256, valid for at most ten minutes), and as an installation with an
  installation access token from `POST /app/installations/{id}/access_tokens`,
  kept in memory by `Tackle.Web.Forge.GitHub.TokenCache` until shortly
  before it expires. Tokens never reach the database, the disk, or a jail.

  Configuration, under `config :tackle_web, Tackle.Web.Forge.GitHub`:
  `:api_url` (default `"https://api.github.com"`) and `:req_options`,
  extra `Req` options (tests route requests to `Req.Test` with them).
  """

  @behaviour Tackle.Web.Forge

  alias Tackle.Web.Forge.Event
  alias Tackle.Web.Forge.GitHub.TokenCache
  alias Tackle.Web.Forges.ForgeApp

  @api_version "2022-11-28"
  # GitHub accepts at most ten minutes; `iat` is backdated for clock skew.
  @jwt_backdate 60
  @jwt_lifetime 540
  # List reads: GitHub's largest page, and a bound on how many are read.
  @per_page 100
  @max_pages 100

  ## Webhooks

  @impl Tackle.Web.Forge
  def verify_webhook(raw_body, headers, %ForgeApp{} = forge_app) when is_binary(raw_body) do
    with {:ok, signature} <- header(headers, "x-hub-signature-256"),
         :ok <- check_signature(raw_body, signature, secret(forge_app, :webhook_secret)),
         {:ok, payload} <- decode(raw_body) do
      event = header_value(headers, "x-github-event")
      delivery_id = header_value(headers, "x-github-delivery")

      case parse_event(event, payload) do
        {:ok, %Event{} = parsed} -> {:ok, %{parsed | delivery_id: delivery_id}}
        :error -> {:error, :invalid_payload}
      end
    else
      :missing -> {:error, :invalid_signature}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_signature(raw_body, "sha256=" <> _hex = signature, secret) when is_binary(secret) do
    expected =
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw_body), case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp check_signature(_raw_body, _signature, _secret), do: {:error, :invalid_signature}

  defp decode(raw_body) do
    case JSON.decode(raw_body) do
      {:ok, %{} = payload} -> {:ok, payload}
      _other -> {:error, :invalid_payload}
    end
  end

  defp header(headers, name) do
    case header_value(headers, name) do
      nil -> :missing
      value -> {:ok, value}
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  @doc false
  # Public for tests: turns a decoded payload of one GitHub event type into
  # an event, or `:error` when the payload lacks what the type requires.
  @spec parse_event(String.t() | nil, map()) :: {:ok, Event.t()} | :error
  def parse_event("ping", _payload), do: {:ok, %Event{type: :ping}}

  def parse_event("installation", %{"action" => action, "installation" => installation} = payload) do
    with {:ok, action} <- installation_action(action),
         {:ok, installation} <- installation(installation),
         {:ok, repositories} <-
           repositories(Map.get(payload, "repositories") || [], installation.account) do
      {:ok,
       %Event{
         type: :installation,
         action: action,
         installation: installation,
         repositories: repositories
       }}
    else
      {:ignore, action} -> {:ok, ignored("installation #{action}")}
      :error -> :error
    end
  end

  def parse_event("installation_repositories", %{"action" => action} = payload)
      when action in ["added", "removed"] do
    key = "repositories_#{action}"

    with {:ok, installation} <- installation(payload["installation"]),
         {:ok, repositories} <- repositories(payload[key] || [], installation.account) do
      {:ok,
       %Event{
         type: if(action == "added", do: :repositories_added, else: :repositories_removed),
         installation: installation,
         repositories: repositories
       }}
    end
  end

  @pull_request_actions %{
    "opened" => :opened,
    "reopened" => :reopened,
    "ready_for_review" => :ready_for_review,
    "synchronize" => :synchronize,
    "closed" => :closed
  }

  def parse_event("pull_request", %{"action" => action} = payload) do
    case Map.fetch(@pull_request_actions, action) do
      {:ok, action} ->
        with {:ok, repository} <- repository(payload["repository"]),
             {:ok, installation} <- installation_of(payload["installation"], repository),
             {:ok, pull_request} <- pull_request_data(payload["pull_request"]) do
          {:ok,
           %Event{
             type: :pull_request,
             action: action,
             installation: installation,
             repository: repository,
             pull_request: pull_request,
             sender: get_in(payload, ["sender", "login"])
           }}
        end

      :error ->
        {:ok, ignored("pull_request #{action}")}
    end
  end

  # Comments in a pull request's conversation are issue comments. Edited and
  # deleted comments never start a review.
  def parse_event("issue_comment", %{"action" => "created", "issue" => issue} = payload) do
    if is_map(issue) and Map.has_key?(issue, "pull_request") do
      with {:ok, repository} <- repository(payload["repository"]),
           {:ok, installation} <- installation_of(payload["installation"], repository),
           {:ok, comment} <- comment(issue, payload["comment"]) do
        {:ok,
         %Event{
           type: :comment,
           installation: installation,
           repository: repository,
           comment: comment
         }}
      end
    else
      {:ok, ignored("comment on an issue")}
    end
  end

  def parse_event("issue_comment", %{"action" => action}),
    do: {:ok, ignored("issue_comment #{action}")}

  def parse_event(event, _payload), do: {:ok, ignored("event #{inspect(event)}")}

  defp ignored(reason), do: %Event{type: :ignored, reason: reason}

  defp installation_action("created"), do: {:ok, :created}
  defp installation_action("deleted"), do: {:ok, :deleted}
  defp installation_action("suspend"), do: {:ok, :suspended}
  defp installation_action("unsuspend"), do: {:ok, :unsuspended}
  defp installation_action(other), do: {:ignore, other}

  defp installation(%{"id" => id, "account" => %{"login" => login}})
       when is_integer(id) and is_binary(login),
       do: {:ok, %{external_id: Integer.to_string(id), account: login}}

  defp installation(_other), do: :error

  # Events about a repository carry only the installation's id. A GitHub
  # App installation belongs to one account, which owns every repository it
  # covers, so the repository's owner is the installation's account.
  defp installation_of(%{"id" => id}, %{owner: owner}) when is_integer(id),
    do: {:ok, %{external_id: Integer.to_string(id), account: owner}}

  defp installation_of(_other, _repository), do: :error

  defp repository(%{"id" => id, "name" => name, "owner" => %{"login" => owner}})
       when is_integer(id) and is_binary(name) and is_binary(owner),
       do: {:ok, %{external_id: Integer.to_string(id), owner: owner, name: name}}

  defp repository(_other), do: :error

  # Installation events list repositories as `id`, `name`, and `full_name`.
  defp repositories(list, account) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"id" => id, "name" => name} = repo, {:ok, acc} when is_integer(id) and is_binary(name) ->
        owner =
          case repo["full_name"] do
            full_name when is_binary(full_name) -> full_name |> String.split("/") |> hd()
            _none -> account
          end

        {:cont, {:ok, [%{external_id: Integer.to_string(id), owner: owner, name: name} | acc]}}

      _invalid, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, repositories} -> {:ok, Enum.reverse(repositories)}
      :error -> :error
    end
  end

  defp repositories(_other, _account), do: :error

  defp pull_request_data(
         %{
           "number" => number,
           "state" => state,
           "head" => %{"sha" => head_sha} = head,
           "base" => %{"sha" => base_sha, "ref" => base_ref} = base
         } = pull_request
       )
       when is_integer(number) and number > 0 and state in ["open", "closed"] and
              is_binary(head_sha) and is_binary(base_sha) and is_binary(base_ref) do
    {:ok,
     %{
       number: number,
       state: String.to_existing_atom(state),
       draft: pull_request["draft"] == true,
       head_sha: head_sha,
       base_sha: base_sha,
       base_ref: base_ref,
       head_is_fork: fork?(head, base),
       author: get_in(pull_request, ["user", "login"])
     }}
  end

  defp pull_request_data(_other), do: :error

  # A head repository that no longer exists (a deleted fork) is a fork too.
  defp fork?(%{"repo" => %{"id" => head_id}}, %{"repo" => %{"id" => base_id}}),
    do: head_id != base_id

  defp fork?(_head, _base), do: true

  defp comment(%{"number" => number}, %{"body" => body, "user" => %{"login" => login} = user})
       when is_integer(number) and is_binary(body) and is_binary(login) do
    {:ok,
     %{
       pull_number: number,
       body: body,
       author: login,
       author_is_bot: user["type"] == "Bot"
     }}
  end

  defp comment(_issue, _comment), do: :error

  ## API

  @doc "Canonical public GitHub HTTPS URL; never accepts a caller-supplied remote."
  @spec clone_url(map()) :: {:ok, String.t()} | {:error, :invalid_clone_url}
  def clone_url(%{owner: owner, name: name}) do
    if valid_clone_owner?(owner) and valid_clone_name?(name) do
      {:ok, "https://github.com/#{owner}/#{name}.git"}
    else
      {:error, :invalid_clone_url}
    end
  end

  def clone_url(_repository), do: {:error, :invalid_clone_url}

  defp valid_clone_owner?(value) do
    is_binary(value) and byte_size(value) in 1..39 and
      Regex.match?(~r/\A[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\z/, value)
  end

  defp valid_clone_name?(value) do
    is_binary(value) and byte_size(value) in 1..100 and
      Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value) and
      value not in [".", ".."] and not String.ends_with?(value, ".git")
  end

  @impl Tackle.Web.Forge
  def clone_auth(forge_app, installation, repository) do
    with {:ok, url} <- clone_url(repository),
         {:ok, token} <- installation_token(forge_app, installation) do
      {:ok, %{url: url, authorization: "Basic " <> Base.encode64("x-access-token:" <> token)}}
    else
      {:error, :invalid_clone_url} = error -> error
      _error -> {:error, :clone_auth_failed}
    end
  rescue
    _error -> {:error, :clone_auth_failed}
  end

  @impl Tackle.Web.Forge
  def pull_request(forge_app, installation, repository, number)
      when is_integer(number) and number > 0 do
    path = "/repos/#{segment(repository.owner)}/#{segment(repository.name)}/pulls/#{number}"

    with {:ok, body} <- installation_request(forge_app, installation, :get, path) do
      case pull_request_data(body) do
        {:ok, pull_request} -> {:ok, pull_request}
        :error -> {:error, {:github, :unexpected_response, path}}
      end
    end
  end

  @impl Tackle.Web.Forge
  def can_trigger?(forge_app, installation, repository, login) when is_binary(login) do
    path =
      "/repos/#{segment(repository.owner)}/#{segment(repository.name)}" <>
        "/collaborators/#{segment(login)}/permission"

    case installation_request(forge_app, installation, :get, path) do
      # `permission` folds maintain into write and triage into read.
      {:ok, %{"permission" => permission}} -> {:ok, permission in ["admin", "write"]}
      {:ok, _other} -> {:error, {:github, :unexpected_response, path}}
      # Not a collaborator, or no such user.
      {:error, {:github, 404, _message}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Posting

  @impl Tackle.Web.Forge
  def post_review(forge_app, installation, repository, number, head_sha, body, comments)
      when is_integer(number) and number > 0 do
    path = pulls_path(repository, number) <> "/reviews"

    with :ok <- check_sha(head_sha),
         :ok <- check_text(body),
         {:ok, comments} <- review_comments_payload(comments) do
      payload =
        JSON.encode!(%{
          "event" => "COMMENT",
          "commit_id" => head_sha,
          "body" => body,
          "comments" => comments
        })

      # A mutation is sent once: no retries and no redirects, which could
      # repeat it or send it elsewhere.
      case installation_request(forge_app, installation, :post, path,
             body: payload,
             retry: false,
             redirect: false
           ) do
        {:ok, %{"id" => id}} when is_integer(id) and id > 0 -> {:ok, Integer.to_string(id)}
        {:ok, _other} -> {:error, {:github, :unexpected_response, path}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp check_sha(sha) do
    if is_binary(sha) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, sha),
      do: :ok,
      else: {:error, :invalid_head_sha}
  end

  defp check_text(body), do: if(is_binary(body), do: :ok, else: {:error, :invalid_body})

  # An invalid comment is named by its index: its text is model output and
  # does not belong in an error that may be stored or logged.
  defp review_comments_payload(comments) when is_list(comments) do
    comments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {comment, index}, {:ok, acc} ->
      case review_comment_payload(comment) do
        {:ok, payload} -> {:cont, {:ok, [payload | acc]}}
        :error -> {:halt, {:error, {:invalid_comment, index}}}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      error -> error
    end
  end

  defp review_comments_payload(_comments), do: {:error, :invalid_comments}

  defp review_comment_payload(%{path: path, side: side, line: line, body: body} = comment)
       when is_binary(path) and path != "" and is_integer(line) and line > 0 and
              is_binary(body) do
    with {:ok, github_side} <- github_side(side),
         {:ok, start} <- start_line(Map.get(comment, :start_line), line, github_side) do
      {:ok,
       Map.merge(
         %{"path" => path, "side" => github_side, "line" => line, "body" => body},
         start
       )}
    end
  end

  defp review_comment_payload(_comment), do: :error

  defp github_side(:new), do: {:ok, "RIGHT"}
  defp github_side(:old), do: {:ok, "LEFT"}
  defp github_side(_side), do: :error

  defp start_line(nil, _line, _side), do: {:ok, %{}}

  defp start_line(start, line, side) when is_integer(start) and start > 0 and start < line,
    do: {:ok, %{"start_line" => start, "start_side" => side}}

  defp start_line(_start, _line, _side), do: :error

  @impl Tackle.Web.Forge
  def find_review(forge_app, installation, repository, number, marker)
      when is_integer(number) and number > 0 and is_binary(marker) and marker != "" do
    path = pulls_path(repository, number) <> "/reviews"

    with {:ok, bot_login} <- bot_login(forge_app),
         {:ok, reviews} <- paginate(forge_app, installation, path, &review/1) do
      {:ok,
       Enum.find_value(reviews, fn review ->
         if review.login == bot_login and review.bot? and is_binary(review.body) and
              String.contains?(review.body, marker),
            do: review.id
       end)}
    end
  end

  # A deleted account's reviews have no user: they are nobody's, not ours.
  defp review(%{"id" => id} = review) when is_integer(id) and id > 0 do
    with {:ok, body} <- optional_string(review, "body") do
      case Map.get(review, "user") do
        %{"login" => login} = user when is_binary(login) ->
          {:ok,
           %{id: Integer.to_string(id), body: body, login: login, bot?: user["type"] == "Bot"}}

        nil ->
          {:ok, %{id: Integer.to_string(id), body: body, login: nil, bot?: false}}

        _malformed ->
          :error
      end
    end
  end

  defp review(_review), do: :error

  # The app's own reviews are by its bot user, `<slug>[bot]`; `[bot]` cannot
  # appear in other accounts' logins.
  defp bot_login(forge_app) do
    with {:ok, jwt} <- app_jwt(forge_app) do
      case request(:get, "/app", jwt) do
        {:ok, %{"slug" => slug}} when is_binary(slug) and slug != "" -> {:ok, slug <> "[bot]"}
        {:ok, _other} -> {:error, {:github, :unexpected_response, "/app"}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Tackle.Web.Forge
  def review_comments(forge_app, installation, repository, number, review_id)
      when is_integer(number) and number > 0 do
    if is_binary(review_id) and Regex.match?(~r/\A[1-9][0-9]*\z/, review_id) do
      path = pulls_path(repository, number) <> "/reviews/#{review_id}/comments"
      paginate(forge_app, installation, path, &posted_comment/1)
    else
      {:error, :invalid_review_id}
    end
  end

  defp posted_comment(%{"id" => id, "body" => body})
       when is_integer(id) and id > 0 and is_binary(body),
       do: {:ok, %{id: Integer.to_string(id), body: body}}

  defp posted_comment(_comment), do: :error

  @impl Tackle.Web.Forge
  def pull_request_files(forge_app, installation, repository, number)
      when is_integer(number) and number > 0 do
    path = pulls_path(repository, number) <> "/files"
    paginate(forge_app, installation, path, &pull_request_file/1)
  end

  defp pull_request_file(%{"filename" => path} = file) when is_binary(path) and path != "" do
    with {:ok, patch} <- optional_string(file, "patch"), do: {:ok, %{path: path, patch: patch}}
  end

  defp pull_request_file(_file), do: :error

  defp optional_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) or is_nil(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp pulls_path(repository, number),
    do: "/repos/#{segment(repository.owner)}/#{segment(repository.name)}/pulls/#{number}"

  # Reads every page of a list at a fixed path, `@per_page` items each; a
  # shorter page is the last. Any malformed page or item fails the whole
  # read, and so does a list longer than `@max_pages` pages, rather than
  # answering from part of it.
  defp paginate(forge_app, installation, path, parse, page \\ 1, acc \\ [])

  defp paginate(forge_app, installation, path, parse, page, acc) do
    params = [per_page: @per_page, page: page]

    case installation_request(forge_app, installation, :get, path, params: params) do
      # One empty sentinel page distinguishes exactly @max_pages full pages
      # from an over-limit list. Never accept or accumulate beyond the cap.
      {:ok, []} ->
        {:ok, Enum.reverse(acc)}

      {:ok, [_ | _]} when page > @max_pages ->
        {:error, {:github, :too_many_pages, path}}

      {:ok, items} when is_list(items) ->
        case parse_items(items, parse) do
          {:ok, parsed} when length(items) < @per_page ->
            {:ok, acc |> Enum.reverse() |> Enum.concat(parsed)}

          {:ok, parsed} ->
            paginate(forge_app, installation, path, parse, page + 1, Enum.reverse(parsed, acc))

          :error ->
            {:error, {:github, :unexpected_response, path}}
        end

      {:ok, _other} ->
        {:error, {:github, :unexpected_response, path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_items(items, parse) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case parse.(item) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      :error -> :error
    end
  end

  @doc """
  An installation access token for `installation`, from the cache or
  fetched with the app's JWT.
  """
  @spec installation_token(ForgeApp.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def installation_token(%ForgeApp{} = forge_app, installation) do
    key = token_key(forge_app, installation)

    case TokenCache.fetch(key) do
      {:ok, token} ->
        {:ok, token}

      :error ->
        with {:ok, jwt} <- app_jwt(forge_app),
             {:ok, %{"token" => token, "expires_at" => expires_at}} <-
               request(
                 :post,
                 "/app/installations/#{segment(installation.external_id)}/access_tokens",
                 jwt
               ),
             {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_at) do
          TokenCache.put(key, token, DateTime.to_unix(expires_at))
          {:ok, token}
        else
          {:ok, _unexpected} -> {:error, {:github, :unexpected_response, "access_tokens"}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp token_key(forge_app, installation), do: {forge_app.app_id, installation.external_id}

  @doc """
  The app's JWT: RS256 over `iat`, `exp`, and `iss` (the App ID), signed
  with its private key.
  """
  @spec app_jwt(ForgeApp.t(), integer()) :: {:ok, String.t()} | {:error, :invalid_private_key}
  def app_jwt(%ForgeApp{} = forge_app, now \\ System.os_time(:second)) do
    with {:ok, key} <- private_key(secret(forge_app, :private_key)) do
      header = encode_segment(%{"alg" => "RS256", "typ" => "JWT"})

      claims =
        encode_segment(%{
          "iat" => now - @jwt_backdate,
          "exp" => now + @jwt_lifetime,
          "iss" => forge_app.app_id
        })

      signing_input = header <> "." <> claims
      signature = :public_key.sign(signing_input, :sha256, key)
      {:ok, signing_input <> "." <> Base.url_encode64(signature, padding: false)}
    end
  end

  defp encode_segment(map), do: map |> JSON.encode!() |> Base.url_encode64(padding: false)

  defp private_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _rest] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, :invalid_private_key}
    end
  rescue
    _error -> {:error, :invalid_private_key}
  end

  defp private_key(_pem), do: {:error, :invalid_private_key}

  # A token the API rejects (revoked, or the installation changed) is
  # dropped from the cache; the caller's retry fetches a new one.
  defp installation_request(forge_app, installation, method, path, opts \\ []) do
    with {:ok, token} <- installation_token(forge_app, installation) do
      case request(method, path, token, opts) do
        {:error, {:github, 401, _message}} = error ->
          TokenCache.delete(token_key(forge_app, installation))
          error

        result ->
          result
      end
    end
  end

  # `opts`: `:body`, an encoded JSON body; `:params`, query parameters; and
  # `:retry` and `:redirect`. They are applied after the configured `:req_options`, so
  # configuration cannot turn a mutation's protections off.
  defp request(method, path, token, opts \\ []) do
    config = Application.get_env(:tackle_web, __MODULE__, [])
    {body, opts} = Keyword.pop(opts, :body)

    content_type =
      if body, do: [{"content-type", "application/json"}], else: []

    [
      method: method,
      base_url: Keyword.get(config, :api_url, "https://api.github.com"),
      url: path,
      headers:
        [
          {"accept", "application/vnd.github+json"},
          {"authorization", "Bearer " <> token},
          {"x-github-api-version", @api_version},
          {"user-agent", "tackle-web"}
        ] ++ content_type,
      # Oban retries failed jobs; a retrying request would hold the job.
      retry: false,
      receive_timeout: 15_000
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.merge(Keyword.take(opts, [:params, :retry, :redirect]))
    |> then(fn options -> if body, do: Keyword.put(options, :body, body), else: options end)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github, status, error_message(body)}}

      {:error, exception} ->
        {:error, {:github, :transport, Exception.message(exception)}}
    end
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(_body), do: nil

  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  # Secrets are calculations (AshCloak); load the one needed when the record
  # was read without it.
  defp secret(%ForgeApp{} = forge_app, field) do
    case Map.fetch!(forge_app, field) do
      %Ash.NotLoaded{} -> forge_app |> Ash.load!(field) |> Map.fetch!(field)
      value -> value
    end
  end
end
