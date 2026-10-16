defmodule Tackle.Web.Reviews do
  @moduledoc """
  Review requests from forge events and commands, the runs that answer them,
  their findings, and the outcomes recorded for those findings
  (docs/TACKLE_WEB_PLAN.md §6).
  """

  use Ash.Domain, otp_app: :tackle_web, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Tackle.Web.Reviews.ReviewRequest
    resource Tackle.Web.Reviews.ReviewRun
    resource Tackle.Web.Reviews.Finding
  end

  # Authorise when an actor is given; see Tackle.Web.Accounts.
  authorization do
    authorize :when_requested
  end
end
