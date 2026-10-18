defmodule Tackle.Hub.Accounts.ActorOwns do
  @moduledoc """
  A change for records users own (docs/TACKLE_HUB_PLAN.md §7.12): with a
  user as the actor, sets `attribute` (a user id) to the actor's id,
  whatever was given. Without an actor (trusted server code: the console,
  tests), the given value stays.
  """

  use Ash.Resource.Change

  alias Tackle.Hub.Accounts.User

  @impl Ash.Resource.Change
  def change(changeset, opts, %{actor: %User{id: id}}),
    do: Ash.Changeset.force_change_attribute(changeset, Keyword.fetch!(opts, :attribute), id)

  def change(changeset, _opts, _context), do: changeset
end
