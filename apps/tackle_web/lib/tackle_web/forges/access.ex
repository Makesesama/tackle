defmodule Tackle.Web.Forges.Access do
  @moduledoc """
  Read access to an installation's repositories and their reviews, granted
  by the installation's owner to another forge user
  (docs/TACKLE_WEB_PLAN.md §7.12).

  A grant without a `repository` covers every repository of the
  installation, including ones added later; with one, only that repository.
  The grantee is matched by the forge's user id (`forge_user_id`), which
  `:grant` resolves from a login through the forge (`c:Tackle.Web.Forge.user/3`),
  so a grant works before the grantee first signs in and survives renames.
  `login` is the login when it was granted, for display.

  Only the owner grants (`:grant`, which is idempotent per scope and user);
  the owner and admins revoke (`:revoke`), which takes effect at the next
  read. The owner, admins, and the grantee can read a grant.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Forges,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  alias Tackle.Web.Accounts.{Check, User}
  alias Tackle.Web.Forges.{AccessCheck, Installation, Repository}

  postgres do
    table "accesses"
    repo Tackle.Web.Repo

    references do
      reference :installation, on_delete: :delete
      reference :repository, on_delete: :delete
      reference :granted_by, on_delete: :nilify
    end
  end

  admin do
    table_columns [:login, :installation_id, :repository_id, :granted_by_id, :inserted_at]
    create_actions []
    update_actions []
    destroy_actions [:revoke]
  end

  code_interface do
    define :grant, args: [:installation_id, :login]
    define :revoke
  end

  actions do
    defaults [:read]

    # `repository_id` nil grants the whole installation.
    create :grant do
      accept [:installation_id, :repository_id]

      argument :login, :string do
        allow_nil? false
        constraints min_length: 1, max_length: 100
      end

      upsert? true
      upsert_identity :unique_grant
      upsert_fields [:login, :granted_by_id, :updated_at]

      change Tackle.Web.Forges.Access.Resolve
      change relate_actor(:granted_by, allow_nil?: true)
    end

    destroy :revoke do
      primary? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Check, role: :admin}
      forbid_unless {Check, role: :user}
      authorize_if {AccessCheck, at: :installation, role: :owner, path: [:installation]}

      authorize_if expr(
                     forge_user_id == ^actor(:external_id) and
                       installation.forge == ^actor(:forge)
                   )
    end

    policy action(:grant) do
      forbid_unless {Check, role: :user}
      authorize_if Tackle.Web.Forges.Access.OwnerCheck
    end

    policy action(:revoke) do
      authorize_if {Check, role: :admin}
      forbid_unless {Check, role: :user}
      authorize_if {AccessCheck, at: :installation, role: :owner, path: [:installation]}
    end
  end

  attributes do
    uuid_primary_key :id

    # The forge's id for the grantee.
    attribute :forge_user_id, :string do
      allow_nil? false
      public? true
    end

    # The grantee's login when it was granted.
    attribute :login, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :installation, Installation do
      allow_nil? false
      public? true
    end

    belongs_to :repository, Repository do
      public? true
    end

    belongs_to :granted_by, User do
      public? true
    end
  end

  identities do
    identity :unique_grant, [:installation_id, :repository_id, :forge_user_id],
      nils_distinct?: false
  end
end
