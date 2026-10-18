defmodule Tackle.Hub.Accounts.Check do
  @moduledoc """
  The policy check for signed-in actors: `{Tackle.Hub.Accounts.Check, role:
  :user}` passes for any existing user, `role: :admin` for an admin.

  It reads the user again instead of trusting the actor's fields. A page
  that stays open (an AshAdmin form, say) holds the user as it was loaded,
  so a user deleted or an admin flag revoked since then must still stop the
  next action. One primary key read per check.
  """

  use Ash.Policy.SimpleCheck

  alias Tackle.Hub.Accounts.User

  @impl Ash.Policy.Check
  def describe(opts), do: "actor is a current #{Keyword.fetch!(opts, :role)}"

  @impl Ash.Policy.SimpleCheck
  def match?(%User{id: id}, _context, opts) do
    case {User.get(id), Keyword.fetch!(opts, :role)} do
      {{:ok, %User{admin: true}}, :admin} -> true
      {{:ok, %User{}}, :user} -> true
      _other -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
