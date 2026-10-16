defmodule Tackle.Web.Forges do
  @moduledoc """
  Forge integrations and what they cover: installations of the app on a
  forge account and their repositories, with each repository's review
  settings (docs/TACKLE_WEB_PLAN.md §6).
  """

  use Ash.Domain, otp_app: :tackle_web, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Tackle.Web.Forges.ForgeApp
    resource Tackle.Web.Forges.Installation
    resource Tackle.Web.Forges.Repository
  end

  # Authorise when an actor is given; see Tackle.Web.Accounts.
  authorization do
    authorize :when_requested
  end
end
