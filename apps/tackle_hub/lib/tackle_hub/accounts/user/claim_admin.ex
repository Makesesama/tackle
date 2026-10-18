defmodule Tackle.Hub.Accounts.User.ClaimAdmin do
  @moduledoc """
  With `claim_admin: true` (a sign-in from the browser that unlocked setup,
  `Tackle.Hub.Setup`), makes the signed-in user an admin if nobody is one
  yet. Runs after the upsert, so it also applies to someone who had signed
  in before, and under `AdminLock`, so only one claim can win.
  """

  use Ash.Resource.Change

  alias Tackle.Hub.Accounts.User.AdminLock

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_argument(changeset, :claim_admin) do
      Ash.Changeset.after_action(changeset, fn _changeset, user -> claim(user) end)
    else
      changeset
    end
  end

  defp claim(%{admin: true} = user), do: {:ok, user}

  defp claim(user) do
    AdminLock.lock!()

    if AdminLock.other_admins(nil) == 0 do
      user
      |> Ash.Changeset.for_update(:set_admin, %{admin: true})
      |> Ash.update(authorize?: false)
    else
      {:ok, user}
    end
  end
end
