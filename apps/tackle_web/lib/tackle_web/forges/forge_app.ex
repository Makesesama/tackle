defmodule Tackle.Web.Forges.ForgeApp do
  @moduledoc """
  The app's integration with one forge: for GitHub, the GitHub App the
  reviews run as (docs/TACKLE_WEB_PLAN.md §7.1). One row per forge.

  The private key, webhook secret, and OAuth client secret are encrypted
  with `Tackle.Web.Vault` (AshCloak) and sensitive. Actions accept them as
  arguments; reading them back needs an explicit load of the matching
  calculation (`:private_key`, `:webhook_secret`, `:client_secret`), which
  only the forge modules do; a load with an actor is refused
  (`Tackle.Web.Vault.authorize_decrypt/4`).

  The admin interface shows the row read-only. Its secrets are set with
  `Tackle.Web.Release.configure_github_app/0`, which reads them from files:
  a multi-line PEM key does not fit a password field.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Forges,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak, AshAdmin.Resource]

  postgres do
    table "forge_apps"
    repo Tackle.Web.Repo
  end

  cloak do
    vault Tackle.Web.Vault
    attributes [:private_key, :webhook_secret, :client_secret]
    on_decrypt {Tackle.Web.Vault, :authorize_decrypt, []}
  end

  admin do
    table_columns [:forge, :app_id, :client_id, :updated_at]
    create_actions []
    update_actions []
    destroy_actions []
  end

  code_interface do
    define :configure, args: [:forge]
    define :register, args: [:forge]
    define :get, action: :read, get_by: [:forge], not_found_error?: false
  end

  actions do
    defaults [:read]

    # Web setup (Tackle.Web.Setup): stores a newly registered app. Unlike
    # :configure it never replaces one, so two setups racing cannot
    # overwrite each other's secrets.
    create :register do
      accept [:forge, :app_id, :client_id, :private_key, :webhook_secret, :client_secret]
    end

    # Creates the forge's row or replaces its settings and secrets.
    create :configure do
      accept [:forge, :app_id, :client_id, :private_key, :webhook_secret, :client_secret]
      upsert? true
      upsert_identity :unique_forge

      upsert_fields [
        :app_id,
        :client_id,
        :encrypted_private_key,
        :encrypted_webhook_secret,
        :encrypted_client_secret,
        :updated_at
      ]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Tackle.Web.Accounts.Check, role: :user}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :forge, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:github]
    end

    # GitHub: the App ID, the `iss` of the app's JWTs.
    attribute :app_id, :string do
      allow_nil? false
      public? true
    end

    # GitHub: the App's OAuth client id, for sign-in.
    attribute :client_id, :string do
      public? true
    end

    # PEM; signs the app's JWTs.
    attribute :private_key, :string do
      allow_nil? false
      sensitive? true
    end

    # Signs webhook deliveries (X-Hub-Signature-256).
    attribute :webhook_secret, :string do
      allow_nil? false
      sensitive? true
    end

    # The App's OAuth client secret, for sign-in.
    attribute :client_secret, :string do
      sensitive? true
    end

    timestamps()
  end

  identities do
    identity :unique_forge, [:forge]
  end
end
