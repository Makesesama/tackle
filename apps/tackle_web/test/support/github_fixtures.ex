defmodule Tackle.Web.GitHubFixtures do
  @moduledoc """
  GitHub test data: an App with a generated RSA key, records, payloads
  shaped like GitHub's webhook deliveries, and their signatures.
  """

  alias Tackle.Web.Forges.{Access, ForgeApp, Installation, Repository}

  @webhook_secret "test-webhook-secret"

  def webhook_secret, do: @webhook_secret

  @doc "A PEM RSA key, generated once per test run."
  def private_key_pem do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        key = :public_key.generate_key({:rsa, 2048, 65_537})
        pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
        :persistent_term.put({__MODULE__, :key}, {pem, key})
        pem

      {pem, _key} ->
        pem
    end
  end

  @doc "The public half of `private_key_pem/0`."
  def public_key do
    private_key_pem()

    {_pem, {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _}} =
      :persistent_term.get({__MODULE__, :key})

    {:RSAPublicKey, modulus, exponent}
  end

  def forge_app!(attrs \\ %{}) do
    params =
      Map.merge(
        %{
          app_id: "4242",
          client_id: "Iv1.test",
          private_key: private_key_pem(),
          webhook_secret: @webhook_secret,
          client_secret: "test-client-secret"
        },
        attrs
      )

    ForgeApp.configure!(:github, params)
  end

  def unique_id, do: System.unique_integer([:positive, :monotonic]) + 1_000_000

  @doc """
  An active installation. `:owner` (a user) records its owner; other
  attributes are its review defaults.
  """
  def installation!(attrs \\ %{}) do
    installation =
      Installation.sync!(:github, to_string(unique_id()), attrs[:account] || "acme", :active)

    installation =
      case attrs[:owner] do
        nil -> installation
        owner -> Installation.record_owner!(installation, owner.external_id, owner.login)
      end

    case Map.take(attrs, [:review_new_repositories, :default_auto_review]) do
      defaults when map_size(defaults) == 0 -> installation
      defaults -> Installation.set_defaults!(installation, defaults)
    end
  end

  def repository!(installation, settings \\ %{}) do
    repository =
      Repository.sync!(installation.id, to_string(unique_id()), installation.account, "widgets")

    repository =
      if settings == %{}, do: repository, else: Repository.configure!(repository, settings)

    %{repository | installation: installation}
  end

  @doc """
  Stubs GitHub's installation tokens and its user lookup
  (`GET /users/:login`), which answers for `users` and 404 for anyone else.
  Replaces the test's other GitHub stubs.
  """
  def stub_users(users) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    by_login = Map.new(users, &{&1.login, &1})

    Req.Test.stub(Tackle.Web.Forge.GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _rest} ->
          Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

        {"GET", "/users/" <> login} ->
          user_response(conn, Map.get(by_login, login))
      end
    end)
  end

  defp user_response(conn, nil),
    do: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})

  defp user_response(conn, user) do
    Req.Test.json(conn, %{
      "id" => String.to_integer(user.external_id),
      "login" => user.login,
      "type" => "User"
    })
  end

  @doc """
  Grants `user` read access to `installation` (to `repository` alone when
  given), as trusted code, through `stub_users/1`. Needs a forge app.
  """
  def grant!(installation, user, repository \\ nil) do
    stub_users([user])
    Access.grant!(installation.id, user.login, %{repository_id: repository && repository.id})
  end

  ## Payloads

  def repository_payload(repository) do
    %{
      "id" => String.to_integer(repository.external_id),
      "name" => repository.name,
      "full_name" => "#{repository.owner}/#{repository.name}",
      "owner" => %{"login" => repository.owner}
    }
  end

  def pull_request_payload(installation, repository, action, overrides \\ %{}) do
    repo = repository_payload(repository)

    pull_request =
      Map.merge(
        %{
          "number" => 7,
          "title" => "Add widgets",
          "state" => "open",
          "draft" => false,
          "user" => %{"login" => "octocat"},
          "head" => %{"sha" => sha("head"), "ref" => "feature", "repo" => repo},
          "base" => %{"sha" => sha("base"), "ref" => "main", "repo" => repo}
        },
        overrides
      )

    %{
      "action" => action,
      "installation" => %{"id" => String.to_integer(installation.external_id)},
      "repository" => repo,
      "pull_request" => pull_request,
      "sender" => %{"login" => "octocat"}
    }
  end

  def comment_payload(installation, repository, body, opts \\ []) do
    %{
      "action" => Keyword.get(opts, :action, "created"),
      "installation" => %{"id" => String.to_integer(installation.external_id)},
      "repository" => repository_payload(repository),
      "issue" =>
        Map.merge(
          %{"number" => 7},
          if(Keyword.get(opts, :pull_request?, true), do: %{"pull_request" => %{}}, else: %{})
        ),
      "comment" => %{
        "body" => body,
        "user" => %{
          "login" => Keyword.get(opts, :author, "octocat"),
          "type" => Keyword.get(opts, :author_type, "User")
        }
      }
    }
  end

  @doc """
  An `installation` or `installation_repositories` delivery. `opts`:
  `:sender`, a `{id, login}` user who sent it; `:account_type` and
  `:account_id`, the account's type and id (left out by default).
  """
  def installation_payload(action, installation_id, account, repositories, opts \\ []) do
    account_fields =
      Map.reject(
        %{"login" => account, "type" => opts[:account_type], "id" => opts[:account_id]},
        fn {_key, value} -> is_nil(value) end
      )

    sender =
      case opts[:sender] do
        {id, login} -> %{"sender" => %{"id" => id, "login" => login, "type" => "User"}}
        nil -> %{}
      end

    Map.merge(sender, %{
      "action" => action,
      "installation" => %{"id" => installation_id, "account" => account_fields},
      "repositories" =>
        Enum.map(repositories, fn {id, name} ->
          %{"id" => id, "name" => name, "full_name" => "#{account}/#{name}"}
        end)
    })
  end

  ## API responses (for Req.Test stubs)

  @doc "Answers GitHub's paginated `GET /app/installations`: `items` on page 1."
  def installations_page(conn, items) do
    conn = Plug.Conn.fetch_query_params(conn)
    Req.Test.json(conn, if(conn.query_params["page"] == "1", do: items, else: []))
  end

  @doc "Answers `GET /app/installations/:id` from `items`; 404 for another id."
  def installation_response(conn, items, id) do
    case Enum.find(items, &(Integer.to_string(&1["id"]) == id)) do
      nil -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      item -> Req.Test.json(conn, item)
    end
  end

  @doc "Answers `GET /installation/repositories` with `{id, name}` repositories of `owner`."
  def repositories_response(conn, owner, repos) do
    repositories =
      Enum.map(repos, fn {id, name} ->
        %{"id" => id, "name" => name, "owner" => %{"login" => owner}}
      end)

    Req.Test.json(conn, %{"total_count" => length(repositories), "repositories" => repositories})
  end

  @doc "A 40-character hex SHA derived from `seed`."
  def sha(seed), do: :crypto.hash(:sha, seed) |> Base.encode16(case: :lower)

  def signature(body, secret \\ @webhook_secret) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  def headers(event, body, secret \\ @webhook_secret) do
    [
      {"x-github-event", event},
      {"x-github-delivery", "delivery-#{unique_id()}"},
      {"x-hub-signature-256", signature(body, secret)},
      {"content-type", "application/json"}
    ]
  end
end
