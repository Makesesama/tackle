defmodule Tackle.Session.ProjectionError do
  @moduledoc """
  Raised when a validated commit cannot be folded into a projection.

  Replay treats this as corruption rather than repairing it: an invalid parent
  link, a duplicate entry id, an unknown active position, or a malformed
  compaction record stops writable resume instead of silently dropping history.
  """

  defexception [:message, :reason]

  @impl true
  def exception(opts) do
    reason = Keyword.get(opts, :reason)
    %__MODULE__{reason: reason, message: "invalid projection transition: #{inspect(reason)}"}
  end
end

defmodule Tackle.Session.Projection do
  @moduledoc """
  Durable projection folded from validated journal commits.

  A projection is conversation data plus audit metadata. It never holds runtime
  handles, and it is not a `%Tackle.Lib.State{}`: the runtime state is rebuilt
  from a projection together with current trusted configuration.

  Conversation structure is folded into a `Tackle.Lib.Tree`, even for linear
  journals, so branching state and the canonical archive are derived through one
  implementation. Two projections expose the accepted semantics:

    * `messages` — the complete archive of settled messages on every branch, in
      commit order; shared ancestors appear once. Search and counts read this.
    * `model_messages` — the active path's provider-visible context, with the
      compactions that occur on that path applied.

  `tree_enabled?` records whether the session is allowed to branch. A journal
  without branching keeps `false` until the host records an explicit
  `tree.enabled` transition; its chain is a tree with one branch either way.

  Replay folds validated commits into the tree and derives message surfaces
  once at the end. Live commits update unchanged surfaces incrementally and
  rebuild only the active model path when navigation or compaction requires it.
  """

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tree
  alias Tackle.Session.Codec
  alias Tackle.Session.Log
  alias Tackle.Session.ProjectionError

  @preview_length 200

  @enforce_keys [:session_id]
  defstruct session_id: nil,
            created_at: nil,
            updated_at: nil,
            cwd: nil,
            parent: nil,
            title: nil,
            tags: [],
            model_ref: nil,
            thinking: nil,
            tree_enabled?: false,
            tree: %Tree{},
            messages: [],
            model_messages: [],
            compactions: [],
            turns: %{},
            active_turn: nil,
            pending_tools: [],
            last_seq: 0,
            status: :clean,
            recovered: nil,
            closed_at: nil

  @type turn :: %{
          turn_id: String.t() | nil,
          operation: String.t() | nil,
          status: :started | :completed | :errored | :cancelled | :crashed | :abandoned,
          started_at: String.t() | nil,
          ended_at: String.t() | nil,
          input: term()
        }

  @typedoc """
  The recovery status of the durable history: `:interrupted` while a turn has
  no terminal event, otherwise `:recovered` once repair recovered the journal,
  otherwise `:clean`.

  Every commit keeps it current, live and in replay, so it is what replay of
  the history so far reports: a turn a live owner is still running counts as
  interrupted here. The catalog lists such a session as `:active` instead.
  """
  @type status :: :clean | :interrupted | :recovered

  @typedoc "A tool execution started without a durable result yet."
  @type pending_tool :: %{
          tool_call_id: String.t() | nil,
          name: String.t() | nil,
          started_at: String.t() | nil,
          turn_id: String.t() | nil
        }

  @type t :: %__MODULE__{
          session_id: String.t(),
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          cwd: String.t() | nil,
          parent: map() | nil,
          title: String.t() | nil,
          tags: [String.t()],
          model_ref: String.t() | nil,
          thinking: String.t() | nil,
          tree_enabled?: boolean(),
          tree: Tree.t(),
          messages: [map()],
          model_messages: [map()],
          compactions: [map()],
          turns: %{optional(String.t()) => turn()},
          active_turn: turn() | nil,
          pending_tools: [pending_tool()],
          last_seq: non_neg_integer(),
          status: status(),
          recovered: map() | nil,
          closed_at: String.t() | nil
        }

  @doc """
  Builds an empty projection from a validated header.

  Everything else, such as the title, the model, and whether the session may
  branch, comes from the events folded into it, starting with
  `session.created`.
  """
  @spec new(map()) :: t()
  def new(header) do
    %__MODULE__{
      session_id: header["session_id"],
      created_at: header["created_at"],
      updated_at: header["created_at"],
      cwd: header["cwd"],
      parent: header["parent"]
    }
  end

  @doc """
  Applies one validated commit to a projection.

  The commit must be valid: read with `Tackle.Session.Log.read_commit/4`, or
  built by the journal from `Tackle.Session.Log`'s builders with plain data.
  Unknown optional events are ignored by the core projection. A commit that
  cannot be folded consistently raises `Tackle.Session.ProjectionError` so
  replay can reject it instead of dropping history.
  """
  @spec apply_commit(t(), map()) :: t()
  def apply_commit(
        %__MODULE__{} = projection,
        %{"seq" => seq, "events" => events} = commit
      ) do
    projection = Enum.reduce(events, projection, &apply_live_event/2)

    classify(%{
      projection
      | last_seq: seq,
        updated_at: commit["written_at"] || projection.updated_at
    })
  end

  @doc false
  @spec apply_replay_commit(t(), map()) :: t()
  def apply_replay_commit(
        %__MODULE__{} = projection,
        %{"seq" => seq, "events" => events} = commit
      ) do
    projection = Enum.reduce(events, projection, &apply_event/2)

    classify(%{
      projection
      | last_seq: seq,
        updated_at: commit["written_at"] || projection.updated_at
    })
  end

  @doc false
  @spec refresh(t()) :: t()
  def refresh(%__MODULE__{tree: tree} = projection) do
    %{projection | messages: plain_messages(tree), model_messages: plain_model_messages(tree)}
  end

  @doc """
  Returns tool executions started without a durable result, in start order.

  A tool result message resolves the matching `tool.execution_started` by its
  tool call id, in whichever turn it arrives (a repair turn settles the calls
  an earlier turn left open), so resolved executions are excluded. A start
  without a later tool message means the tool may have produced an external
  effect whose outcome is uncertain. Automatic continuation is prohibited
  while such a tool is unresolved.
  """
  @spec uncertain_tools(t()) :: [pending_tool()]
  def uncertain_tools(%__MODULE__{pending_tools: pending}), do: pending

  @doc """
  Returns the durable metadata summary for catalog and listing.

  `:context_tokens` estimates the context the next request would send, so a
  frontend can warn before reopening a session whose provider cache expired.
  """
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = projection) do
    %{
      session_id: projection.session_id,
      title: projection.title,
      cwd: projection.cwd,
      created_at: projection.created_at,
      updated_at: projection.updated_at || projection.created_at,
      status: projection.status,
      model: projection.model_ref,
      tags: projection.tags,
      message_count: length(projection.messages),
      model_message_count: length(projection.model_messages),
      compaction_count: length(projection.compactions),
      context_tokens: context_tokens(projection),
      preview: preview(projection),
      last_indexed_seq: projection.last_seq,
      parent_session_id: parent_session_id(projection)
    }
  end

  @doc """
  Estimates the tokens of the active model context, or `nil` when it is empty.

  Uses `Tackle.Lib.ContextUsage.since_checkpoint/1`: the latest assistant usage
  on the model projection is the checkpoint, and messages after it are
  estimated like `Tackle.Lib.ContextUsage.estimate_message/1` does, images
  included. Without a checkpoint the whole projection is estimated. Messages
  are decoded newest first and only up to the checkpoint; undecodable ones
  are skipped. The system prompt and tool definitions are not part of the
  durable projection, so the estimate excludes them.
  """
  @spec context_tokens(t()) :: non_neg_integer() | nil
  def context_tokens(%__MODULE__{model_messages: []}), do: nil

  def context_tokens(%__MODULE__{model_messages: messages}) do
    {checkpoint, trailing} =
      messages
      |> Enum.reverse()
      |> Stream.flat_map(fn data ->
        case Codec.decode_message(data) do
          {:ok, message} -> [message]
          {:error, _reason} -> []
        end
      end)
      |> ContextUsage.since_checkpoint()

    (checkpoint || 0) + trailing
  end

  @doc """
  Returns the default searchable text for a session.

  Explicit or derived title, user and assistant message text, cwd, and explicit
  tags are indexed. Reasoning, provider continuation state, tool arguments, and
  tool output are excluded by default to bound index size and accidental secret
  exposure. Search covers the complete archive, so switching branches never
  removes results.

  It is built on demand, when a session is searched or its summary sidecar is
  written, never per commit: its cost grows with the session.
  """
  @spec search_text(t()) :: String.t()
  def search_text(%__MODULE__{} = projection) do
    parts =
      [
        projection.title,
        projection.cwd,
        Enum.join(projection.tags, " ")
      ] ++ conversation_text(projection.messages)

    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @doc """
  Returns a bounded, payload-free summary of the conversation tree.

  Hosts that inspect a session without starting a runtime scope use this to
  discover branches, parent links, and the active position. Full message and
  compaction payloads stay in `messages` and `compactions` so they are not
  duplicated.
  """
  @spec tree_summary(t()) :: map()
  def tree_summary(%__MODULE__{tree: tree} = projection) do
    entries =
      tree
      |> Tree.enumerate()
      |> Enum.map(fn %{id: id, parent_id: parent_id, kind: kind} ->
        %{id: id, parent_id: parent_id, kind: kind}
      end)

    %{
      enabled?: projection.tree_enabled?,
      active_id: Tree.active_id(tree),
      entries: entries
    }
  end

  # The first part of the first user message, or the title without one.
  defp preview(%__MODULE__{} = projection) do
    projection.messages
    |> Enum.find_value(fn
      %{"role" => "user", "content" => content} when is_binary(content) and content != "" ->
        String.slice(content, 0, @preview_length)

      _message ->
        nil
    end)
    |> case do
      nil -> projection.title
      text -> text
    end
  end

  defp conversation_text(messages) do
    Enum.flat_map(messages, fn
      %{"role" => role, "content" => content}
      when role in ["user", "assistant"] and is_binary(content) and content != "" ->
        [content]

      _message ->
        []
    end)
  end

  defp parent_session_id(%__MODULE__{parent: %{"session_id" => session_id}}), do: session_id
  defp parent_session_id(_projection), do: nil

  defp apply_event(%{"type" => "session.created" = type, "data" => data}, projection) do
    check_metadata!(type, data)

    %{
      projection
      | title: Map.get(data, "title", projection.title),
        tags: Map.get(data, "tags") || projection.tags,
        model_ref: Map.get(data, "model_ref", projection.model_ref),
        thinking: Map.get(data, "thinking", projection.thinking),
        cwd: Map.get(data, "cwd", projection.cwd),
        tree_enabled?: projection.tree_enabled? or Map.get(data, "tree") == true
    }
  end

  defp apply_event(%{"type" => "session.metadata_changed" = type, "data" => data}, projection) do
    check_metadata!(type, data)

    %{
      projection
      | title: Map.get(data, "title", projection.title),
        tags: Map.get(data, "tags") || projection.tags
    }
  end

  defp apply_event(
         %{"type" => "session.configuration_changed" = type, "data" => data},
         projection
       ) do
    check_metadata!(type, data)

    %{
      projection
      | model_ref: Map.get(data, "model_ref", projection.model_ref),
        thinking: Map.get(data, "thinking", projection.thinking)
    }
  end

  defp apply_event(%{"type" => "session.recovered", "data" => data}, projection) do
    %{projection | recovered: data}
  end

  # Legacy: no longer written. It records when an earlier version closed the
  # session, which says nothing about the session's state now: a later turn
  # can resume it.
  defp apply_event(%{"type" => "session.closed", "data" => data}, projection) do
    %{projection | closed_at: Map.get(data, "closed_at")}
  end

  defp apply_event(%{"type" => "session.forked"}, projection), do: projection

  defp apply_event(%{"type" => "tree.enabled"}, projection) do
    %{projection | tree_enabled?: true}
  end

  defp apply_event(%{"type" => "tree.navigated", "data" => data}, projection) do
    case Tree.move(projection.tree, Map.get(data, "to_id")) do
      {:ok, tree} -> %{projection | tree: tree}
      {:error, reason} -> raise ProjectionError, reason: reason
    end
  end

  defp apply_event(%{"type" => "turn.started", "data" => data} = event, projection) do
    turn_id = data["turn_id"] || event["turn_id"]

    turn = %{
      turn_id: turn_id,
      operation: data["operation"],
      status: :started,
      started_at: data["started_at"],
      ended_at: nil,
      input: data["input"]
    }

    %{
      projection
      | turns: Map.put(projection.turns, turn_id, turn),
        active_turn: turn
    }
  end

  defp apply_event(%{"type" => "message.appended", "data" => data}, projection) do
    parent_id = parent_id(data, projection.tree.active_id)
    message = decode_message(Map.get(data, "message"))

    projection
    |> resolve_pending_tool(message)
    |> append_message(message, parent_id)
  end

  # Compaction replaces only the active branch's model surface. The canonical
  # archive is never touched, so history stays inspectable and searchable.
  # Sibling branches never inherit the checkpoint because it is an entry on one
  # branch's ancestry.
  defp apply_event(%{"type" => "context.compacted", "data" => data}, projection) do
    parent_id = parent_id(data, projection.tree.active_id)

    case Codec.decode_compaction(data) do
      {:ok, %Record{} = record} ->
        case Tree.append_compaction(projection.tree, record, parent_id: parent_id) do
          {:ok, tree, _entry} ->
            %{projection | tree: tree, compactions: append(projection.compactions, data)}

          {:error, reason} ->
            raise ProjectionError, reason: reason
        end

      {:error, reason} ->
        raise ProjectionError, reason: {:invalid_compaction, reason}
    end
  end

  defp apply_event(%{"type" => "tool.execution_started", "data" => data}, projection) do
    pending = %{
      tool_call_id: data["tool_call_id"],
      name: data["name"],
      started_at: data["started_at"],
      turn_id: active_turn_id(projection)
    }

    %{projection | pending_tools: append(projection.pending_tools, pending)}
  end

  # A terminal event settles its turn; any other event is not part of the
  # core projection.
  defp apply_event(%{"type" => type, "data" => data} = event, projection) do
    case Log.terminal_status(type) do
      nil -> projection
      status -> settle_turn(projection, event, data, status)
    end
  end

  defp apply_event(_event, projection), do: projection

  # Live commits keep the archive and active model surface materialized. Most
  # journal events do not touch either surface, so they only fold their durable
  # metadata. Message appends encode the new message once and extend the two
  # lists. A branch append, navigation, or compaction can change active ancestry
  # and therefore rebuilds only the active model path.
  defp apply_live_event(%{"type" => "message.appended", "data" => data}, projection) do
    previous_active_id = Tree.active_id(projection.tree)
    parent_id = parent_id(data, previous_active_id)
    message = decode_message(Map.get(data, "message"))
    plain = plain_message(message)

    projection =
      projection
      |> resolve_pending_tool(message)
      |> append_message(message, parent_id)

    model_messages =
      if parent_id == previous_active_id do
        append(projection.model_messages, plain)
      else
        plain_model_messages(projection.tree)
      end

    %{projection | messages: append(projection.messages, plain), model_messages: model_messages}
  end

  defp apply_live_event(%{"type" => type} = event, projection)
       when type in ["context.compacted", "tree.navigated"] do
    projection = apply_event(event, projection)
    %{projection | model_messages: plain_model_messages(projection.tree)}
  end

  defp apply_live_event(event, projection), do: apply_event(event, projection)

  defp append_message(%__MODULE__{tree: tree} = projection, message, parent_id) do
    case Tree.append_message(tree, message, parent_id: parent_id) do
      {:ok, tree, _entry} -> %{projection | tree: tree}
      {:error, reason} -> raise ProjectionError, reason: reason
    end
  end

  # A durable tool result settles the matching `tool.execution_started`, in
  # any turn: once the outcome is recorded the execution is no longer
  # uncertain, so it must not gate recovery. A start without a result stays
  # pending for the whole session.
  defp resolve_pending_tool(%__MODULE__{pending_tools: []} = projection, _message),
    do: projection

  defp resolve_pending_tool(projection, %Message{role: :tool, tool_call_id: id})
       when is_binary(id) do
    %{projection | pending_tools: Enum.reject(projection.pending_tools, &(&1.tool_call_id == id))}
  end

  defp resolve_pending_tool(projection, _message), do: projection

  # The archive and active model surface remain derivable from the tree. Replay
  # refreshes once after folding the complete journal; live commits maintain
  # them incrementally above.
  defp plain_messages(tree) do
    tree
    |> Tree.enumerate()
    |> Enum.flat_map(fn
      %{kind: :message, message: %Message{} = message} -> [plain_message(message)]
      _entry -> []
    end)
  end

  defp plain_model_messages(tree) do
    tree
    |> Tree.model_context()
    |> Enum.map(&plain_message/1)
  end

  defp plain_message(%Message{} = message) do
    message
    |> Codec.encode_message!()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Listings, search, and resume read these fields, so a value of another type
  # is a corrupt record rather than something to carry along. Missing fields
  # keep their previous value.
  defp check_metadata!(type, data) do
    Enum.each(data, fn {key, value} ->
      if not valid_metadata?(key, value),
        do: raise(ProjectionError, reason: {:invalid_event_data, type, key})
    end)
  end

  defp valid_metadata?(key, value) when key in ["title", "cwd", "model_ref"],
    do: is_nil(value) or is_binary(value)

  defp valid_metadata?("tags", tags),
    do: is_nil(tags) or (is_list(tags) and Enum.all?(tags, &is_binary/1))

  defp valid_metadata?("tree", tree), do: is_nil(tree) or is_boolean(tree)
  defp valid_metadata?(_key, _value), do: true

  defp decode_message(data) do
    case Codec.decode_message(data) do
      {:ok, message} -> message
      {:error, reason} -> raise ProjectionError, reason: reason
    end
  end

  defp parent_id(data, default) do
    if Map.has_key?(data, "parent_id"), do: data["parent_id"], else: default
  end

  defp settle_turn(projection, event, data, status) do
    turn_id = data["turn_id"] || event["turn_id"]

    turns =
      Map.update(projection.turns, turn_id, empty_turn(turn_id, status, data), fn turn ->
        %{turn | status: status, ended_at: data["ended_at"] || data["settled_at"]}
      end)

    %{projection | turns: turns, active_turn: nil}
  end

  defp empty_turn(turn_id, status, data) do
    %{
      turn_id: turn_id,
      operation: nil,
      status: status,
      started_at: nil,
      ended_at: data["ended_at"] || data["settled_at"],
      input: nil
    }
  end

  defp append(items, item), do: Enum.concat(items, [item])

  # Every commit keeps the status current, so live owners, replay, the
  # catalog, and the summary sidecar all report the same one.
  defp classify(%__MODULE__{active_turn: %{}} = projection),
    do: %{projection | status: :interrupted}

  defp classify(%__MODULE__{recovered: %{}} = projection), do: %{projection | status: :recovered}
  defp classify(%__MODULE__{} = projection), do: %{projection | status: :clean}

  defp active_turn_id(%__MODULE__{active_turn: %{turn_id: turn_id}}), do: turn_id
  defp active_turn_id(_projection), do: nil
end
