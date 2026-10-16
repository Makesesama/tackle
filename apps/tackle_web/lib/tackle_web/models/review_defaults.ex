defmodule Tackle.Web.Models.ReviewDefaults do
  @moduledoc """
  One server-wide row of stage model references and thinking levels, in the
  JSON shape of `Tackle.Review.Settings`. Partial configuration can be saved;
  `Tackle.Web.Models.resolve_settings/2` refuses to run without detector and
  verifier models. No model is implicitly selected.
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Models,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "review_defaults"
    repo Tackle.Web.Repo

    check_constraints do
      check_constraint :id, "review_defaults_singleton", check: "id = 1"
    end
  end

  code_interface do
    define :configure
    define :get, action: :read, get?: true, not_found_error?: false
  end

  actions do
    defaults [:read]

    create :configure do
      accept [:models, :thinking]
      upsert? true
      upsert_fields [:models, :thinking, :updated_at]
    end
  end

  validations do
    validate Tackle.Web.Models.ValidateDefaults
  end

  attributes do
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      default 1
      constraints min: 1, max: 1
    end

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
end
