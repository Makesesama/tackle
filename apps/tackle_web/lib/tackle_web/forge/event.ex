defmodule Tackle.Web.Forge.Event do
  @moduledoc """
  A verified webhook delivery, in forge-neutral terms. Forge modules build
  them; `Tackle.Web.Webhooks` acts on them.

  `type` and the fields it sets:

    * `:installation` - the app was installed, uninstalled, suspended, or
      unsuspended: `action` (`:created`, `:deleted`, `:suspended`,
      `:unsuspended`), `installation`, and for `:created` the
      `repositories` it can access.
    * `:repositories_added`, `:repositories_removed` - repositories were
      added to or removed from an installation: `installation`,
      `repositories`.
    * `:pull_request` - `action` (`:opened`, `:reopened`,
      `:ready_for_review`, `:synchronize`, `:closed`), `installation`,
      `repository`, `pull_request` (`t:Tackle.Web.Forge.pull_request/0`),
      `sender`.
    * `:comment` - a new comment on a pull request's conversation:
      `installation`, `repository`, `comment`.
    * `:ping` - the forge checks the webhook.
    * `:ignored` - anything else; `reason` says what it was.
  """

  @type installation :: %{external_id: String.t(), account: String.t() | nil}
  @type repository :: %{external_id: String.t(), owner: String.t(), name: String.t()}
  @type comment :: %{
          pull_number: pos_integer(),
          body: String.t(),
          author: String.t(),
          author_is_bot: boolean()
        }

  @type t :: %__MODULE__{
          type:
            :installation
            | :repositories_added
            | :repositories_removed
            | :pull_request
            | :comment
            | :ping
            | :ignored,
          delivery_id: String.t() | nil,
          action: atom() | nil,
          installation: installation() | nil,
          repository: repository() | nil,
          repositories: [repository()],
          pull_request: Tackle.Web.Forge.pull_request() | nil,
          comment: comment() | nil,
          sender: String.t() | nil,
          reason: String.t() | nil
        }

  @enforce_keys [:type]
  defstruct [
    :type,
    :delivery_id,
    :action,
    :installation,
    :repository,
    :pull_request,
    :comment,
    :sender,
    :reason,
    repositories: []
  ]
end
