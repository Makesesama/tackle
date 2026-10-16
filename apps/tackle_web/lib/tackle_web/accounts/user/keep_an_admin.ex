defmodule Tackle.Web.Accounts.User.KeepAnAdmin do
  @moduledoc """
  Refuses to take admin away from the last admin, so the app can always be
  managed from the browser. Checked under `AdminLock` inside the action's
  transaction, so two admins demoting each other cannot both succeed.
  """

  use Ash.Resource.Change

  alias Tackle.Web.Accounts.User.AdminLock

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      AdminLock.lock!()

      demoting? =
        changeset.data.admin and Ash.Changeset.get_attribute(changeset, :admin) == false

      if demoting? and AdminLock.other_admins(changeset.data.id) == 0 do
        Ash.Changeset.add_error(changeset,
          field: :admin,
          message: "the last admin cannot be removed"
        )
      else
        changeset
      end
    end)
  end
end
