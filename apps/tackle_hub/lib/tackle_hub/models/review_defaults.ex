defmodule Tackle.Hub.Models.ReviewDefaults do
  @moduledoc """
  A user's stage model references and thinking levels, in the JSON shape of
  `Tackle.Review.Settings`: one row per user (docs/TACKLE_HUB_PLAN.md
  §7.12). Reviews of an installation's repositories use its owner's
  defaults, validated against the owner's enabled providers. Partial
  configuration can be saved; `Tackle.Hub.Models.resolve_settings/3` refuses
  to run without detector and verifier models. No model is implicitly
  selected.

  Users configure and read their own defaults; admins read everyone's.
  Trusted code without an actor passes `user_id`.
  """

  use Ash.Resource,
    otp_app: :tackle_hub,
    domain: Tackle.Hub.Models,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource],
    simple_notifiers: [Tackle.Hub.Updates]

  postgres do
    table "review_defaults"
    repo Tackle.Hub.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  # `:configure` is an upsert of the user's row: the admin interface offers
  # it as the create action, which also replaces existing defaults.
  admin do
    table_columns [:user_id, :models, :thinking, :updated_at]
    create_actions [:configure]
    update_actions []
    destroy_actions []
  end

  code_interface do
    define :configure
    define :get, action: :read, get_by: [:user_id], not_found_error?: false
  end

  actions do
    defaults [:read]

    create :configure do
      accept [:user_id, :models, :thinking]
      upsert? true
      upsert_fields [:models, :thinking, :updated_at]
      change {Tackle.Hub.Accounts.ActorOwns, attribute: :user_id}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Tackle.Hub.Accounts.Check, role: :admin}
      forbid_unless {Tackle.Hub.Accounts.Check, role: :user}
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action(:configure) do
      forbid_unless {Tackle.Hub.Accounts.Check, role: :user}
      authorize_if relating_to_actor(:user)
    end
  end

  validations do
    validate Tackle.Hub.Models.ValidateDefaults
  end

  attributes do
    attribute :models, :map do
      public? true
      allow_nil? false
      default %{}
    end

    attribute :thinking, :map do
      public? true
      allow_nil? false
      default %{}
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Tackle.Hub.Accounts.User do
      primary_key? true
      allow_nil? false
      public? true
    end
  end
end
