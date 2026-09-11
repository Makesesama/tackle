defmodule Tackle.Lib.Tree do
  @moduledoc """
  Immutable conversation tree with an active position.

  A tree preserves alternative conversation paths inside one session. Every
  settled message and every committed compaction becomes an entry with a stable
  id and a parent link, and exactly one entry is the active position (or `nil`
  before the first entry).

      user: Investigate the cache
      └─ assistant: Two possible approaches
         ├─ user: Try A
         │  └─ assistant: Result A
         └─ user: Try B
            └─ assistant: Result B  <- active position

  ## Invariants

    * an entry references an existing parent or `nil`; multiple roots are valid;
    * ids are unique across entry kinds;
    * parent chains are acyclic and ordering is deterministic (`:ordinal`);
    * only settled messages and committed compactions become entries;
    * appending attaches to the active position and advances it;
    * navigation changes the active position without modifying entries;
    * model projection follows ancestry, not chronological append order.

  ## Readers

  The module separates three surfaces deliberately:

    * `enumerate/1` — every entry on every branch, in chronological order;
    * `transcript/1` — the active path's settled messages, never compacted;
    * `model_context/1` — the active path's provider context, with the
      compactions that occur on that path applied.

  Compactions only affect the branch they were created on. Navigating before a
  compaction restores the uncompacted context without re-summarizing, and
  sibling branches never inherit each other's checkpoints.

  This value is pure: it needs no process, storage, or OTP supervision.
  """

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tree.Entry
  alias Tackle.Lib.Usage

  @type id :: String.t()
  @type t :: %__MODULE__{
          entries: %{optional(id()) => Entry.t()},
          order: [id()],
          active_id: id() | nil,
          revision: non_neg_integer()
        }

  @enforce_keys []
  defstruct entries: %{}, order: [], active_id: nil, revision: 0

  @doc "Builds an empty tree with no active position."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the number of entries in the tree."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: map_size(entries)

  @doc "Returns true when the tree holds no entries."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = tree), do: size(tree) == 0

  @doc "Returns the current active entry id, or nil before the root."
  @spec active_id(t()) :: id() | nil
  def active_id(%__MODULE__{active_id: active_id}), do: active_id

  @doc "Returns the monotonic tree revision used for stale-transition checks."
  @spec revision(t()) :: non_neg_integer()
  def revision(%__MODULE__{revision: revision}), do: revision

  @doc "Returns one entry by id, or nil when it is not part of the tree."
  @spec entry(t(), id() | nil) :: Entry.t() | nil
  def entry(_tree, nil), do: nil
  def entry(%__MODULE__{entries: entries}, id), do: Map.get(entries, id)

  @doc "Returns true when the tree contains the entry id."
  @spec contains?(t(), id() | nil) :: boolean()
  def contains?(_tree, nil), do: false
  def contains?(%__MODULE__{entries: entries}, id), do: is_map_key(entries, id)

  @doc "Returns the active entry, or nil before the root."
  @spec active_entry(t()) :: Entry.t() | nil
  def active_entry(%__MODULE__{} = tree), do: entry(tree, tree.active_id)

  @doc "Returns every entry in chronological insertion order."
  @spec enumerate(t()) :: [Entry.t()]
  def enumerate(%__MODULE__{entries: entries, order: order}) do
    order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(entries, &1))
  end

  @doc "Returns the entries whose parent is `parent_id`, in chronological order."
  @spec children(t(), id() | nil) :: [Entry.t()]
  def children(%__MODULE__{} = tree, parent_id) do
    tree
    |> enumerate()
    |> Enum.filter(&(&1.parent_id == parent_id))
  end

  @doc "Returns the root entries of the tree."
  @spec roots(t()) :: [Entry.t()]
  def roots(%__MODULE__{} = tree), do: children(tree, nil)

  @doc """
  Returns the ancestry from the root to `id` (inclusive).

  `nil` addresses the position before the first entry, whose ancestry is empty.
  """
  @spec ancestry(t(), id() | nil) :: [Entry.t()]
  def ancestry(%__MODULE__{} = tree, id) do
    do_ancestry(tree, id, [])
  end

  @doc "Returns the active path's entries from root to active position."
  @spec active_path(t()) :: [Entry.t()]
  def active_path(%__MODULE__{active_id: active_id} = tree), do: ancestry(tree, active_id)

  @doc """
  Returns the active path's complete settled transcript.

  The transcript is never compacted; it is the canonical history of the selected
  branch, including messages that a compaction has since shadowed in the model
  surface.
  """
  @spec transcript(t()) :: [Message.t()]
  def transcript(%__MODULE__{active_id: active_id} = tree), do: transcript(tree, active_id)

  @doc "Returns the settled transcript for an arbitrary entry."
  @spec transcript(t(), id() | nil) :: [Message.t()]
  def transcript(%__MODULE__{} = tree, id) do
    tree
    |> ancestry(id)
    |> Enum.flat_map(fn
      %Entry{kind: :message, message: %Message{} = message} -> [message]
      %Entry{} -> []
    end)
  end

  @doc """
  Returns the provider-visible model context for the active path.

  Compactions encountered on the path replace the preceding prefix with their
  synthetic checkpoint. Shared ancestors keep their context, and sibling
  branches never contribute messages or checkpoints.
  """
  @spec model_context(t()) :: [Message.t()]
  def model_context(%__MODULE__{active_id: active_id} = tree),
    do: model_context(tree, active_id)

  @doc "Returns the provider-visible model context ending at an arbitrary entry."
  @spec model_context(t(), id() | nil) :: [Message.t()]
  def model_context(%__MODULE__{} = tree, id) do
    tree
    |> ancestry(id)
    |> Enum.reduce([], fn
      %Entry{kind: :message, message: %Message{} = message}, acc ->
        acc ++ [message]

      %Entry{kind: :compaction, compaction: %Record{} = record}, acc ->
        apply_compaction(acc, record)
    end)
  end

  @doc "Returns the last assistant answer on the active path, or nil."
  @spec last_answer(t()) :: String.t() | nil
  def last_answer(%__MODULE__{} = tree) do
    tree
    |> transcript()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, content: content} when is_binary(content) and content != "" ->
        content

      _message ->
        nil
    end)
  end

  @doc """
  Aggregates assistant-message usage across the entire tree.

  Every settled message is counted once, regardless of how many branches share
  it. This is archive accounting, not the cost of the active model projection.
  """
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{} = tree) do
    tree
    |> enumerate()
    |> Enum.flat_map(fn
      %Entry{kind: :message, message: %Message{} = message} -> [message.token_usage]
      %Entry{} -> []
    end)
    |> Usage.aggregate()
  end

  @doc "Aggregates assistant-message usage on the active path."
  @spec branch_usage(t()) :: Usage.t()
  def branch_usage(%__MODULE__{} = tree) do
    tree
    |> transcript()
    |> Enum.map(& &1.token_usage)
    |> Usage.aggregate()
  end

  @doc "Returns the most recent compaction id on the active path, or nil."
  @spec last_compaction_id(t()) :: id() | nil
  def last_compaction_id(%__MODULE__{active_id: active_id} = tree) do
    tree
    |> ancestry(active_id)
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Entry{kind: :compaction, compaction: %Record{compaction_id: id}} -> id
      %Entry{} -> nil
    end)
  end

  @doc """
  Returns true when `id` is a structurally safe continuation point.

  A safe point has every assistant tool call on its path answered by a tool
  result, so selecting it cannot silently replay a tool, fabricate a result, or
  send a malformed provider history. `nil` (the position before the first
  message) is always safe.
  """
  @spec resumable?(t(), id() | nil) :: boolean()
  def resumable?(_tree, nil), do: true

  def resumable?(%__MODULE__{} = tree, id) do
    if contains?(tree, id) do
      path = ancestry(tree, id)
      calls = Enum.flat_map(path, &entry_tool_call_ids/1)
      results = Enum.flat_map(path, &entry_tool_result_ids/1)
      Enum.all?(calls, &(&1 in results))
    else
      false
    end
  end

  @doc """
  Appends a settled message to the active position.

  `:parent_id` overrides the attachment point; it defaults to the active entry
  and may be `nil` to start a new root. Returns the updated tree and the new
  entry.
  """
  @spec append_message(t(), Message.t(), keyword()) ::
          {:ok, t(), Entry.t()} | {:error, term()}
  def append_message(%__MODULE__{} = tree, %Message{} = message, opts \\ []) do
    append(tree, :message, %{message: message}, message.id, opts)
  end

  @doc """
  Appends a committed compaction to the active position.

  The compaction id is reused as the entry id, and the record's summary message
  becomes the branch's new context checkpoint.
  """
  @spec append_compaction(t(), Record.t(), keyword()) ::
          {:ok, t(), Entry.t()} | {:error, term()}
  def append_compaction(%__MODULE__{} = tree, %Record{} = record, opts \\ []) do
    append(tree, :compaction, %{compaction: record}, record.compaction_id, opts)
  end

  @doc """
  Moves the active position to `id`, or to `nil` before the first entry.

  Moving is a no-op when the position is already active; it never modifies
  entries or deletes branches.
  """
  @spec move(t(), id() | nil) :: {:ok, t()} | {:error, term()}
  def move(%__MODULE__{active_id: active_id} = tree, id) when id == active_id,
    do: {:ok, tree}

  def move(%__MODULE__{} = tree, nil),
    do: {:ok, %{tree | active_id: nil, revision: tree.revision + 1}}

  def move(%__MODULE__{} = tree, id) do
    case entry(tree, id) do
      nil -> {:error, {:unknown_entry, id}}
      _entry -> {:ok, %{tree | active_id: id, revision: tree.revision + 1}}
    end
  end

  @doc """
  Builds a validated tree from durable entry descriptors.

  Each descriptor is a map with `:id`, `:parent_id`, `:kind`, and either
  `:message` or `:compaction`. Descriptors must arrive in chronological order;
  every parent must already exist (which also guarantees acyclicity). Invalid
  input is rejected rather than repaired by dropping entries.
  """
  @spec restore([map()], keyword()) :: {:ok, t()} | {:error, term()}
  def restore(entries, opts \\ []) when is_list(entries) do
    with {:ok, tree} <- build_restored(entries, %__MODULE__{}, 1),
         {:ok, tree} <- restore_active(tree, Keyword.get(opts, :active_id)) do
      {:ok, tree}
    end
  end

  defp build_restored([], tree, _ordinal), do: {:ok, tree}

  defp build_restored([descriptor | rest], tree, ordinal) do
    with {:ok, entry} <- build_entry(descriptor, ordinal),
         :ok <- validate_unique(tree, entry.id),
         :ok <- validate_parent(tree, entry.parent_id) do
      tree = %{
        tree
        | entries: Map.put(tree.entries, entry.id, entry),
          order: [entry.id | tree.order],
          active_id: entry.id,
          revision: tree.revision + 1
      }

      build_restored(rest, tree, ordinal + 1)
    end
  end

  defp build_entry(%{} = descriptor, ordinal) do
    id = fetch(descriptor, :id)
    kind = normalize_kind(fetch(descriptor, :kind))
    parent_id = fetch(descriptor, :parent_id)

    with :ok <- validate_id(id),
         :ok <- validate_kind(kind, descriptor),
         :ok <- validate_parent_value(parent_id) do
      entry =
        case kind do
          :message ->
            %Entry{
              id: id,
              parent_id: parent_id,
              kind: :message,
              ordinal: ordinal,
              message: fetch(descriptor, :message)
            }

          :compaction ->
            %Entry{
              id: id,
              parent_id: parent_id,
              kind: :compaction,
              ordinal: ordinal,
              compaction: fetch(descriptor, :compaction)
            }
        end

      {:ok, entry}
    end
  end

  defp build_entry(other, _ordinal), do: {:error, {:invalid_entry, other}}

  defp validate_kind(:message, descriptor) do
    case fetch(descriptor, :message) do
      %Message{} -> :ok
      other -> {:error, {:invalid_entry_message, other}}
    end
  end

  defp validate_kind(:compaction, descriptor) do
    case fetch(descriptor, :compaction) do
      %Record{} -> :ok
      other -> {:error, {:invalid_entry_compaction, other}}
    end
  end

  defp validate_kind(other, _descriptor), do: {:error, {:invalid_entry_kind, other}}

  defp normalize_kind("message"), do: :message
  defp normalize_kind("compaction"), do: :compaction
  defp normalize_kind(kind), do: kind

  defp validate_parent_value(nil), do: :ok
  defp validate_parent_value(parent_id) when is_binary(parent_id) and parent_id != "", do: :ok
  defp validate_parent_value(other), do: {:error, {:invalid_parent, other}}

  defp restore_active(tree, nil), do: {:ok, %{tree | active_id: nil}}

  defp restore_active(tree, active_id) do
    if contains?(tree, active_id) do
      {:ok, %{tree | active_id: active_id}}
    else
      {:error, {:unknown_active_entry, active_id}}
    end
  end

  defp append(tree, kind, payload, id, opts) do
    parent_id = Keyword.get(opts, :parent_id, tree.active_id)

    with :ok <- validate_id(id),
         :ok <- validate_unique(tree, id),
         :ok <- validate_parent(tree, parent_id) do
      entry =
        payload
        |> Map.merge(%{
          id: id,
          parent_id: parent_id,
          kind: kind,
          ordinal: map_size(tree.entries) + 1
        })
        |> then(&struct(Entry, &1))

      tree = %{
        tree
        | entries: Map.put(tree.entries, id, entry),
          order: [id | tree.order],
          active_id: id,
          revision: tree.revision + 1
      }

      {:ok, tree, entry}
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_id(other), do: {:error, {:invalid_entry_id, other}}

  defp validate_unique(tree, id) do
    if contains?(tree, id), do: {:error, {:duplicate_entry, id}}, else: :ok
  end

  defp validate_parent(_tree, nil), do: :ok

  defp validate_parent(tree, parent_id) do
    if contains?(tree, parent_id),
      do: :ok,
      else: {:error, {:unknown_parent, parent_id}}
  end

  defp do_ancestry(_tree, nil, acc), do: acc

  defp do_ancestry(tree, id, acc) do
    case entry(tree, id) do
      nil -> acc
      %Entry{parent_id: parent_id} = entry -> do_ancestry(tree, parent_id, [entry | acc])
    end
  end

  defp apply_compaction(acc, %Record{} = record) do
    [record.summary_message | acc |> retained_tail(record) |> reset_metadata()]
  end

  defp retained_tail(acc, %Record{first_retained_message_id: id, shadowed_message_ids: shadowed}) do
    case id do
      nil ->
        drop_shadowed(acc, shadowed)

      id ->
        case Enum.find_index(acc, &(&1.id == id)) do
          nil -> drop_shadowed(acc, shadowed)
          index -> Enum.drop(acc, index)
        end
    end
  end

  defp drop_shadowed(messages, shadowed_ids) do
    shadowed = MapSet.new(shadowed_ids)
    Enum.drop_while(messages, &MapSet.member?(shadowed, &1.id))
  end

  defp reset_metadata(messages) do
    Enum.map(messages, &%{&1 | token_usage: nil, provider_state: nil})
  end

  defp entry_tool_call_ids(%Entry{kind: :message, message: %Message{tool_calls: calls}})
       when is_list(calls) do
    calls
    |> Enum.map(&tool_call_id/1)
    |> Enum.reject(&is_nil/1)
  end

  defp entry_tool_call_ids(_entry), do: []

  defp entry_tool_result_ids(%Entry{kind: :message, message: %Message{role: :tool} = message}) do
    case message.tool_call_id do
      id when is_binary(id) -> [id]
      _other -> []
    end
  end

  defp entry_tool_result_ids(_entry), do: []

  defp tool_call_id(call) when is_map(call) do
    Map.get(call, :id) || Map.get(call, "id")
  end

  defp tool_call_id(_call), do: nil

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
