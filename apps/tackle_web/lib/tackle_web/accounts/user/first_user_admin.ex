defmodule Tackle.Web.Accounts.User.FirstUserAdmin do
  @moduledoc """
  Makes the first user an admin. Inside the action's transaction, a
  transaction-scoped advisory lock serialises sign-ins, so two people signing
  in at once cannot both become the first. On an existing user the upsert
  leaves `admin` alone, whatever this computes.
  """

  use Ash.Resource.Change

  alias Tackle.Web.Repo

  # An arbitrary constant naming the lock; unrelated to review request locks,
  # which hash their request ids.
  @lock_key 7_301_002_026

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key])
      %{rows: [[any_user?]]} = Repo.query!("SELECT EXISTS (SELECT 1 FROM users)")
      Ash.Changeset.force_change_attribute(changeset, :admin, not any_user?)
    end)
  end
end
