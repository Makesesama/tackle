defmodule Tackle.Web.Setup do
  @moduledoc """
  The first-run state of the app (docs/TACKLE_WEB_PLAN.md §7.11).

  Setup is *complete* once a GitHub App is stored and someone is an admin.
  Until then, `/setup` (`Tackle.Web.SetupController`) leads through
  registering the App, installing it, and signing in, which makes that
  person the first admin. Only someone with the **setup token** can start:
  a random value made at boot (`init_token/0`), kept in memory only, and
  written to the log (`announce/0`) while setup is incomplete. A restart
  makes a new one; once setup is complete it stops working.

  Entering the token unlocks setup for that browser session for
  `unlock_ttl/0` seconds; the session stores only when, not the token.
  """

  require Ash.Query
  require Logger

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Endpoint
  alias Tackle.Web.Forges.{ForgeApp, Installation}

  @key {__MODULE__, :token}
  @unlock_ttl 60 * 60

  @typedoc "Where setup stands; see `status/0`."
  @type status :: %{
          forge_app: ForgeApp.t() | nil,
          installed?: boolean(),
          admin?: boolean()
        }

  @doc "Makes this boot's setup token. Called once as the application starts."
  @spec init_token() :: :ok
  def init_token do
    :persistent_term.put(@key, Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false))
  end

  @doc false
  # The current token; for the log message and tests.
  @spec token() :: String.t()
  def token, do: :persistent_term.get(@key)

  @doc "How long an unlocked setup session lasts, in seconds."
  @spec unlock_ttl() :: pos_integer()
  def unlock_ttl, do: @unlock_ttl

  @doc "Where setup stands, read from the database."
  @spec status() :: status()
  def status do
    {:ok, forge_app} = ForgeApp.get(:github)

    %{
      forge_app: forge_app,
      installed?: Installation |> Ash.Query.filter(status == :active) |> Ash.exists?(),
      admin?: User |> Ash.Query.filter(admin == true) |> Ash.exists?()
    }
  end

  @doc "Whether setup is complete: an App is stored and someone is an admin."
  @spec complete?(status()) :: boolean()
  def complete?(%{forge_app: forge_app, admin?: admin?}), do: not is_nil(forge_app) and admin?

  @doc "Whether `given` is this boot's token, while setup is incomplete."
  @spec valid_token?(term()) :: boolean()
  def valid_token?(given) when is_binary(given) do
    Plug.Crypto.secure_compare(String.trim(given), token()) and not complete?(status())
  end

  def valid_token?(_given), do: false

  @doc """
  Whether a session unlocked at `unlocked_at` (Unix seconds, or nil) may
  still use setup: within `unlock_ttl/0` and while setup is incomplete.
  """
  @spec unlocked?(term()) :: boolean()
  def unlocked?(unlocked_at) when is_integer(unlocked_at) do
    (System.os_time(:second) - unlocked_at) in 0..@unlock_ttl and not complete?(status())
  end

  def unlocked?(_unlocked_at), do: false

  @doc """
  Logs the setup URL and token when setup is incomplete. Run once after the
  repository starts; a database that is not reachable (yet) is logged too,
  so the token is never lost.
  """
  @spec announce() :: :ok
  def announce do
    if complete?(status()), do: :ok, else: log_token()
  rescue
    error ->
      Logger.warning("could not read the setup state: #{Exception.message(error)}")
      log_token()
  end

  defp log_token do
    Logger.warning(
      "tackle_web is not set up yet. Open #{Endpoint.url()}/setup and enter the " <>
        "setup token #{token()} (valid until setup is complete or the server restarts)."
    )
  end
end
