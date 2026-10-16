defmodule Tackle.Web.Models do
  @moduledoc """
  Model providers with their encrypted credentials, and the default models
  and thinking levels of the review stages (docs/TACKLE_WEB_PLAN.md §6,
  §7.2).
  """

  use Ash.Domain, otp_app: :tackle_web

  resources do
  end
end
