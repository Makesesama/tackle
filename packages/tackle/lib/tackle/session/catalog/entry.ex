defmodule Tackle.Session.Catalog.Entry do
  @moduledoc """
  One bounded, searchable session summary held by the derived catalog.

  A result carries metadata rather than a full transcript. The internal
  `:search_text` field is used for matching and is `nil` until a search builds
  it; `:journal_path` locates the session's file for that. Neither is returned
  to frontends.

  `:archived` reflects where the session lives: an archived session is listed
  only when a listing asks for archived sessions. `:context_tokens` is the
  estimated size of the session's model context (see
  `Tackle.Session.Projection.context_tokens/1`); it is `nil` for summaries
  written before the field existed.
  """

  @enforce_keys [:session_id]
  defstruct session_id: nil,
            title: nil,
            cwd: nil,
            created_at: nil,
            updated_at: nil,
            status: :clean,
            model: nil,
            tags: [],
            message_count: 0,
            preview: nil,
            last_indexed_seq: 0,
            parent_session_id: nil,
            archived: false,
            context_tokens: nil,
            search_text: nil,
            journal_path: nil

  @typedoc """
  The session's status: the projection's (`Tackle.Session.Projection.status/0`),
  or `:active` while its journal owner runs a turn.
  """
  @type status :: :clean | :interrupted | :recovered | :active

  @type t :: %__MODULE__{
          session_id: String.t(),
          title: String.t() | nil,
          cwd: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          status: status() | nil,
          model: String.t() | nil,
          tags: [String.t()],
          message_count: non_neg_integer(),
          preview: String.t() | nil,
          last_indexed_seq: non_neg_integer(),
          parent_session_id: String.t() | nil,
          archived: boolean(),
          context_tokens: non_neg_integer() | nil,
          search_text: String.t() | nil,
          journal_path: String.t() | nil
        }

  @public_fields [
    :session_id,
    :title,
    :cwd,
    :created_at,
    :updated_at,
    :status,
    :model,
    :tags,
    :message_count,
    :preview,
    :last_indexed_seq,
    :parent_session_id,
    :archived,
    :context_tokens
  ]

  @doc "Returns the frontend-facing projection of an entry."
  @spec public(t()) :: map()
  def public(%__MODULE__{} = entry), do: Map.take(entry, @public_fields)
end
