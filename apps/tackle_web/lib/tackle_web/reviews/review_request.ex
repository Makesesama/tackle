defmodule Tackle.Web.Reviews.ReviewRequest do
  @moduledoc """
  A request to review one head of a pull request (docs/TACKLE_WEB_PLAN.md
  §6, §7.7), from a command or an automatic trigger.

  There is at most one request per repository, pull request, and head SHA,
  so redelivered webhooks and repeated commands do not review a head twice;
  `Tackle.Web.Triggers` decides when an existing request runs again.
  `profile` is the profile the review uses, resolved when the request is
  made: the command's, or the repository's.

  A queued job reviews the request (`:running`), stores the run
  (`:reviewed`), and posts it (`:posted`). A `:reviewed` request stays
  scheduled, so a failed posting is retried from the stored run without
  reviewing again; when its attempts are exhausted it fails with
  `Tackle.Web.ReviewJob.Store.posting_error/0`, which
  `Tackle.Web.ReviewJob.Store.retry_posting/1` resets.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Reviews,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban, AshAdmin.Resource]

  require Ash.Query

  alias Tackle.Web.Forges.Repository

  postgres do
    table "review_requests"
    repo Tackle.Web.Repo

    references do
      reference :repository, on_delete: :delete
    end
  end

  oban do
    triggers do
      trigger :run do
        scheduler_module_name Tackle.Web.Reviews.ReviewRequest.RunScheduler
        worker_module_name Tackle.Web.Reviews.ReviewRequest.RunWorker
        action :run
        queue :reviews
        where expr(status in [:pending, :running, :reviewed])
        lock_for_update? false
        max_attempts 3
        timeout 1_200_000
        on_error :run_failed
        on_error_fails_job? true

        worker_opts unique: [
                      fields: [:worker, :args],
                      keys: [:primary_key],
                      states: [:available, :scheduled, :executing, :retryable],
                      period: :infinity
                    ]
      end
    end
  end

  # Read-only in the admin interface: reruns and posting retries stay
  # console actions (see the app's README).
  admin do
    table_columns [
      :repository_id,
      :pull_number,
      :head_sha,
      :trigger,
      :profile,
      :status,
      :error,
      :updated_at
    ]

    create_actions []
    update_actions []
    destroy_actions []
  end

  code_interface do
    define :request

    define :get_head,
      action: :read,
      get_by: [:repository_id, :pull_number, :head_sha],
      not_found_error?: false

    define :rerun
    define :skip, args: [:reason]
  end

  actions do
    defaults [:read]

    create :request do
      accept [
        :repository_id,
        :pull_number,
        :head_sha,
        :base_sha,
        :base_ref,
        :head_is_fork,
        :trigger,
        :profile,
        :requested_by
      ]

      # Two deliveries racing for the same head find the row the first one
      # inserted instead of failing.
      upsert? true
      upsert_identity :unique_head
      upsert_fields []
    end

    update :run do
      accept []
      transaction? false
      require_atomic? false
      manual Tackle.Web.ReviewJob.Run
    end

    update :run_failed do
      accept []
      argument :error, :term
      transaction? false
      require_atomic? false
      manual Tackle.Web.ReviewJob.Failed
    end

    # Internal, fenced by ReviewJob.Store's short transactions.
    update :record_progress do
      accept [:status, :error, :forge_review_id, :claimed_job_id, :claimed_attempt]
      require_atomic? false
    end

    # Runs a finished request again (see Tackle.Web.Triggers). The status
    # check is part of the update, so a request another delivery or the
    # review job changed since it was read is not reset.
    update :rerun do
      accept [:trigger, :profile, :requested_by]

      validate attribute_in(:status, [:failed, :skipped, :reviewed, :posted]) do
        message "only a finished request can run again"
      end

      change set_attribute(:status, :pending)
      change set_attribute(:error, nil)
      change set_attribute(:forge_review_id, nil)
      change set_attribute(:claimed_job_id, nil)
      change set_attribute(:claimed_attempt, nil)
    end

    update :skip do
      accept []

      argument :reason, :string do
        allow_nil? false
      end

      validate attribute_equals(:status, :pending) do
        message "only a pending request can be skipped"
      end

      change set_attribute(:status, :skipped)
      change set_attribute(:error, arg(:reason))
    end
  end

  policies do
    # AshOban's scheduler and workers authorise without an actor.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Admins, and whoever may read the repository (docs/TACKLE_WEB_PLAN.md
    # §7.12).
    policy action_type(:read) do
      authorize_if {Tackle.Web.Accounts.Check, role: :admin}
      forbid_unless {Tackle.Web.Accounts.Check, role: :user}
      authorize_if {Tackle.Web.Forges.AccessCheck, at: :repository, path: [:repository]}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :pull_number, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :head_sha, :string do
      allow_nil? false
      public? true
    end

    attribute :base_sha, :string do
      allow_nil? false
      public? true
    end

    # The branch the pull request merges into.
    attribute :base_ref, :string do
      allow_nil? false
      public? true
    end

    # Whether the head comes from another repository (a fork).
    attribute :head_is_fork, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :trigger, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:command, :opened, :pushed]
    end

    attribute :profile, Tackle.Web.Reviews.Profile do
      allow_nil? false
      public? true
    end

    # The forge login that asked: the command's author or the pull request's
    # sender.
    attribute :requested_by, :string do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :running, :reviewed, :posted, :failed, :skipped]
    end

    # Why the request failed or was skipped.
    attribute :error, :string do
      public? true
    end

    # The forge's id for the posted review.
    attribute :forge_review_id, :string do
      public? true
    end

    attribute :claimed_job_id, :integer
    attribute :claimed_attempt, :integer

    timestamps()
  end

  relationships do
    belongs_to :repository, Repository do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_head, [:repository_id, :pull_number, :head_sha]
  end

  @doc """
  Skips the pending requests for other heads of a pull request: a newer
  head supersedes them, or the pull request was closed.
  """
  @spec skip_pending(Ecto.UUID.t(), pos_integer(), String.t() | nil, String.t()) ::
          :ok | {:error, term()}
  def skip_pending(repository_id, pull_number, keep_head_sha, reason) do
    __MODULE__
    |> Ash.Query.filter(
      repository_id == ^repository_id and pull_number == ^pull_number and status == :pending
    )
    |> then(fn query ->
      if keep_head_sha,
        do: Ash.Query.filter(query, head_sha != ^keep_head_sha),
        else: query
    end)
    |> Ash.bulk_update(:skip, %{reason: reason},
      return_errors?: true,
      strategy: [:atomic, :stream]
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end
end
