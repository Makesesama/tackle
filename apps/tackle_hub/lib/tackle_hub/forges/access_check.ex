defmodule Tackle.Hub.Forges.AccessCheck do
  @moduledoc """
  The policy filter for who may see or manage an installation's records
  (docs/TACKLE_HUB_PLAN.md §7.12): the installation's owner, and for
  reading, users holding a `Tackle.Hub.Forges.Access` grant on it.

  Options:

    * `:at` - what the check starts from: `:installation` or `:repository`.
    * `:path` - the relationship path from the policy's resource to that
      record, for example `[:repository]` on a review request (default `[]`).
    * `:role` - `:owner` passes only for the owner; `:reader` (the default)
      also for grantees: a grant on the whole installation (no repository)
      or, from a repository, a grant on that repository.

  Owners and grantees are matched by the forge's user id, never by login.
  It reads the actor's fields as given; combine it with
  `{Tackle.Hub.Accounts.Check, role: :user}` so that a user deleted since the
  actor was loaded is refused.
  """

  use Ash.Policy.FilterCheck

  import Ash.Expr

  alias Ash.Query.Exists
  alias Tackle.Hub.Accounts.User

  @impl Ash.Policy.Check
  def describe(opts) do
    role = Keyword.get(opts, :role, :reader)

    "actor is the #{if role == :owner, do: "owner", else: "owner or a grantee"} of the #{opts[:at]}"
  end

  @impl Ash.Policy.FilterCheck
  def filter(actor, _context, opts), do: visible(actor, opts)

  @doc """
  The check's filter for `user`, with the check's options, for queries that
  want only what a user owns or was granted (the policies also let admins
  read everything).
  """
  @spec visible(User.t() | term(), keyword()) :: Ash.Expr.t()
  def visible(%User{forge: forge, external_id: user_id}, opts) when is_binary(user_id) do
    expression =
      expression(Keyword.fetch!(opts, :at), Keyword.get(opts, :role, :reader), forge, user_id)

    # From a related resource: the record at the end of the (to-one) path
    # must match.
    case Keyword.get(opts, :path, []) do
      [] -> expression
      path -> Exists.new(path, expression)
    end
  end

  def visible(_actor, _opts), do: expr(false)

  defp expression(:installation, :owner, forge, user_id),
    do: expr(forge == ^forge and owner_external_id == ^user_id)

  defp expression(:installation, :reader, forge, user_id) do
    expr(
      forge == ^forge and
        (owner_external_id == ^user_id or exists(accesses, forge_user_id == ^user_id))
    )
  end

  defp expression(:repository, :owner, forge, user_id),
    do: expr(installation.forge == ^forge and installation.owner_external_id == ^user_id)

  defp expression(:repository, :reader, forge, user_id) do
    expr(
      installation.forge == ^forge and
        (installation.owner_external_id == ^user_id or
           exists(accesses, forge_user_id == ^user_id) or
           exists(installation.accesses, forge_user_id == ^user_id and is_nil(repository_id)))
    )
  end
end
