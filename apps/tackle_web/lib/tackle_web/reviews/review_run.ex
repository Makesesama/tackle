defmodule Tackle.Web.Reviews.ReviewRun do
  @moduledoc "A completed review, retained across manual reruns (plan §6)."
  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Reviews,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource],
    simple_notifiers: [Tackle.Web.Updates]

  postgres do
    table "review_runs"
    repo Tackle.Web.Repo

    references do
      reference :request, on_delete: :delete
    end
  end

  admin do
    table_columns [:request_id, :verdict, :duration_ms, :inserted_at]
    create_actions []
    update_actions []
    destroy_actions []
  end

  actions do
    defaults [:read, create: [:request_id, :summary, :usage, :duration_ms, :verdict]]

    # Internal: the posted review frozen in the summary, written only by
    # Tackle.Web.ReviewJob.Store's short transactions.
    update :record_posting do
      accept [:summary]
      require_atomic? false
    end
  end

  policies do
    # Admins, and whoever may read the repository (docs/TACKLE_WEB_PLAN.md
    # §7.12).
    policy action_type(:read) do
      authorize_if {Tackle.Web.Accounts.Check, role: :admin}
      forbid_unless {Tackle.Web.Accounts.Check, role: :user}
      authorize_if {Tackle.Web.Forges.AccessCheck, at: :repository, path: [:request, :repository]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :summary, :map, allow_nil?: false, public?: true
    attribute :usage, :map, allow_nil?: false, public?: true
    attribute :duration_ms, :integer, allow_nil?: false, public?: true, constraints: [min: 0]

    attribute :verdict, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:blocking, :optional, :clean]
    end

    timestamps()
  end

  relationships do
    belongs_to :request, Tackle.Web.Reviews.ReviewRequest, allow_nil?: false, public?: true
    has_many :findings, Tackle.Web.Reviews.Finding, destination_attribute: :run_id, public?: true
  end

  aggregates do
    # The findings posted on the forge.
    count :shown_findings, :findings do
      filter expr(state == :shown)
      public? true
    end
  end
end
