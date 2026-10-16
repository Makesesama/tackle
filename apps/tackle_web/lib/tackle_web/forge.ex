defmodule Tackle.Web.Forge do
  @moduledoc """
  What the app needs from a forge (docs/TACKLE_WEB_PLAN.md §7.1), so that
  nothing outside a forge module knows a forge's API or payloads. Only
  `Tackle.Web.Forge.GitHub` implements it.

  Callbacks are added as the phases need them: feedback (phase 7) is not
  here yet. Ids the forge assigns (reviews, comments) are strings, whatever
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

  @doc "The forge module for a forge."
  @spec module(atom()) :: module()
  def module(:github), do: Tackle.Web.Forge.GitHub
end
