defmodule Tackle.Web.Accounts.User do
  @moduledoc """
  Someone who signs in to the app with their forge account
  (docs/TACKLE_WEB_PLAN.md §6, §7.6). Created on first sign-in by a member
  of an account the forge app is installed on; later sign-ins update the
  login and name.

  `admin` may change settings. The first admin is whoever signs in from the
  browser that unlocked setup (`Tackle.Web.Setup`, `claim_admin`); admins
  grant and revoke it for others in the admin interface (`:set_admin`), which
  never removes the last admin. `Tackle.Web.Release.set_admin/2` is the
  console's recovery path.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  postgres do
    table "users"
    repo Tackle.Web.Repo
  end

  admin do
    table_columns [:login, :name, :admin, :forge, :last_signed_in_at]
    create_actions []
    update_actions [:set_admin]
    destroy_actions []
  end

  code_interface do
    define :sign_in
    define :get, action: :read, get_by: [:id], not_found_error?: false
    define :set_admin, args: [:admin]
  end

  actions do
    defaults [:read]

    # From a verified forge sign-in: records the user, or updates their login
    # and name. It never changes `admin`, except for a setup claim.
    create :sign_in do
      accept [:forge, :external_id, :login, :name]
      upsert? true
      upsert_identity :unique_external_id
      upsert_fields [:login, :name, :last_signed_in_at, :updated_at]

      argument :claim_admin, :boolean do
        allow_nil? false
        default false
      end

      change set_attribute(:last_signed_in_at, &DateTime.utc_now/0)
      change Tackle.Web.Accounts.User.ClaimAdmin
    end

    update :set_admin do
      accept [:admin]
      require_atomic? false
      change Tackle.Web.Accounts.User.KeepAnAdmin
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Tackle.Web.Accounts.Check, role: :user}
    end

    policy action(:set_admin) do
      authorize_if {Tackle.Web.Accounts.Check, role: :admin}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :forge, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:github]
    end

    # The forge's id for the account; stable across renames.
    attribute :external_id, :string do
      allow_nil? false
      public? true
    end

    attribute :login, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      public? true
    end

    attribute :admin, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :last_signed_in_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_external_id, [:forge, :external_id]
  end
end
