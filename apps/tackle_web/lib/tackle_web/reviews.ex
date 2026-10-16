defmodule Tackle.Web.Reviews do
  @moduledoc """
  Review requests from forge events and commands, the runs that answer them,
  their findings, and the outcomes recorded for those findings
  (docs/TACKLE_WEB_PLAN.md §6).
  """

  use Ash.Domain, otp_app: :tackle_web

  resources do
  end
end
