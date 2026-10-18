defmodule Tackle.Hub.Accounts.User.AdminLock do
  @moduledoc """
  Serialises changes to who is an admin: a transaction-scoped advisory lock
  taken inside the action's transaction, so an admin claim and the
  last-admin check see each other's results.
  """

  alias Tackle.Hub.Repo

  # An arbitrary constant naming the lock; unrelated to review request locks,
  # which hash their request ids.
  @lock_key 7_301_002_026

  @doc "Takes the lock for the rest of the current transaction."
  @spec lock!() :: :ok
  def lock! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key])
    :ok
  end

  @doc "How many admins there are, other than `except_id`."
  @spec other_admins(Ecto.UUID.t() | nil) :: non_neg_integer()
  def other_admins(except_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM users WHERE admin AND ($1::uuid IS NULL OR id <> $1::uuid)",
        [except_id && Ecto.UUID.dump!(except_id)]
      )

    count
  end
end
