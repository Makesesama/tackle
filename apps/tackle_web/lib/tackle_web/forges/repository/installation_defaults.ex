defmodule Tackle.Web.Forges.Repository.InstallationDefaults do
  @moduledoc """
  Sets a repository's `enabled` and `auto_review` from its installation's
  `review_new_repositories` and `default_auto_review`.

  On `:sync` this only affects an inserted row: the upsert does not update
  these fields on an existing repository.
  """

  use Ash.Resource.Change

  alias Tackle.Web.Forges.Installation

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      installation_id = Ash.Changeset.get_attribute(changeset, :installation_id)

      case Ash.get(Installation, installation_id) do
        {:ok, installation} ->
          Ash.Changeset.force_change_attributes(changeset,
            enabled: installation.review_new_repositories,
            auto_review: installation.default_auto_review
          )

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end
end
