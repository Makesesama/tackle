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

  `:stale` marks an entry a rebuild took from the session's summary sidecar
  because replaying its journal, which changed since the sidecar was written,
  took too long (`Tackle.Session.Catalog.rebuild/1`). It may miss the latest
  commits until the session's next indexed commit or rebuild.
  """

  alias Tackle.Session.Projection

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
            stale: false,
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
          stale: boolean(),
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
    :context_tokens,
    :stale
  ]

  # The fields a summary sidecar stores. Where the session lives (`archived`,
  # `journal_path`) and whether a rebuild fell back to the sidecar (`stale`)
  # are decided when it is read.
  @sidecar_fields [
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
    :context_tokens,
    :search_text
  ]

  # The statuses an entry can have, by name. Earlier versions recorded
  # `"closed"` for a session that is clean now.
  @statuses %{
    "clean" => :clean,
    "interrupted" => :interrupted,
    "recovered" => :recovered,
    "active" => :active
  }

  @doc """
  Builds the entry that describes a projection.

  Options:

    * `:status` - the status to list instead of the projection's; a live
      journal owner lists `:active` while it runs a turn;
    * `:journal_path` - the session's journal file;
    * `:archived` - whether the session lives in the archive (default
      `false`);
    * `:search_text` - `true` to build the search text now
      (`Tackle.Session.Projection.search_text/1`, whose cost grows with the
      session); without it the entry has none until a search builds it.
  """
  @spec from_projection(Projection.t(), keyword()) :: t()
  def from_projection(%Projection{} = projection, opts \\ []) do
    metadata = Projection.metadata(projection)

    %__MODULE__{
      session_id: metadata.session_id,
      title: metadata.title,
      cwd: metadata.cwd,
      created_at: metadata.created_at,
      updated_at: metadata.updated_at,
      status: Keyword.get(opts, :status) || metadata.status,
      model: metadata.model,
      tags: metadata.tags,
      message_count: metadata.message_count,
      preview: metadata.preview,
      last_indexed_seq: metadata.last_indexed_seq,
      parent_session_id: metadata.parent_session_id,
      archived: Keyword.get(opts, :archived, false) == true,
      context_tokens: metadata.context_tokens,
      search_text:
        if(Keyword.get(opts, :search_text, false), do: Projection.search_text(projection)),
      journal_path: Keyword.get(opts, :journal_path)
    }
  end

  @doc """
  Encodes an entry as the plain-data summary a sidecar stores: binary keys,
  and the status by name. `:archived`, `:journal_path`, and `:stale` are not
  stored.
  """
  @spec to_sidecar(t()) :: %{optional(String.t()) => term()}
  def to_sidecar(%__MODULE__{} = entry) do
    entry
    |> Map.take(@sidecar_fields)
    |> Map.new(fn
      {:status, status} when is_atom(status) and not is_nil(status) ->
        {"status", Atom.to_string(status)}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end

  @doc """
  Decodes a sidecar summary written by any version.

  Missing fields take their defaults (earlier versions wrote no
  `context_tokens`), unknown keys are ignored, and a status that names none
  of `t:status/0`, such as the `"closed"` earlier versions wrote, reads as
  `:clean`. The entry is not located: `:archived` is `false` and
  `:journal_path` is `nil`.
  """
  @spec from_sidecar(map()) :: t()
  def from_sidecar(%{} = data) do
    %__MODULE__{
      session_id: data["session_id"],
      title: data["title"],
      cwd: data["cwd"],
      created_at: data["created_at"],
      updated_at: data["updated_at"],
      status: decode_status(data["status"]),
      model: data["model"],
      tags: data["tags"] || [],
      message_count: data["message_count"] || 0,
      preview: data["preview"],
      last_indexed_seq: data["last_indexed_seq"] || 0,
      parent_session_id: data["parent_session_id"],
      context_tokens: data["context_tokens"],
      search_text: data["search_text"]
    }
  end

  @doc """
  Returns the status a name stands for (`"active"` is `:active`), or `:error`
  when it names none.
  """
  @spec status_named(String.t()) :: {:ok, status()} | :error
  def status_named(name) when is_binary(name), do: Map.fetch(@statuses, name)

  @doc "Returns the frontend-facing projection of an entry."
  @spec public(t()) :: map()
  def public(%__MODULE__{} = entry), do: Map.take(entry, @public_fields)

  defp decode_status(nil), do: nil
  defp decode_status(status) when is_atom(status), do: status

  defp decode_status(status) when is_binary(status) do
    case status_named(status) do
      {:ok, status} -> status
      :error -> :clean
    end
  end
end
