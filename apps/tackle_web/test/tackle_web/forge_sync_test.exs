defmodule Tackle.Web.ForgeSyncTest do
  use Tackle.Web.DataCase, async: true

  import Tackle.Web.GitHubFixtures

  require Ash.Query

  alias Tackle.Web.Forge.GitHub
  alias Tackle.Web.Forges.{Installation, Repository}
  alias Tackle.Web.ForgeSync

  setup do
    forge_app!()
    :ok
  end

  # GitHub's view: `installations` as `{id, account, suspended?, repos}`.
  defp stub_github(installations) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    items =
      Enum.map(installations, fn {id, account, suspended?, _repos} ->
        %{
          "id" => String.to_integer(id),
          "account" => %{"login" => account},
          "suspended_at" => if(suspended?, do: "2026-01-01T00:00:00Z")
        }
      end)

    Req.Test.stub(GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/app/installations"} ->
          installations_page(conn, items)

        {"GET", "/app/installations/" <> id} ->
          installation_response(conn, items, id)

        {"POST", "/app/installations/" <> rest} ->
          [id, "access_tokens"] = String.split(rest, "/")
          Req.Test.json(conn, %{"token" => "ghs_" <> id, "expires_at" => expires_at})

        {"GET", "/installation/repositories"} ->
          ["Bearer ghs_" <> id] = Plug.Conn.get_req_header(conn, "authorization")
          {_id, account, _suspended?, repos} = List.keyfind(installations, id, 0)
          repositories_response(conn, account, repos)
      end
    end)
  end

  test "records new installations and repositories with the installation's defaults" do
    id = to_string(unique_id())
    stub_github([{id, "acme", false, [{11, "widgets"}, {12, "gadgets"}]}])

    assert ForgeSync.sync_all(:github) == {:ok, %{installations: 1, repositories: 2}}

    installation = Installation.get_external!(:github, id)
    assert %{account: "acme", status: :active} = installation

    repos =
      Repository
      |> Ash.Query.filter(installation_id == ^installation.id)
      |> Ash.Query.sort(:name)
      |> Ash.read!()

    assert [%{name: "gadgets", active: true, enabled: false}, %{name: "widgets"}] = repos
  end

  test "reconciles: keeps settings, deactivates what GitHub no longer lists, leaves suspended ones" do
    kept = installation!(%{account: "acme"})
    kept_repo = repository!(kept, %{enabled: true, auto_review: :on_open})
    dropped_repo = repository!(kept)

    suspended = installation!(%{account: "paused"})
    suspended_repo = repository!(suspended)

    gone = installation!(%{account: "gone"})
    gone_repo = repository!(gone)

    stub_github([
      {kept.external_id, "acme", false,
       [{String.to_integer(kept_repo.external_id), kept_repo.name}]},
      {suspended.external_id, "paused", true, []}
    ])

    assert {:ok, %{installations: 2}} = ForgeSync.sync_all(:github)

    assert %{active: true, enabled: true, auto_review: :on_open} =
             Ash.get!(Repository, kept_repo.id)

    assert %{active: false} = Ash.get!(Repository, dropped_repo.id)
    assert %{status: :suspended} = Ash.get!(Installation, suspended.id)
    assert %{active: true} = Ash.get!(Repository, suspended_repo.id)
    assert %{status: :removed} = Ash.get!(Installation, gone.id)
    assert %{active: false} = Ash.get!(Repository, gone_repo.id)
  end

  @tag :capture_log
  test "an installation whose repositories cannot be read keeps them; the others sync" do
    broken = installation!(%{account: "broken"})
    broken_repo = repository!(broken)
    fine = to_string(unique_id())

    items = [
      %{"id" => String.to_integer(broken.external_id), "account" => %{"login" => "broken"}},
      %{"id" => String.to_integer(fine), "account" => %{"login" => "acme"}}
    ]

    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    broken_tokens = "/app/installations/#{broken.external_id}/access_tokens"

    Req.Test.stub(GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/app/installations"} -> installations_page(conn, items)
        {"POST", ^broken_tokens} -> conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{})
        {"POST", _token} -> Req.Test.json(conn, %{"token" => "t", "expires_at" => expires_at})
        {"GET", "/installation/repositories"} -> repositories_response(conn, "acme", [{31, "x"}])
      end
    end)

    assert {:ok, %{installations: 2, repositories: 1}} = ForgeSync.sync_all(:github)
    assert %{active: true} = Ash.get!(Repository, broken_repo.id)
    assert %{status: :active} = Installation.get_external!(:github, fine)
  end

  test "a webhook that lands while GitHub is read is not undone by the older snapshot" do
    installation = installation!(%{account: "acme"})
    id = installation.external_id
    test_pid = self()

    Req.Test.stub(GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/app/installations"} ->
          installations_page(conn, [
            %{"id" => String.to_integer(id), "account" => %{"login" => "acme"}}
          ])

        {"POST", _token} ->
          expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
          Req.Test.json(conn, %{"token" => "t", "expires_at" => expires_at})

        {"GET", "/installation/repositories"} ->
          # A repositories_added webhook, handled while the sync reads GitHub.
          send(test_pid, {:added, Repository.sync!(installation.id, "77", "acme", "fresh")})
          repositories_response(conn, "acme", [])
      end
    end)

    assert {:ok, _summary} = ForgeSync.sync_all(:github)
    assert_received {:added, fresh}
    assert %{active: true} = Ash.get!(Repository, fresh.id)
  end

  test "sync_installation records one installation that GitHub confirms" do
    id = to_string(unique_id())
    other = installation!(%{account: "other"})
    stub_github([{id, "acme", false, [{21, "widgets"}]}])

    assert ForgeSync.sync_installation(:github, id) ==
             {:ok, %{installations: 1, repositories: 1}}

    assert %{status: :active} = Installation.get_external!(:github, id)
    # Other installations are not touched by a single-installation sync.
    assert %{status: :active} = Ash.get!(Installation, other.id)

    assert ForgeSync.sync_installation(:github, "424242") == {:error, :not_found}
  end
end
