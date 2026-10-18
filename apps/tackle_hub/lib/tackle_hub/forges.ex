defmodule Tackle.Hub.Forges do
  @moduledoc """
  Forge integrations and what they cover: installations of the app on a
  forge account and their repositories, with each repository's review
  settings (docs/TACKLE_HUB_PLAN.md §6), and who may read them
  (`Tackle.Hub.Forges.Access`, §7.12).
  """

  use Ash.Domain, otp_app: :tackle_hub, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Tackle.Hub.Forges.ForgeApp
    resource Tackle.Hub.Forges.Installation
    resource Tackle.Hub.Forges.Repository
    resource Tackle.Hub.Forges.Access
  end

  # Authorise when an actor is given; see Tackle.Hub.Accounts.
  authorization do
    authorize :when_requested
  end
end
