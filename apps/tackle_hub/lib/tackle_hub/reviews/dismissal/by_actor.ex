defmodule Tackle.Hub.Reviews.Dismissal.ByActor do
  @moduledoc """
  For `Dismissal.dismiss` with a user as the actor: the dismissal is the
  actor's, from the web (`source: :web`, `by` their login), whatever was
  given. Trusted code without an actor passes both.
  """

  use Ash.Resource.Change

  alias Tackle.Hub.Accounts.User

  @impl Ash.Resource.Change
  def change(changeset, _opts, %{actor: %User{login: login}}),
    do: Ash.Changeset.force_change_attributes(changeset, source: :web, by: login)

  def change(changeset, _opts, _context), do: changeset
end
