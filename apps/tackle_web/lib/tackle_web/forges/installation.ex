defmodule Tackle.Web.Forges.Installation do
  @moduledoc """
  An installation of the forge app on one account (a GitHub organisation or
  user), with the defaults that repositories get when they are added to it
  (docs/TACKLE_WEB_PLAN.md §6). Every repository, and through them every
  review, hangs off an installation.

  Rows are kept when the app is uninstalled (`status: :removed`), so the
  review history stays.

  Its owner (§7.12) is the forge user who installed the app, by the forge's
  user id (`owner_external_id`; `owner_login` is for display). Forge events
  and syncs record it once, through `:record_owner`, and never change it;
  admins can set it with `:set_owner`. The owner, and users holding a
  `Tackle.Web.Forges.Access` grant, can read the installation; reviews of
  an installation without an owner do not run.

  The owner and admins change the defaults with `:set_defaults`; with
  `apply_to_repositories: true` it also resets every existing repository of
  the installation to them, which turns on "review every pull request in the
  organisation" in one step (§7.7).
  """

  use Ash.Resource,
    otp_app: :tackle_web,
    domain: Tackle.Web.Forges,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  alias Tackle.Web.Accounts.{Check, User}
  alias Tackle.Web.Forges.{Access, AccessCheck, Repository}

  postgres do
    table "installations"
    repo Tackle.Web.Repo
  end

  admin do
    table_columns [
      :account,
      :owner_login,
      :forge,
      :status,
      :review_new_repositories,
      :default_auto_review,
      :updated_at
    ]

    create_actions []
    update_actions [:set_defaults, :set_owner]
    destroy_actions []
  end

  code_interface do
    define :sync, args: [:forge, :external_id, :account, :status]
    define :get_external, action: :read, get_by: [:forge, :external_id], not_found_error?: false
    define :set_defaults
    define :record_owner, args: [:owner_external_id, :owner_login]
    define :set_owner, args: [:user_id]
  end

  actions do
    defaults [:read]

    # From forge events: records the installation, or updates its account and
    # status. The review defaults are only set on insert and kept afterwards.
    create :sync do
      accept [:forge, :external_id, :account, :status]
      upsert? true
      upsert_identity :unique_external_id
      upsert_fields [:account, :status, :updated_at]
    end

    update :set_defaults do
      accept [:review_new_repositories, :default_auto_review]
      require_atomic? false

      # Also reset the installation's existing repositories to the new
      # defaults, as `Repository.apply_installation_defaults` does for one.
      argument :apply_to_repositories, :boolean do
        allow_nil? false
        default false
      end

      change Tackle.Web.Forges.Installation.ApplyDefaults
    end

    # Internal, from forge events and syncs: the first owner the forge
    # names. An installation that has one keeps it.
    update :record_owner do
      accept [:owner_external_id, :owner_login]
      require_atomic? false

      validate present([:owner_external_id, :owner_login])

      validate fn changeset, _context ->
        if is_nil(changeset.data.owner_external_id),
          do: :ok,
          else: {:error, field: :owner_external_id, message: "the installation has an owner"}
      end
    end

    # For admins: makes a user who signed in the owner, for an organisation
    # installation the forge did not name an owner for.
    update :set_owner do
      accept []
      require_atomic? false

      argument :user_id, :uuid do
        allow_nil? false
      end

      change Tackle.Web.Forges.Installation.SetOwner
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Check, role: :admin}
      forbid_unless {Check, role: :user}
      authorize_if {AccessCheck, at: :installation}
    end

    policy action(:set_defaults) do
      authorize_if {Check, role: :admin}
      forbid_unless {Check, role: :user}
      authorize_if {AccessCheck, at: :installation, role: :owner}
    end

    policy action(:set_owner) do
      authorize_if {Check, role: :admin}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :forge, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:github]
    end

    # The forge's id for the installation.
    attribute :external_id, :string do
      allow_nil? false
      public? true
    end

    # The login of the organisation or user the app is installed on.
    attribute :account, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :suspended, :removed]
    end

    # The forge's id for the user who installed the app, and their login
    # when it was recorded.
    attribute :owner_external_id, :string do
      public? true
    end

    attribute :owner_login, :string do
      public? true
    end

    # Whether a repository added to the installation is enabled for reviews.
    attribute :review_new_repositories, :boolean do
      allow_nil? false
      public? true
      default false
    end

    # The `auto_review` a repository added to the installation gets.
    attribute :default_auto_review, Tackle.Web.Forges.AutoReview do
      allow_nil? false
      public? true
      default :off
    end

    timestamps()
  end

  relationships do
    has_many :repositories, Repository do
      public? true
    end

    has_many :accesses, Access do
      public? true
    end
  end

  identities do
    identity :unique_external_id, [:forge, :external_id]
  end

  @doc """
  Records `owner` (`t:Tackle.Web.Forge.account/0`, from a forge event or
  sync) on an installation that has no owner yet; otherwise, or with no
  owner, returns the installation as it is.
  """
  @spec put_owner(t(), Tackle.Web.Forge.account() | nil) :: {:ok, t()} | {:error, term()}
  def put_owner(%__MODULE__{owner_external_id: nil} = installation, %{
        external_id: external_id,
        login: login
      }),
      do: record_owner(installation, external_id, login)

  def put_owner(%__MODULE__{} = installation, _owner), do: {:ok, installation}

  @doc "Whether `user` is the installation's owner, compared by forge and forge user id."
  @spec owned_by?(t(), User.t() | nil) :: boolean()
  def owned_by?(%__MODULE__{forge: forge, owner_external_id: id}, %User{
        forge: forge,
        external_id: id
      })
      when is_binary(id),
      do: true

  def owned_by?(_installation, _user), do: false

  @doc """
  Whose providers and review defaults the installation's reviews use: the
  owner, once they have signed in. `{:error, :installation_has_no_owner}`
  when no owner is recorded, `{:error, :owner_not_signed_in}` before the
  owner's first sign-in. A trusted read.
  """
  @spec owner(t()) ::
          {:ok, User.t()}
          | {:error, :installation_has_no_owner | :owner_not_signed_in | term()}
  def owner(%__MODULE__{owner_external_id: nil}), do: {:error, :installation_has_no_owner}

  def owner(%__MODULE__{forge: forge, owner_external_id: external_id}) do
    case User.get_external(forge, external_id) do
      {:ok, nil} -> {:error, :owner_not_signed_in}
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end
end
