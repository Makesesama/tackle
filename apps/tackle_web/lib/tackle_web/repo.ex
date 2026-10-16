defmodule Tackle.Web.Repo do
  @moduledoc "The app's PostgreSQL repository, used by AshPostgres and Oban."

  use AshPostgres.Repo, otp_app: :tackle_web

  @impl AshPostgres.Repo
  def installed_extensions, do: ["ash-functions"]

  @impl AshPostgres.Repo
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
