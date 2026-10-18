defmodule Tackle.Hub.Accounts do
  @moduledoc """
  People who sign in to the app through the forge
  (docs/TACKLE_HUB_PLAN.md §6, §7.6).

  Like every domain of the app, authorisation runs when an actor is given
  (`authorize :when_requested`): the web interface always passes the
  signed-in user, and the resources' policies decide. Calls without an actor
  are trusted server code (jobs, webhooks, the console).
  """

  use Ash.Domain, otp_app: :tackle_hub, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Tackle.Hub.Accounts.User
  end

  authorization do
    authorize :when_requested
  end
end
