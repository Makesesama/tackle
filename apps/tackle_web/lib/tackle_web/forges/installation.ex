defmodule Tackle.Web.Forges.Installation do
  @moduledoc """
  An installation of the forge app on one account (a GitHub organisation or
  user), with the defaults that repositories get when they are added to it
  (docs/TACKLE_WEB_PLAN.md §6). Every repository, and through them every
  review, hangs off an installation.

  Rows are kept when the app is uninstalled (`status: :removed`), so the
  review history stays.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Forges,
    data_layer: AshPostgres.DataLayer

  alias Tackle.Web.Forges.Repository

  postgres do
    table "installations"
    repo Tackle.Web.Repo
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
