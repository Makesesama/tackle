defmodule Tackle.Web.HealthTest do
  use Tackle.Web.DataCase, async: true

  import ExUnit.CaptureLog

  alias Tackle.Web.Health

  defmodule UnreachableRepo do
    use Ecto.Repo, otp_app: :tackle_web, adapter: Ecto.Adapters.Postgres
  end

  test "passes when the database answers" do
    assert Health.check() == :ok
  end

  test "fails when the database cannot be reached" do
    socket_dir =
      Path.join(System.tmp_dir!(), "tackle-web-no-db-#{System.unique_integer([:positive])}")

    capture_log(fn ->
      start_supervised!(
        {UnreachableRepo,
         socket_dir: socket_dir,
         database: "none",
         username: "none",
         pool_size: 1,
         queue_target: 20,
         queue_interval: 20}
      )

      assert {:error, {:database, %DBConnection.ConnectionError{}}} =
               Health.check(UnreachableRepo)
    end)
  end
end
