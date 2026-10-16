defmodule Tackle.Web.Forges.Installation do
  @moduledoc """
  An installation of the forge app on one account (a GitHub organisation or
  user), with the defaults that repositories get when they are added to it
  (docs/TACKLE_WEB_PLAN.md §6). Every repository, and through them every
  review, hangs off an installation.

  Rows are kept when the app is uninstalled (`status: :removed`), so the
  review history stays.

  Admins change the defaults with `:set_defaults`; with
  `apply_to_repositories: true` it also resets every existing repository of
  the installation to them, which turns on "review every pull request in the
  organisation" in one step (§7.7).
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Forges,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  alias Tackle.Web.Forges.Repository

  postgres do
    table "installations"
    repo Tackle.Web.Repo
  end

  admin do
    table_columns [
      :account,
      :forge,
      :status,
      :review_new_repositories,
      :default_auto_review,
      :updated_at
    ]

    create_actions []
    update_actions [:set_defaults]
    destroy_actions []
  end

  code_interface do
    define :sync, args: [:forge, :external_id, :account, :status]
    define :get_external, action: :read, get_by: [:forge, :external_id], not_found_error?: false
    define :set_defaults
  end

  actions do
    defaults [:read]

    # From forge events: records the installation, or updates its account and
    # status. The review defaults are only set on insert and kept afterwards.
    create :sync do
      accept [:forge, :external_id, :account, :status]
      upsert? true
      upsert_identity :unique_external_id
      upsert_fields [:account, :status, :updated_at]
    end

    update :set_defaults do
      accept [:review_new_repositories, :default_auto_review]
      require_atomic? false

      # Also reset the installation's existing repositories to the new
      # defaults, as `Repository.apply_installation_defaults` does for one.
      argument :apply_to_repositories, :boolean do
        allow_nil? false
        default false
      end

      change Tackle.Web.Forges.Installation.ApplyDefaults
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Tackle.Web.Accounts.Check, role: :user}
    end

    policy action(:set_defaults) do
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

    # The forge's id for the installation.
    attribute :external_id, :string do
      allow_nil? false
      public? true
    end

    # The login of the organisation or user the app is installed on.
    attribute :account, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :suspended, :removed]
    end

    # Whether a repository added to the installation is enabled for reviews.
    attribute :review_new_repositories, :boolean do
      allow_nil? false
      public? true
      default false
    end

    # The `auto_review` a repository added to the installation gets.
    attribute :default_auto_review, Tackle.Web.Forges.AutoReview do
      allow_nil? false
      public? true
      default :off
    end

    timestamps()
  end

  relationships do
    has_many :repositories, Repository do
      public? true
    end
  end

  identities do
    identity :unique_external_id, [:forge, :external_id]
  end
end
