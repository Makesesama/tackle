defmodule Tackle.Session.Catalog.Entry do
  @moduledoc """
  One bounded, searchable session summary held by the derived catalog.

  A result carries metadata rather than a full transcript. The internal
  `:search_text` field is used for matching but is never returned to frontends.
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
            search_text: ""

  @type t :: %__MODULE__{
          session_id: String.t(),
          title: String.t() | nil,
          cwd: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          status: atom() | nil,
          model: String.t() | nil,
          tags: [String.t()],
          message_count: non_neg_integer(),
          preview: String.t() | nil,
          last_indexed_seq: non_neg_integer(),
          parent_session_id: String.t() | nil,
          search_text: String.t()
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
    :parent_session_id
  ]

  @doc "Returns the frontend-facing projection of an entry."
  @spec public(t()) :: map()
  def public(%__MODULE__{} = entry), do: Map.take(entry, @public_fields)
end
