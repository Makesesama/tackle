defmodule Tackle.Web.Forge do
  @moduledoc """
  What the app needs from a forge (docs/TACKLE_WEB_PLAN.md §7.1), so that
  nothing outside a forge module knows a forge's API or payloads. Only
  `Tackle.Web.Forge.GitHub` implements it.

  Callbacks are added as the phases need them: feedback (phase 7) is not
  here yet. Sign-in (§7.6) uses the forge app's OAuth client:
  `c:authorize_url/3`, `c:sign_in/3`, and `c:member?/3`. Ids the forge assigns (reviews, comments) are strings, whatever
  the forge's own representation, so callers never depend on it.
  """

  alias Tackle.Web.Forge.Event
  alias Tackle.Web.Forges.{ForgeApp, Installation, Repository}

  @typedoc "A pull request's current state, as a review request needs it."
  @type pull_request :: %{
          number: pos_integer(),
          state: :open | :closed,
          draft: boolean(),
          head_sha: String.t(),
          base_sha: String.t(),
          base_ref: String.t(),
          head_is_fork: boolean(),
          author: String.t() | nil
        }

  @typedoc """
  A line comment of a review to post. `side` is the side of the diff the
  lines are on (`:new` for added or context lines, `:old` for removed
  ones); `line` is the last line of the range, `start_line` its first when
  the range spans lines (`nil` or absent otherwise; it must be less than
  `line` and in the same hunk). `body` is final text: the forge sends it as
  given.
  """
  @type review_comment :: %{
          required(:path) => String.t(),
          required(:side) => :new | :old,
          required(:line) => pos_integer(),
          optional(:start_line) => pos_integer() | nil,
          required(:body) => String.t()
        }

  @typedoc """
  A forge account that signed in: the forge's id for it (stable across
  renames), its login, and its display name.
  """
  @type user :: %{external_id: String.t(), login: String.t(), name: String.t() | nil}

  @typedoc """
  A forge account as an installation's owner: the forge's id and login,
  with no display name.
  """
  @type account :: %{external_id: String.t(), login: String.t()}

  @typedoc "A line comment as posted on the forge, with the forge's id for it."
  @type posted_comment :: %{id: String.t(), body: String.t()}

  @typedoc """
  A file changed by a pull request. `patch` is the file's unified diff
  hunks, or `nil` when the forge leaves it out (binary or too large files).
  The list reflects the pull request's head when it was read: callers that
  need a particular head check it separately.
  """
  @type pull_request_file :: %{path: String.t(), patch: String.t() | nil}

  @doc """
  Verifies a webhook delivery against the forge app's secret and decodes
  it. `raw_body` is the request body exactly as received; `headers` are the
  request headers with lowercase names.
  """
  @callback verify_webhook(
              raw_body :: binary(),
              headers :: [{String.t(), String.t()}],
              ForgeApp.t()
            ) ::
              {:ok, Event.t()} | {:error, :invalid_signature | :invalid_payload}

  @doc """
  Returns a canonical HTTPS clone URL and a short-lived HTTP authorization
  header. The header is sensitive: use only in a remote Git command's
  environment, never in argv, persisted config, logs, or a review jail.
  """
  @callback clone_auth(ForgeApp.t(), Installation.t(), Repository.t()) ::
              {:ok, %{url: String.t(), authorization: String.t()}} | {:error, term()}

  @doc "Reads a pull request's current state."
  @callback pull_request(ForgeApp.t(), Installation.t(), Repository.t(), pos_integer()) ::
              {:ok, pull_request()} | {:error, term()}

  @doc "Whether `login` may start reviews in the repository: write access or higher."
  @callback can_trigger?(ForgeApp.t(), Installation.t(), Repository.t(), login :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @doc """
  Posts one review on a pull request at `head_sha`: a plain comment review
  (it neither approves nor requests changes) with `body` and the line
  `comments`. Sent once, never retried or redirected, so an error after the
  forge received it may still mean it was posted: look it up with
  `c:find_review/5` before posting again. Returns the review's id.
  """
  @callback post_review(
              ForgeApp.t(),
              Installation.t(),
              Repository.t(),
              number :: pos_integer(),
              head_sha :: String.t(),
              body :: String.t(),
              comments :: [review_comment()]
            ) :: {:ok, review_id :: String.t()} | {:error, term()}

  @doc """
  The id of the first review on a pull request posted by this forge app
  whose body contains `marker`, or `nil` when there is none. Reads every
  review; reviews by anyone else are never matched, so other users cannot
  forge a marker.
  """
  @callback find_review(
              ForgeApp.t(),
              Installation.t(),
              Repository.t(),
              number :: pos_integer(),
              marker :: String.t()
            ) :: {:ok, review_id :: String.t() | nil} | {:error, term()}

  @doc "Every line comment of a review, in the forge's order."
  @callback review_comments(
              ForgeApp.t(),
              Installation.t(),
              Repository.t(),
              number :: pos_integer(),
              review_id :: String.t()
            ) :: {:ok, [posted_comment()]} | {:error, term()}

  @doc "Every file a pull request changes, with its diff when the forge has one."
  @callback pull_request_files(ForgeApp.t(), Installation.t(), Repository.t(), pos_integer()) ::
              {:ok, [pull_request_file()]} | {:error, term()}

  @doc """
  The URL to send a browser to for signing in with the forge app's OAuth
  client. `state` is the caller's one-time value, returned to `redirect_uri`
  with the code. Fails when the forge app has no OAuth client configured.
  """
  @callback authorize_url(ForgeApp.t(), state :: String.t(), redirect_uri :: String.t()) ::
              {:ok, String.t()} | {:error, :sign_in_not_configured}

  @doc """
  Exchanges the code from the forge's redirect for the account that signed
  in. The user's access token is used for that read only, then revoked on a
  best-effort basis; it is never returned or stored.
  """
  @callback sign_in(ForgeApp.t(), code :: String.t(), redirect_uri :: String.t()) ::
              {:ok, user()} | {:error, term()}

  @doc """
  Whether `user` belongs to the account the installation is on: a member of
  the organisation, or the user account itself. Asks the forge, not the
  stored installation, so renamed accounts cannot be confused.
  """
  @callback member?(ForgeApp.t(), Installation.t(), user()) ::
              {:ok, boolean()} | {:error, term()}

  @doc """
  The forge user with `login`, as `t:user/0` with the forge's canonical
  login; `{:error, :not_found}` when there is no such user (organisations and
  bots are not users). Asked with the installation's credentials, for access
  grants (docs/TACKLE_WEB_PLAN.md §7.12).
  """
  @callback user(ForgeApp.t(), Installation.t(), login :: String.t()) ::
              {:ok, user()} | {:error, :not_found | term()}

  @doc "The forge module for a forge."
  @spec module(atom()) :: module()
  def module(:github), do: Tackle.Web.Forge.GitHub

  ## Web setup (docs/TACKLE_WEB_PLAN.md §7.11)

  @typedoc """
  A form the browser posts to the forge to register the app: the forge
  creates it and redirects to `base_url` + `/setup/<forge>/callback` with a
  code and `state`.
  """
  @type registration_form :: %{action: String.t(), fields: [{String.t(), String.t()}]}

  @typedoc """
  A registered app's settings and secrets, as `ForgeApp` stores them, and
  where to install it. `webhook_secret` is nil when the app was registered
  without a webhook.
  """
  @type registration :: %{
          app_id: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          private_key: String.t(),
          webhook_secret: String.t() | nil,
          install_url: String.t()
        }

  @typedoc """
  One installation of the app, as the forge reports it. `repositories` is
  nil when they cannot be read (a suspended installation).
  """
  @type installation_snapshot :: %{
          installation: Event.installation(),
          status: :active | :suspended,
          repositories: [Event.repository()] | nil
        }

  @doc """
  The form that registers the app on the forge. `opts`: `:name` (the
  suggested name), `:owner` (an organisation to register it under; the
  signed-in user's account otherwise), and `:webhook?` (false registers it
  without a webhook, for a URL the forge cannot reach).
  """
  @callback registration_form(base_url :: String.t(), state :: String.t(), keyword()) ::
              {:ok, registration_form()} | {:error, :invalid_owner}

  @doc "Exchanges the code from the forge's registration redirect, once."
  @callback complete_registration(code :: String.t()) :: {:ok, registration()} | {:error, term()}

  @doc "Where to install the registered app on (another) account."
  @callback install_url(ForgeApp.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Every installation of the app, with its repositories."
  @callback installations(ForgeApp.t()) :: {:ok, [installation_snapshot()]} | {:error, term()}

  @doc """
  One installation of the app by the forge's id, with its repositories;
  `{:error, :not_found}` when it is not this app's.
  """
  @callback installation(ForgeApp.t(), external_id :: String.t()) ::
              {:ok, installation_snapshot()} | {:error, term()}
end
