defmodule Tackle.Web.GitHubFixtures do
  @moduledoc """
  GitHub test data: an App with a generated RSA key, records, payloads
  shaped like GitHub's webhook deliveries, and their signatures.
  """

  alias Tackle.Web.Forges.{ForgeApp, Installation, Repository}

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

  def installation!(attrs \\ %{}) do
    installation =
      Installation.sync!(:github, to_string(unique_id()), attrs[:account] || "acme", :active)

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

  def installation_payload(action, installation_id, account, repositories) do
    %{
      "action" => action,
      "installation" => %{"id" => installation_id, "account" => %{"login" => account}},
      "repositories" =>
        Enum.map(repositories, fn {id, name} ->
          %{"id" => id, "name" => name, "full_name" => "#{account}/#{name}"}
        end)
    }
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
