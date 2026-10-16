defmodule Tackle.Web.Models.Provider do
  @moduledoc """
  An allowlisted adapter instance. Id and adapter are immutable; settings and
  enablement can change without replacing credentials. Secrets are only loaded
  explicitly by `Tackle.Web.CredentialStore`, never by normal reads.

  These are trusted server actions, not an authorisation boundary. Do not expose
  them through a router or AshAdmin before phase 6's admin policies exist.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Models,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak]

  postgres do
    table "providers"
    repo Tackle.Web.Repo
  end

  cloak do
    vault Tackle.Web.Vault
    attributes [:credentials]
  end

  code_interface do
    define :register, args: [:id, :adapter]
    define :get, action: :read, get_by: [:id], not_found_error?: false
    define :configure
    define :set_credentials, args: [:api_key]
    define :store_credentials, args: [:credentials]
  end

  actions do
    defaults [:read]

    create :register do
      accept [:id, :adapter, :settings, :enabled]
    end

    update :configure do
      accept [:settings, :enabled]
      require_atomic? false
    end

    update :set_credentials do
      accept []
      require_atomic? false

      argument :api_key, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 1
      end

      validate attribute_equals(:adapter, :openrouter)

      change fn changeset, _context ->
        AshCloak.encrypt_and_set(changeset, :credentials, %{
          "api_key" => Ash.Changeset.get_argument(changeset, :api_key)
        })
      end
    end

    # Internal store seam for opaque OAuth credentials and deletion (nil).
    update :store_credentials do
      accept [:credentials]
      require_atomic? false
    end
  end

  validations do
    validate Tackle.Web.Models.ValidateProvider
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :adapter, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:openrouter, :codex]
    end

    attribute :settings, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :credentials, :map do
      sensitive? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default false
    end

    timestamps()
  end
end
