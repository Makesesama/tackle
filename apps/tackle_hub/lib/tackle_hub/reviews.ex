defmodule Tackle.Hub.Reviews do
  @moduledoc """
  Review requests from forge events and commands, the runs that answer them,
  their findings, and the findings dismissed in a repository
  (docs/TACKLE_HUB_PLAN.md §6, §7.13).
  """

  use Ash.Domain, otp_app: :tackle_hub, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Tackle.Hub.Reviews.ReviewRequest
    resource Tackle.Hub.Reviews.ReviewRun
    resource Tackle.Hub.Reviews.Finding
    resource Tackle.Hub.Reviews.Dismissal
  end

  # Authorise when an actor is given; see Tackle.Hub.Accounts.
  authorization do
    authorize :when_requested
  end
end
