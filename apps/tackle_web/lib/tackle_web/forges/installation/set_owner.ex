defmodule Tackle.Web.Forges.Installation.SetOwner do
  @moduledoc """
  `Installation.set_owner`: makes the user given by `user_id` the owner,
  with their forge id and current login. The user must have signed in with
  the installation's forge.
  """

  use Ash.Resource.Change

  alias Tackle.Web.Accounts.User

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      user_id = Ash.Changeset.get_argument(changeset, :user_id)

      case User.get(user_id) do
        {:ok, %User{forge: forge} = user} when forge == changeset.data.forge ->
          Ash.Changeset.force_change_attributes(changeset,
            owner_external_id: user.external_id,
            owner_login: user.login
          )

        {:ok, _other} ->
          Ash.Changeset.add_error(changeset,
            field: :user_id,
            message: "is not a user of the installation's forge"
          )

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end
end
