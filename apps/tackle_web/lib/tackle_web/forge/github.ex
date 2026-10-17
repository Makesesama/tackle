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
  `:api_url` (default `"https://api.github.com"`), `:web_url` (default
  `"https://github.com"`, where browsers sign in and OAuth codes are
  exchanged), and `:req_options`, extra `Req` options (tests route requests
  to `Req.Test` with them).
  """

  @behaviour Tackle.Web.Forge

  require Logger

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
         installation: installer(installation, action, payload["sender"]),
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

  # Resolving or unresolving a line comment's thread (§7.13). Bots' changes
  # (another app's) never count.
  def parse_event("pull_request_review_thread", %{"action" => action} = payload)
      when action in ["resolved", "unresolved"] do
    case payload["sender"] do
      %{"login" => login, "type" => "User"} when is_binary(login) ->
        with {:ok, repository} <- repository(payload["repository"]),
             {:ok, installation} <- installation_of(payload["installation"], repository),
             {:ok, thread} <- thread(payload["pull_request"], payload["thread"]) do
          {:ok,
           %Event{
             type: :review_thread,
             action: if(action == "resolved", do: :resolved, else: :unresolved),
             installation: installation,
             repository: repository,
             thread: thread,
             sender: login
           }}
        end

      _other ->
        {:ok, ignored("review thread #{action} by a bot")}
    end
  end

  def parse_event("pull_request_review_thread", %{"action" => action}),
    do: {:ok, ignored("pull_request_review_thread #{action}")}

  def parse_event(event, _payload), do: {:ok, ignored("event #{inspect(event)}")}

  defp ignored(reason), do: %Event{type: :ignored, reason: reason}

  defp installation_action("created"), do: {:ok, :created}
  defp installation_action("deleted"), do: {:ok, :deleted}
  defp installation_action("suspend"), do: {:ok, :suspended}
  defp installation_action("unsuspend"), do: {:ok, :unsuspended}
  defp installation_action(other), do: {:ignore, other}

  defp installation(%{"id" => id, "account" => %{"login" => login} = account})
       when is_integer(id) and is_binary(login),
       do:
         {:ok, %{external_id: Integer.to_string(id), account: login, owner: user_owner(account)}}

  defp installation(_other), do: :error

  # The user who installed the app owns it (docs/TACKLE_WEB_PLAN.md §7.12):
  # the sender of the signed `created` event. Other events only name the
  # owner of an installation on a user account.
  defp installer(installation, :created, %{"type" => "User"} = sender) do
    case user_owner(sender) do
      nil -> installation
      owner -> %{installation | owner: owner}
    end
  end

  defp installer(installation, _action, _sender), do: installation

  # A user account owns an installation on it; an organisation's owner is
  # not known from the account.
  defp user_owner(%{"type" => "User", "id" => id, "login" => login})
       when is_integer(id) and id > 0 and is_binary(login) and login != "",
       do: %{external_id: Integer.to_string(id), login: login}

  defp user_owner(_account), do: nil

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
       author: get_in(pull_request, ["user", "login"]),
       title: title(pull_request["title"])
     }}
  end

  defp pull_request_data(_other), do: :error

  # Shown on the pages: a string, bounded.
  defp title(title) when is_binary(title), do: String.slice(title, 0, 300)
  defp title(_title), do: nil

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

  defp thread(%{"number" => number}, %{"comments" => comments})
       when is_integer(number) and number > 0 and is_list(comments) do
    ids =
      Enum.flat_map(comments, fn
        %{"id" => id} when is_integer(id) and id > 0 -> [Integer.to_string(id)]
        _other -> []
      end)

    {:ok, %{pull_number: number, comment_ids: ids}}
  end

  defp thread(_pull_request, _thread), do: :error

  ## Sign-in

  # The App's OAuth web flow ("user access tokens"): GitHub Apps have no
  # scopes, so the token can only read the user's public profile here.

  @impl Tackle.Web.Forge
  def authorize_url(%ForgeApp{} = forge_app, state, redirect_uri)
      when is_binary(state) and state != "" and is_binary(redirect_uri) do
    with {:ok, client_id, _client_secret} <- oauth_client(forge_app) do
      query =
        URI.encode_query(%{
          "client_id" => client_id,
          "redirect_uri" => redirect_uri,
          "state" => state,
          "allow_signup" => "false"
        })

      {:ok, web_url() <> "/login/oauth/authorize?" <> query}
    end
  end

  @impl Tackle.Web.Forge
  def sign_in(%ForgeApp{} = forge_app, code, redirect_uri)
      when is_binary(code) and is_binary(redirect_uri) do
    with {:ok, client_id, client_secret} <- oauth_client(forge_app),
         {:ok, token} <- exchange_code(client_id, client_secret, code, redirect_uri) do
      result = signed_in_user(token)
      revoke_user_token(client_id, client_secret, token)
      result
    end
  end

  defp oauth_client(forge_app) do
    client_id = forge_app.client_id
    client_secret = secret(forge_app, :client_secret)

    if is_binary(client_id) and client_id != "" and is_binary(client_secret) and
         client_secret != "",
       do: {:ok, client_id, client_secret},
       else: {:error, :sign_in_not_configured}
  end

  # GitHub answers 200 for a rejected code too, with an `error` field. Only
  # that error code is kept: descriptions are not needed and not logged.
  defp exchange_code(client_id, client_secret, code, redirect_uri) do
    body =
      JSON.encode!(%{
        "client_id" => client_id,
        "client_secret" => client_secret,
        "code" => code,
        "redirect_uri" => redirect_uri
      })

    [
      method: :post,
      base_url: web_url(),
      url: "/login/oauth/access_token",
      headers: [
        {"accept", "application/json"},
        {"content-type", "application/json"},
        {"user-agent", "tackle-web"}
      ],
      receive_timeout: 15_000
    ]
    |> Keyword.merge(config(:req_options, []))
    |> Keyword.merge(body: body, retry: false, redirect: false)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}}
      when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} when is_binary(error) ->
        {:error, {:github, :oauth, error}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:github, status, nil}}

      {:error, exception} ->
        {:error, {:github, :transport, Exception.message(exception)}}
    end
  end

  defp signed_in_user(token) do
    case request(:get, "/user", token) do
      {:ok, %{"id" => id, "login" => login} = user}
      when is_integer(id) and id > 0 and is_binary(login) and login != "" ->
        name = if is_binary(user["name"]) and user["name"] != "", do: user["name"]
        {:ok, %{external_id: Integer.to_string(id), login: login, name: name}}

      {:ok, _other} ->
        {:error, {:github, :unexpected_response, "/user"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The token is not needed after reading the user; revoking it keeps a
  # leaked token (logs of a proxy, say) from being useful. Failing to revoke
  # does not fail the sign-in: the token expires by itself.
  defp revoke_user_token(client_id, client_secret, token) do
    path = "/applications/#{segment(client_id)}/token"

    case request(:delete, path, {:basic, client_id, client_secret},
           body: JSON.encode!(%{"access_token" => token}),
           redirect: false
         ) do
      {:ok, _body} ->
        :ok

      {:error, {:github, status, _message}} ->
        Logger.warning("could not revoke a GitHub sign-in token: #{inspect(status)}")
    end
  end

  @impl Tackle.Web.Forge
  def member?(%ForgeApp{} = forge_app, installation, %{external_id: user_id, login: login})
      when is_binary(user_id) and is_binary(login) do
    with {:ok, account} <- installation_account(forge_app, installation) do
      case account do
        %{type: "Organization", login: org} -> org_member?(forge_app, installation, org, login)
        %{type: "User", id: id} -> {:ok, id == user_id}
        # Enterprise installations have no members to check this way.
        _other -> {:ok, false}
      end
    end
  end

  defp installation_account(forge_app, installation) do
    path = "/app/installations/#{segment(installation.external_id)}"

    with {:ok, jwt} <- app_jwt(forge_app) do
      case request(:get, path, jwt) do
        {:ok, %{"account" => %{"login" => login, "id" => id} = account}}
        when is_binary(login) and is_integer(id) ->
          {:ok, %{login: login, id: Integer.to_string(id), type: account["type"]}}

        {:ok, _other} ->
          {:error, {:github, :unexpected_response, path}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # 204 for a member, 404 for anyone else. GitHub answers 302 when the
  # requester cannot see the membership list; an installation token with
  # Members: read can, so a redirect only means "not verified".
  defp org_member?(forge_app, installation, org, login) do
    path = "/orgs/#{segment(org)}/members/#{segment(login)}"

    case installation_request(forge_app, installation, :get, path, redirect: false) do
      {:ok, _body} -> {:ok, true}
      {:error, {:github, status, _message}} when status in [302, 404] -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  # Logins follow GitHub's rules for account names, so a login never
  # reaches the API as anything but one path segment.
  @impl Tackle.Web.Forge
  def user(%ForgeApp{} = forge_app, installation, login) when is_binary(login) do
    if valid_clone_owner?(login) do
      forge_app
      |> installation_request(installation, :get, "/users/#{segment(login)}")
      |> forge_user()
    else
      {:error, :not_found}
    end
  end

  defp forge_user({:ok, %{"type" => "User"} = user}) do
    case user_owner(user) do
      nil -> {:error, {:github, :unexpected_response, "/users"}}
      account -> {:ok, Map.put(account, :name, nil)}
    end
  end

  defp forge_user({:ok, %{"type" => _other}}), do: {:error, :not_found}
  defp forge_user({:ok, _other}), do: {:error, {:github, :unexpected_response, "/users"}}
  defp forge_user({:error, {:github, 404, _message}}), do: {:error, :not_found}
  defp forge_user({:error, reason}), do: {:error, reason}

  ## Registration and installations (web setup)

  # What the app needs (§7.1). `members` is the organisation permission for
  # checking sign-ins.
  @permissions %{
    "metadata" => "read",
    "contents" => "read",
    "pull_requests" => "write",
    "issues" => "read",
    "members" => "read"
  }
  @events ["pull_request", "issue_comment", "pull_request_review_thread"]

  @impl Tackle.Web.Forge
  def registration_form(base_url, state, opts) when is_binary(base_url) and is_binary(state) do
    owner = Keyword.get(opts, :owner)

    with {:ok, path} <- registration_path(owner) do
      manifest =
        %{
          "name" => Keyword.get(opts, :name, "tackle"),
          "url" => base_url,
          "redirect_url" => base_url <> "/setup/github/callback",
          "callback_urls" => [base_url <> "/auth/github/callback"],
          "setup_url" => base_url <> "/setup/github/installed",
          "setup_on_update" => true,
          # Public, so users can install it on their own accounts (§7.12).
          "public" => true,
          "request_oauth_on_install" => false,
          "default_permissions" => @permissions
        }
        |> Map.merge(webhook_manifest(base_url, Keyword.get(opts, :webhook?, true)))

      {:ok,
       %{
         action: web_url() <> path <> "?" <> URI.encode_query(%{"state" => state}),
         fields: [{"manifest", JSON.encode!(manifest)}]
       }}
    end
  end

  defp registration_path(nil), do: {:ok, "/settings/apps/new"}
  defp registration_path(""), do: {:ok, "/settings/apps/new"}

  defp registration_path(owner) do
    if valid_clone_owner?(owner),
      do: {:ok, "/organizations/#{owner}/settings/apps/new"},
      else: {:error, :invalid_owner}
  end

  # Without a webhook there are no events to subscribe to either.
  defp webhook_manifest(base_url, true) do
    %{
      "hook_attributes" => %{"url" => base_url <> "/webhooks/github", "active" => true},
      "default_events" => @events
    }
  end

  defp webhook_manifest(_base_url, false), do: %{}

  # The code is the credential: the endpoint takes no authentication.
  @impl Tackle.Web.Forge
  def complete_registration(code) when is_binary(code) and code != "" do
    path = "/app-manifests/#{segment(code)}/conversions"

    with {:ok, body} <- request(:post, path, :none, retry: false, redirect: false) do
      registration(body)
    end
  end

  defp registration(
         %{
           "id" => id,
           "client_id" => client_id,
           "client_secret" => client_secret,
           "pem" => pem,
           "html_url" => html_url
         } = app
       )
       when is_integer(id) and is_binary(client_id) and is_binary(client_secret) and
              is_binary(pem) and is_binary(html_url) do
    {:ok,
     %{
       app_id: Integer.to_string(id),
       client_id: client_id,
       client_secret: client_secret,
       private_key: pem,
       webhook_secret: if(is_binary(app["webhook_secret"]), do: app["webhook_secret"]),
       install_url: html_url <> "/installations/new"
     }}
  end

  defp registration(_body), do: {:error, {:github, :unexpected_response, "/app-manifests"}}

  @impl Tackle.Web.Forge
  def install_url(%ForgeApp{} = forge_app) do
    with {:ok, jwt} <- app_jwt(forge_app) do
      case request(:get, "/app", jwt) do
        {:ok, %{"html_url" => html_url}} when is_binary(html_url) ->
          {:ok, html_url <> "/installations/new"}

        {:ok, _other} ->
          {:error, {:github, :unexpected_response, "/app"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl Tackle.Web.Forge
  def installations(%ForgeApp{} = forge_app) do
    with {:ok, jwt} <- app_jwt(forge_app),
         {:ok, installations} <-
           paginate_with(
             &request(:get, "/app/installations", jwt, params: &1),
             "/app/installations",
             &installation_item/1,
             &list_items/1
           ) do
      collect(installations, &listed_snapshot(forge_app, &1))
    end
  end

  # In a full listing, an installation whose repositories cannot be read
  # (revoked or suspended since it was listed) does not fail the others: its
  # repositories are reported as unknown, which leaves them as they are.
  defp listed_snapshot(forge_app, item) do
    case snapshot(forge_app, item) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, reason} ->
        Logger.warning(
          "could not read the repositories of GitHub installation " <>
            "#{item.installation.external_id}: #{inspect(error_kind(reason))}"
        )

        {:ok, Map.put(item, :repositories, nil)}
    end
  end

  defp error_kind({:github, status, _detail}), do: {:github, status}
  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(_reason), do: :unexpected

  @impl Tackle.Web.Forge
  def installation(%ForgeApp{} = forge_app, external_id) when is_binary(external_id) do
    path = "/app/installations/#{segment(external_id)}"

    with {:ok, jwt} <- app_jwt(forge_app),
         {:ok, body} <- found(request(:get, path, jwt)) do
      case installation_item(body) do
        {:ok, item} -> snapshot(forge_app, item)
        :error -> {:error, {:github, :unexpected_response, path}}
      end
    end
  end

  defp found({:error, {:github, 404, _message}}), do: {:error, :not_found}
  defp found(result), do: result

  defp installation_item(%{"id" => id, "account" => %{"login" => login} = account} = item)
       when is_integer(id) and is_binary(login) do
    status = if is_nil(item["suspended_at"]), do: :active, else: :suspended

    {:ok,
     %{
       installation: %{
         external_id: Integer.to_string(id),
         account: login,
         owner: user_owner(account)
       },
       status: status
     }}
  end

  defp installation_item(_item), do: :error

  # A suspended installation cannot get a token, so its repositories are
  # unknown rather than empty.
  defp snapshot(_forge_app, %{status: :suspended} = item),
    do: {:ok, Map.put(item, :repositories, nil)}

  defp snapshot(forge_app, %{installation: installation} = item) do
    fetch =
      &installation_request(forge_app, installation, :get, "/installation/repositories",
        params: &1
      )

    with {:ok, repositories} <-
           paginate_with(
             fetch,
             "/installation/repositories",
             &repository/1,
             &wrapped_repositories/1
           ) do
      {:ok, Map.put(item, :repositories, repositories)}
    end
  end

  defp wrapped_repositories(%{"repositories" => list}) when is_list(list), do: {:ok, list}
  defp wrapped_repositories(_body), do: :error

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  ## Browser URLs

  @impl Tackle.Web.Forge
  def repository_url(repository),
    do: "#{web_url()}/#{segment(repository.owner)}/#{segment(repository.name)}"

  @impl Tackle.Web.Forge
  def pull_request_url(repository, number) when is_integer(number) and number > 0,
    do: "#{repository_url(repository)}/pull/#{number}"

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
  def review_comment_reactions(forge_app, installation, repository, number)
      when is_integer(number) and number > 0 do
    path = pulls_path(repository, number) <> "/comments"
    paginate(forge_app, installation, path, &comment_reactions/1)
  end

  defp comment_reactions(%{"id" => id} = comment) when is_integer(id) and id > 0 do
    reactions = Map.get(comment, "reactions") || %{}

    {:ok,
     %{
       id: Integer.to_string(id),
       up: count(reactions["+1"]),
       down: count(reactions["-1"])
     }}
  end

  defp comment_reactions(_comment), do: :error

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0

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
  defp paginate(forge_app, installation, path, parse) do
    fetch = &installation_request(forge_app, installation, :get, path, params: &1)
    paginate_with(fetch, path, parse, &list_items/1)
  end

  # `fetch` reads one page given its query parameters; `items` finds the
  # page's list in its body (some endpoints wrap it in an object).
  defp paginate_with(fetch, path, parse, items, page \\ 1, acc \\ []) do
    with {:ok, body} <- fetch.(per_page: @per_page, page: page) do
      case items.(body) do
        # One empty sentinel page distinguishes exactly @max_pages full pages
        # from an over-limit list. Never accept or accumulate beyond the cap.
        {:ok, []} ->
          {:ok, Enum.reverse(acc)}

        {:ok, [_ | _]} when page > @max_pages ->
          {:error, {:github, :too_many_pages, path}}

        {:ok, list} ->
          next_page(list, fetch, path, parse, items, page, acc)

        :error ->
          {:error, {:github, :unexpected_response, path}}
      end
    end
  end

  defp next_page(list, fetch, path, parse, items, page, acc) do
    case parse_items(list, parse) do
      {:ok, parsed} when length(list) < @per_page ->
        {:ok, acc |> Enum.reverse() |> Enum.concat(parsed)}

      {:ok, parsed} ->
        paginate_with(fetch, path, parse, items, page + 1, Enum.reverse(parsed, acc))

      :error ->
        {:error, {:github, :unexpected_response, path}}
    end
  end

  defp list_items(list) when is_list(list), do: {:ok, list}
  defp list_items(_body), do: :error

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
  # configuration cannot turn a mutation's protections off. `credential` is
  # a bearer token, `{:basic, id, secret}` for the OAuth client's own calls,
  # or `:none`.
  defp request(method, path, credential, opts \\ []) do
    {body, opts} = Keyword.pop(opts, :body)

    content_type =
      if body, do: [{"content-type", "application/json"}], else: []

    [
      method: method,
      base_url: config(:api_url, "https://api.github.com"),
      url: path,
      headers:
        [
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", @api_version},
          {"user-agent", "tackle-web"}
        ] ++ authorization_header(credential) ++ content_type,
      # Oban retries failed jobs; a retrying request would hold the job.
      retry: false,
      receive_timeout: 15_000
    ]
    |> Keyword.merge(config(:req_options, []))
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

  defp authorization({:basic, id, secret}), do: "Basic " <> Base.encode64(id <> ":" <> secret)
  defp authorization(token) when is_binary(token), do: "Bearer " <> token

  defp authorization_header(:none), do: []
  defp authorization_header(credential), do: [{"authorization", authorization(credential)}]

  defp config(key, default),
    do: :tackle_web |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  defp web_url, do: config(:web_url, "https://github.com")

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
