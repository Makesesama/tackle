defmodule Tackle.Web.Reviews.Dismissal do
  @moduledoc """
  A finding that is not to be reported again in a repository
  (docs/TACKLE_WEB_PLAN.md §7.13), by its fingerprint: every review of the
  repository passes the dismissed fingerprints to `Tackle.Review.run/2` as
  `:known_fingerprints`.

  `source` says where it was dismissed: `:forge` when someone with write
  access resolved the finding's thread on the pull request
  (`Tackle.Web.Feedback`), `:web` when the installation's owner dismissed it
  on the review page. `by` is that person's login; `title` and
  `pull_number` are the finding's, for display.

  `:dismiss` is an upsert per repository and fingerprint. With an actor it
  needs the installation's owner, and the source and login are the actor's;
  trusted code (the feedback job) passes them. The owner and admins
  `:restore`.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Reviews,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  alias Tackle.Web.Accounts.Check
  alias Tackle.Web.Forges.{AccessCheck, OwnerCheck, Repository}

  postgres do
    table "dismissals"
    repo Tackle.Web.Repo

    references do
      reference :repository, on_delete: :delete
    end
  end

  admin do
    table_columns [:repository_id, :title, :source, :by, :pull_number, :inserted_at]
    create_actions []
    update_actions []
    destroy_actions [:restore]
  end

  code_interface do
    define :dismiss, args: [:repository_id, :fingerprint]
    define :restore
    define :get, action: :read, get_by: [:repository_id, :fingerprint], not_found_error?: false
  end

  actions do
    defaults [:read]

    create :dismiss do
      accept [:repository_id, :fingerprint, :title, :pull_number, :source, :by]
      upsert? true
      upsert_identity :unique_fingerprint
      upsert_fields [:title, :pull_number, :source, :by, :updated_at]
      change Tackle.Web.Reviews.Dismissal.ByActor
    end

    destroy :restore do
      primary? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Check, role: :admin}
      forbid_unless {Check, role: :user}
      authorize_if {AccessCheck, at: :repository, path: [:repository]}
    end

    policy action(:dismiss) do
      forbid_unless {Check, role: :user}
      authorize_if {OwnerCheck, attribute: :repository_id}
    end

    policy action(:restore) do
      authorize_if {Check, role: :admin}
      forbid_unless {Check, role: :user}
      authorize_if {AccessCheck, at: :repository, path: [:repository], role: :owner}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :fingerprint, :string do
      allow_nil? false
      public? true
    end

    attribute :title, :string do
      public? true
    end

    attribute :pull_number, :integer do
      public? true
      constraints min: 1
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:forge, :web]
    end

    attribute :by, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :repository, Repository do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_fingerprint, [:repository_id, :fingerprint]
  end
end
