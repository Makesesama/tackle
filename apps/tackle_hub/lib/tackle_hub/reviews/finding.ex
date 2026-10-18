defmodule Tackle.Hub.Reviews.Finding do
  @moduledoc """
  A shown, rejected, or verified-but-hidden finding from one run. A shown
  finding posted as a line comment has its `forge_comment_id`, and the
  reactions on that comment as last read (docs/TACKLE_HUB_PLAN.md §7.13).
  """
  use Ash.Resource,
    otp_app: :tackle_hub,
    domain: Tackle.Hub.Reviews,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource],
    simple_notifiers: [Tackle.Hub.Updates]

  postgres do
    table "findings"
    repo Tackle.Hub.Repo

    references do
      reference :run, on_delete: :delete
    end

    # Feedback finds the findings behind a forge's comments (§7.13).
    custom_indexes do
      index [:forge_comment_id], where: "forge_comment_id IS NOT NULL"
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

    # Internal: written by Tackle.Hub.ReviewJob.Store when a review is posted.
    update :record_comment do
      accept [:forge_comment_id]
      require_atomic? false
    end

    # Internal: the reactions on the posted comment, read by Tackle.Hub.Feedback.
    update :record_reactions do
      accept [:reactions_up, :reactions_down]
    end
  end

  policies do
    # Admins, and whoever may read the repository (docs/TACKLE_HUB_PLAN.md
    # §7.12).
    policy action_type(:read) do
      authorize_if {Tackle.Hub.Accounts.Check, role: :admin}
      forbid_unless {Tackle.Hub.Accounts.Check, role: :user}

      authorize_if {Tackle.Hub.Forges.AccessCheck,
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
    # 👍 and 👎 on the posted comment when they were last read; nil before.
    attribute :reactions_up, :integer, public?: true, constraints: [min: 0]
    attribute :reactions_down, :integer, public?: true, constraints: [min: 0]
    timestamps()
  end

  relationships do
    belongs_to :run, Tackle.Hub.Reviews.ReviewRun, allow_nil?: false, public?: true
  end
end
