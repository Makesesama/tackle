defmodule Tackle.Web.Forges.Repository do
  @moduledoc """
  A repository the forge app can access, with its review settings
  (docs/TACKLE_WEB_PLAN.md §6, §7.7).

  A repository added to an installation takes the installation's defaults:
  `enabled` from `review_new_repositories` and `auto_review` from
  `default_auto_review`. Later syncs from forge events only update its
  owner, name, and whether the app can still access it (`active`), never
  its settings.

  `settings` is the JSON form of `Tackle.Review.Settings` (string keys, as
  `Tackle.Review.Settings.from_json/1` takes it) without `profile`, which is
  the `profile` attribute. See `Tackle.Web.Forges.Repository.ValidateSettings`
  for what is checked when it is written.

  Admins, the installation's owner, and users holding a grant on the
  installation or the repository (`Tackle.Web.Forges.Access`) can read it;
  admins and the owner configure it (docs/TACKLE_WEB_PLAN.md §7.12).
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Forges,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  alias Tackle.Web.Accounts.Check
  alias Tackle.Web.Forges.{Access, AccessCheck, AutoReview, Installation}

  postgres do
    table "repositories"
    repo Tackle.Web.Repo

    references do
      reference :installation, on_delete: :delete
    end
  end

  admin do
    table_columns [
      :owner,
      :name,
      :active,
      :enabled,
      :auto_review,
      :profile,
      :daily_token_budget,
      :installation_id
    ]

    create_actions []
    update_actions [:configure, :apply_installation_defaults]
    destroy_actions []
  end

  code_interface do
    define :sync, args: [:installation_id, :external_id, :owner, :name]

    define :get_external,
      action: :read,
      get_by: [:installation_id, :external_id],
      not_found_error?: false

    define :deactivate
    define :configure
    define :apply_installation_defaults
  end

  actions do
    defaults [:read]

    # From forge events: records the repository with the installation's
    # defaults, or updates its owner, name, and access on an existing one.
    create :sync do
      accept [:installation_id, :external_id, :owner, :name]
      upsert? true
      upsert_identity :unique_external_id
      upsert_fields [:owner, :name, :active, :updated_at]
      change set_attribute(:active, true)
      change Tackle.Web.Forges.Repository.InstallationDefaults
    end

    # The app lost access (the repository was removed from the installation).
    update :deactivate do
      accept []
      change set_attribute(:active, false)
    end

    update :configure do
      accept [
        :enabled,
        :auto_review,
        :auto_review_forks,
        :auto_review_drafts,
        :profile,
        :settings,
        :daily_token_budget
      ]
    end

    # Resets `enabled` and `auto_review` to the installation's current
    # defaults, as for a newly added repository.
    update :apply_installation_defaults do
      accept []
      require_atomic? false
      change Tackle.Web.Forges.Repository.InstallationDefaults
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Check, role: :admin}
      forbid_unless {Check, role: :user}
      authorize_if {AccessCheck, at: :repository}
    end

    policy action([:configure, :apply_installation_defaults]) do
      authorize_if {Check, role: :admin}
      forbid_unless {Check, role: :user}
      authorize_if {AccessCheck, at: :repository, role: :owner}
    end
  end

  validations do
    validate Tackle.Web.Forges.Repository.ValidateSettings do
      where changing(:settings)
    end
  end

  attributes do
    uuid_primary_key :id

    # The forge's id for the repository; stable across renames.
    attribute :external_id, :string do
      allow_nil? false
      public? true
    end

    attribute :owner, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    # Whether the app can still access the repository.
    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    # Whether pull requests are reviewed at all, by command or automatically.
    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :auto_review, AutoReview do
      allow_nil? false
      public? true
      default :off
    end

    # Whether automatic reviews cover pull requests from forks.
    attribute :auto_review_forks, :boolean do
      allow_nil? false
      public? true
      default false
    end

    # Whether automatic reviews cover draft pull requests.
    attribute :auto_review_drafts, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :profile, Tackle.Web.Reviews.Profile do
      allow_nil? false
      public? true
      default :default
    end

    attribute :settings, :map do
      allow_nil? false
      public? true
      default %{}
    end

    # Model tokens the repository's reviews may use per day; nil for no limit.
    attribute :daily_token_budget, :integer do
      public? true
      constraints min: 0
    end

    timestamps()
  end

  relationships do
    belongs_to :installation, Installation do
      allow_nil? false
      public? true
    end

    has_many :requests, Tackle.Web.Reviews.ReviewRequest do
      public? true
    end

    # The most recently changed review request, for the overview.
    has_one :latest_request, Tackle.Web.Reviews.ReviewRequest do
      from_many? true
      sort updated_at: :desc
      public? true
    end

    # Grants on this repository alone; grants on the whole installation are
    # the installation's.
    has_many :accesses, Access do
      public? true
    end
  end

  identities do
    identity :unique_external_id, [:installation_id, :external_id]
  end
end
