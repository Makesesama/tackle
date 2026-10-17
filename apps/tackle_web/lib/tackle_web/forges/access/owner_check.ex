defmodule Tackle.Web.Forges.Access.OwnerCheck do
  @moduledoc """
  Policy check for `Access.grant`: the actor owns the installation the new
  grant is for. The installation is read again, and the actor is compared by
  forge and forge user id.
  """

  use Ash.Policy.SimpleCheck

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Forges.Installation

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor owns the installation"

  @impl Ash.Policy.SimpleCheck
  def match?(
        %User{forge: forge, external_id: user_id},
        %{subject: %Ash.Changeset{} = changeset},
        _opts
      )
      when is_binary(user_id) do
    with id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :installation_id),
         {:ok, %Installation{forge: ^forge, owner_external_id: ^user_id}} <-
           Ash.get(Installation, id, not_found_error?: false) do
      true
    else
      _other -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
