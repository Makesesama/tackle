defmodule Tackle.Web.Models.Provider do
  @moduledoc """
  An allowlisted adapter instance owned by a user (docs/TACKLE_WEB_PLAN.md
  §7.12). `name` is the `Tackle.Lib.LLM.Provider` id that model references
  start with (`openrouter/...`); it is unique per owner, so every user can
  have an `openrouter` provider. Reviews of an installation's repositories
  use only its owner's enabled providers. Name, owner, and adapter are
  immutable; settings and enablement can change without replacing
  credentials. Secrets are only loaded explicitly by
  `Tackle.Web.CredentialStore`, never by normal reads.

  Signed-in users `:register` providers for themselves, and `:configure`
  and `:set_credentials` (an OpenRouter API key, write-only) their own;
  admins can read every provider but not change other users' ones. A
  provider is enabled when it first gets credentials, and `connected` says
  whether it has them without decrypting them.
  `:store_credentials` is the credential store's internal seam, and
  decryption with an actor is refused (`Tackle.Web.Vault.authorize_decrypt/4`).
  Codex credentials come from the device login page
  (`Tackle.Web.CodexLoginLive`). Trusted code without an actor passes
  `owner_id` to `:register`.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Models,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak, AshAdmin.Resource],
    simple_notifiers: [Tackle.Web.Updates]

  postgres do
    table "providers"
    repo Tackle.Web.Repo

    references do
      reference :owner, on_delete: :delete
    end
  end

  cloak do
    vault Tackle.Web.Vault
    attributes [:credentials]
    on_decrypt {Tackle.Web.Vault, :authorize_decrypt, []}
    # Deleted credentials are SQL NULL, so `connected` can tell.
    encrypt_nil? false
  end

  admin do
    table_columns [:name, :owner_id, :adapter, :enabled, :updated_at]
    create_actions [:register]
    update_actions [:configure, :set_credentials]
    destroy_actions []
  end

  code_interface do
    define :register, args: [:name, :adapter]
    define :get, action: :read, get_by: [:id], not_found_error?: false
    define :get_named, action: :read, get_by: [:owner_id, :name], not_found_error?: false
    define :configure
    define :set_credentials, args: [:api_key]
    define :store_credentials, args: [:credentials]
  end

  actions do
    defaults [:read]

    create :register do
      accept [:name, :owner_id, :adapter, :settings, :enabled]
      change {Tackle.Web.Accounts.ActorOwns, attribute: :owner_id}
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

      change &enable_when_first_connected/2
    end

    # Internal store seam for opaque OAuth credentials and deletion (nil).
    update :store_credentials do
      accept [:credentials]
      require_atomic? false

      change &enable_when_first_connected/2
    end
  end

  # A provider is enabled when it first gets credentials, as it was of no use
  # without them; one disabled later stays disabled when they change. A
  # before-action hook, so it sees the credentials whichever change
  # (AshCloak's or the action's) encrypts them.
  defp enable_when_first_connected(changeset, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      stored? = not is_nil(changeset.data.encrypted_credentials)
      storing? = not is_nil(Ash.Changeset.get_attribute(changeset, :encrypted_credentials))

      if storing? and not stored?,
        do: Ash.Changeset.force_change_attribute(changeset, :enabled, true),
        else: changeset
    end)
  end

  policies do
    policy action_type(:read) do
      authorize_if {Tackle.Web.Accounts.Check, role: :admin}
      forbid_unless {Tackle.Web.Accounts.Check, role: :user}
      authorize_if expr(owner_id == ^actor(:id))
    end

    policy action(:register) do
      forbid_unless {Tackle.Web.Accounts.Check, role: :user}
      authorize_if relating_to_actor(:owner)
    end

    policy action([:configure, :set_credentials]) do
      forbid_unless {Tackle.Web.Accounts.Check, role: :user}
      authorize_if expr(owner_id == ^actor(:id))
    end
  end

  validations do
    validate Tackle.Web.Models.ValidateProvider
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
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

  relationships do
    belongs_to :owner, Tackle.Web.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  calculations do
    # Whether credentials are stored, without decrypting them.
    calculate :connected, :boolean, expr(not is_nil(encrypted_credentials)) do
      public? true
    end
  end

  identities do
    identity :unique_name, [:owner_id, :name]
  end
end
