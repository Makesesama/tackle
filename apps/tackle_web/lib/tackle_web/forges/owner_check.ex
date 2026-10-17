defmodule Tackle.Web.Forges.OwnerCheck do
  @moduledoc """
  Policy check for creating a record that belongs to an installation the
  actor must own (docs/TACKLE_WEB_PLAN.md §7.12): the changeset names the
  installation directly (`attribute: :installation_id`) or through a
  repository (`attribute: :repository_id`). The installation is read again,
  and the actor is compared by forge and forge user id
  (`Tackle.Web.Forges.Installation.owned_by?/2`).
  """

  use Ash.Policy.SimpleCheck

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Forges.{Installation, Repository}

  @impl Ash.Policy.Check
  def describe(opts), do: "actor owns the installation of #{opts[:attribute]}"

  @impl Ash.Policy.SimpleCheck
  def match?(%User{} = user, %{subject: %Ash.Changeset{} = changeset}, opts) do
    attribute = Keyword.fetch!(opts, :attribute)

    case installation(attribute, Ash.Changeset.get_attribute(changeset, attribute)) do
      %Installation{} = installation -> Installation.owned_by?(installation, user)
      nil -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp installation(:installation_id, id) when is_binary(id),
    do: read(Installation, id, [])

  defp installation(:repository_id, id) when is_binary(id) do
    case read(Repository, id, load: [:installation]) do
      %Repository{installation: installation} -> installation
      nil -> nil
    end
  end

  defp installation(_attribute, _id), do: nil

  defp read(resource, id, opts) do
    case Ash.get(resource, id, [not_found_error?: false] ++ opts) do
      {:ok, record} -> record
      {:error, _invalid} -> nil
    end
  end
end
