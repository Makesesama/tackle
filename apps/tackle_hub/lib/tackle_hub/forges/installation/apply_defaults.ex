defmodule Tackle.Hub.Forges.Installation.ApplyDefaults do
  @moduledoc """
  With `apply_to_repositories: true`, resets every repository of the
  installation to its (new) defaults after the update, in the same
  transaction, with the actor and authorisation of the update itself.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Tackle.Hub.Forges.Repository

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    if Ash.Changeset.get_argument(changeset, :apply_to_repositories) do
      Ash.Changeset.after_action(changeset, fn _changeset, installation ->
        apply_to_repositories(installation, context)
      end)
    else
      changeset
    end
  end

  defp apply_to_repositories(installation, context) do
    Repository
    |> Ash.Query.filter(installation_id == ^installation.id)
    |> Ash.bulk_update(
      :apply_installation_defaults,
      %{},
      Ash.Context.to_opts(context,
        strategy: [:stream],
        return_errors?: true,
        notify?: true
      )
    )
    |> case do
      %Ash.BulkResult{status: :success} -> {:ok, installation}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end
end
