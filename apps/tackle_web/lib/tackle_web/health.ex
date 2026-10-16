defmodule Tackle.Web.Health do
  @moduledoc """
  Readiness of the app's dependencies, for the health endpoint: the
  database answers a query.
  """

  alias Ecto.Adapters.SQL

  @timeout 5_000

  @doc """
  Returns `:ok` when the database answers, or `{:error, {:database,
  reason}}` when it does not. `repo` defaults to `Tackle.Web.Repo`.
  """
  @spec check(module()) :: :ok | {:error, {:database, Exception.t()}}
  def check(repo \\ Tackle.Web.Repo) do
    case SQL.query(repo, "SELECT 1", [], timeout: @timeout, log: false) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:database, reason}}
    end
  rescue
    # Raised instead of returned when no connection can be checked out.
    error in DBConnection.ConnectionError -> {:error, {:database, error}}
  end
end
