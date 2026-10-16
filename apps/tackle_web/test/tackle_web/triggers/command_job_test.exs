defmodule Tackle.Web.Triggers.CommandJobTest do
  use Tackle.Web.DataCase, async: true
  use Oban.Testing, repo: Tackle.Web.Repo

  import Tackle.Web.GitHubFixtures

  alias Tackle.Web.Forge.GitHub
  alias Tackle.Web.Reviews.ReviewRequest
  alias Tackle.Web.Triggers.CommandJob

  setup do
    forge_app!()
    installation = installation!(%{review_new_repositories: true})
    repository = repository!(installation)
    {:ok, repository: repository}
  end

  defp args(repository, attrs \\ %{}) do
    Map.merge(
      %{repository_id: repository.id, pull_number: 7, login: "ada", profile: nil},
      attrs
    )
  end

  # The token request, then the permission check, then (when allowed) the
  # pull request.
  defp stub_github(permission, pull_request \\ %{}) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    Req.Test.stub(GitHub, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest ->
          Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

        "/repos/acme/widgets/collaborators/ada/permission" ->
          Req.Test.json(conn, %{"permission" => permission})

        "/repos/acme/widgets/pulls/7" ->
          repo = %{"id" => 1}

          Req.Test.json(
            conn,
            Map.merge(
              %{
                "number" => 7,
                "state" => "open",
                "draft" => true,
                "head" => %{"sha" => sha("head"), "repo" => repo},
                "base" => %{"sha" => sha("base"), "ref" => "main", "repo" => repo}
              },
              pull_request
            )
          )
      end
    end)
  end

  test "requests a review of the current head for someone with write access", %{
    repository: repository
  } do
    stub_github("write")

    assert :ok = perform_job(CommandJob, args(repository, %{profile: "assertive"}))

    assert {:ok, %{trigger: :command, profile: :assertive, requested_by: "ada", base_ref: "main"}} =
             ReviewRequest.get_head(repository.id, 7, sha("head"))
  end

  test "cancels for someone without write access", %{repository: repository} do
    stub_github("read")

    assert {:cancel, "ada has no write access to acme/widgets"} =
             perform_job(CommandJob, args(repository))

    assert {:ok, nil} = ReviewRequest.get_head(repository.id, 7, sha("head"))
  end

  test "cancels for a closed pull request", %{repository: repository} do
    stub_github("admin", %{"state" => "closed"})

    assert {:cancel, "not reviewed: closed"} = perform_job(CommandJob, args(repository))
  end

  test "retries when the forge fails", %{repository: repository} do
    Req.Test.stub(GitHub, fn conn ->
      conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{"message" => "Bad Gateway"})
    end)

    assert {:error, {:github, 502, "Bad Gateway"}} = perform_job(CommandJob, args(repository))
  end

  test "cancels when the repository no longer exists" do
    assert {:cancel, "the repository no longer exists"} =
             perform_job(CommandJob, %{
               repository_id: Ecto.UUID.generate(),
               pull_number: 7,
               login: "ada",
               profile: nil
             })
  end

  test "cancels an unknown profile without calling the forge", %{repository: repository} do
    assert {:cancel, "unknown profile \"loud\""} =
             perform_job(CommandJob, args(repository, %{profile: "loud"}))
  end
end
