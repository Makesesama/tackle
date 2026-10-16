defmodule Tackle.Web.Reviews.ReviewRequest do
  @moduledoc """
  A request to review one head of a pull request (docs/TACKLE_WEB_PLAN.md
  §6, §7.7), from a command or an automatic trigger.

  There is at most one request per repository, pull request, and head SHA,
  so redelivered webhooks and repeated commands do not review a head twice;
  `Tackle.Web.Triggers` decides when an existing request runs again.
  `profile` is the profile the review uses, resolved when the request is
  made: the command's, or the repository's.

  The review job that runs `:pending` requests arrives in phase 4.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Reviews,
    data_layer: AshPostgres.DataLayer

  require Ash.Query

  alias Tackle.Web.Forges.Repository

  postgres do
    table "review_requests"
    repo Tackle.Web.Repo

    references do
      reference :repository, on_delete: :delete
    end
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

    # Runs a finished request again (see Tackle.Web.Triggers). The status
    # check is part of the update, so a request another delivery or the
    # review job changed since it was read is not reset.
    update :rerun do
      accept [:trigger, :profile, :requested_by]

      validate attribute_in(:status, [:failed, :skipped, :posted]) do
        message "only a finished request can run again"
      end

      change set_attribute(:status, :pending)
      change set_attribute(:error, nil)
      change set_attribute(:forge_review_id, nil)
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
