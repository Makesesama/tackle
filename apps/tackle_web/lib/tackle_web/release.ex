defmodule Tackle.Web.Release do
  @moduledoc """
  Tasks for a release, run with `bin/tackle_web eval`, which has no Mix:

      bin/tackle_web eval "Tackle.Web.Release.migrate()"
  """

  @app :tackle_web

  @doc "Runs all pending migrations of every repository."
  @spec migrate() :: :ok
  def migrate do
    :ok = Application.ensure_loaded(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
