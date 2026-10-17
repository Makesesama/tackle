defmodule Tackle.Web.Reviews.Finding do
  @moduledoc "A shown, rejected, or verified-but-hidden finding from one run."
  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Reviews,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  postgres do
    table "findings"
    repo Tackle.Web.Repo

    references do
      reference :run, on_delete: :delete
    end
  end

  admin do
    table_columns [:state, :severity, :blocking, :title, :path, :start_line, :fingerprint]
    create_actions []
    update_actions []
    destroy_actions []
  end

  actions do
    defaults [:read, create: :*]

    # Internal: written by Tackle.Web.ReviewJob.Store when a review is posted.
    update :record_comment do
      accept [:forge_comment_id]
      require_atomic? false
    end
  end

  policies do
    # Admins, and whoever may read the repository (docs/TACKLE_WEB_PLAN.md
    # §7.12).
    policy action_type(:read) do
      authorize_if {Tackle.Web.Accounts.Check, role: :admin}
      forbid_unless {Tackle.Web.Accounts.Check, role: :user}

      authorize_if {Tackle.Web.Forges.AccessCheck,
                    at: :repository, path: [:run, :request, :repository]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :fingerprint, :string, allow_nil?: false, public?: true

    attribute :state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:shown, :rejected, :hidden]
    end

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :category, :atom, allow_nil?: false, public?: true
    attribute :severity, :atom, allow_nil?: false, public?: true
    attribute :blocking, :boolean, allow_nil?: false, public?: true
    attribute :confidence, :float, allow_nil?: false, public?: true
    attribute :rule_id, :string, public?: true
    attribute :path, :string, allow_nil?: false, public?: true
    attribute :side, :atom, allow_nil?: false, public?: true
    attribute :start_line, :integer, allow_nil?: false, public?: true
    attribute :end_line, :integer, allow_nil?: false, public?: true
    attribute :trigger, :string, allow_nil?: false, public?: true
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :suggestion, :string, public?: true
    attribute :support, :integer, allow_nil?: false, public?: true
    attribute :verdict, :atom, public?: true
    attribute :evidence, :string, public?: true
    attribute :hidden_reason, :map, public?: true
    attribute :forge_comment_id, :string, public?: true
    timestamps()
  end

  relationships do
    belongs_to :run, Tackle.Web.Reviews.ReviewRun, allow_nil?: false, public?: true
  end
end
