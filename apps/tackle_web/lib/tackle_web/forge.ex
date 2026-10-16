defmodule Tackle.Web.Forge do
  @moduledoc """
  What the app needs from a forge (docs/TACKLE_WEB_PLAN.md §7.1), so that
  nothing outside a forge module knows a forge's API or payloads. Only
  `Tackle.Web.Forge.GitHub` implements it.

  Callbacks are added as the phases need them: posting (phase 5) and
  feedback (phase 7) are not here yet.
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

  @doc "The forge module for a forge."
  @spec module(atom()) :: module()
  def module(:github), do: Tackle.Web.Forge.GitHub
end
