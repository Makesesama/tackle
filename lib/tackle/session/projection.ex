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

  `tree_enabled?` records whether the session is allowed to branch. A legacy
  linear journal keeps `false` until the host records an explicit
  `tree.enabled` transition; the derived chain is already present either way.
  """

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tree
  alias Tackle.Session.Codec
  alias Tackle.Session.Compaction
  alias Tackle.Session.ProjectionError

  @terminal_events ~w(turn.completed turn.errored turn.cancelled turn.crashed turn.abandoned)

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
            tree: nil,
            messages: [],
            model_messages: [],
            compactions: [],
            turns: %{},
            active_turn: nil,
            last_seq: 0,
            status: :clean,
            recovered: nil,
            closed_at: nil

  @type turn :: %{
          required(String.t()) => term()
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
          last_seq: non_neg_integer(),
          status: :clean | :closed | :interrupted | :recovered | :corrupt | :unsupported,
          recovered: map() | nil,
          closed_at: String.t() | nil
        }

  @doc "Builds an empty projection from a validated header."
  @spec new(map(), keyword()) :: t()
  def new(header, opts \\ []) do
    %__MODULE__{
      session_id: header["session_id"],
      created_at: header["created_at"],
      updated_at: header["created_at"],
      cwd: header["cwd"],
      parent: header["parent"],
      model_ref: Keyword.get(opts, :model_ref),
      thinking: Keyword.get(opts, :thinking),
      title: Keyword.get(opts, :title),
      tags: Keyword.get(opts, :tags, []),
      tree_enabled?: Keyword.get(opts, :tree, false) or header["tree"] == true,
      tree: Tree.new()
    }
  end

  @doc """
  Applies one validated commit to a projection.

  The commit envelope must already have passed `Tackle.Session.Log.validate_commit/3`.
  Unknown optional events are ignored by the core projection. A commit that
  cannot be folded consistently raises `Tackle.Session.ProjectionError` so
  replay can reject it instead of dropping history.
  """
  @spec apply_commit(t(), map()) :: t()
  def apply_commit(%__MODULE__{} = projection, %{"seq" => seq, "events" => events} = commit) do
    projection =
      events
      |> Enum.reduce(projection, &apply_event/2)
      |> refresh()

    %{projection | last_seq: seq, updated_at: commit["written_at"] || projection.updated_at}
  end

  @doc "Returns the projection's derived recovery status."
  @spec classify(t()) :: t()
  def classify(%__MODULE__{active_turn: active_turn} = projection) when not is_nil(active_turn) do
    %{projection | status: :interrupted}
  end

  def classify(%__MODULE__{status: :closed} = projection), do: projection
  def classify(%__MODULE__{recovered: %{}} = projection), do: %{projection | status: :recovered}
  def classify(%__MODULE__{} = projection), do: %{projection | status: :clean}

  @doc """
  Returns tool executions started without a durable result.

  A tool start without a later tool message means the tool may have produced an
  external effect whose outcome is uncertain. Automatic continuation is
  prohibited while such a tool is unresolved.
  """
  @spec uncertain_tools(t()) :: [map()]
  def uncertain_tools(%__MODULE__{turns: turns}) do
    turns
    |> Map.values()
    |> Enum.flat_map(fn turn -> Map.get(turn, :pending_tools, []) end)
  end

  @doc "Returns the durable metadata summary for catalog and listing."
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
      preview: preview(projection),
      last_indexed_seq: projection.last_seq,
      parent_session_id: parent_session_id(projection)
    }
  end

  @doc """
  Returns the default searchable text for a session.

  Explicit or derived title, user and assistant message text, cwd, and explicit
  tags are indexed. Reasoning, provider continuation state, tool arguments, and
  tool output are excluded by default to bound index size and accidental secret
  exposure. Search covers the complete archive, so switching branches never
  removes results.
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
  def tree_summary(%__MODULE__{tree: nil} = projection) do
    %{enabled?: projection.tree_enabled?, active_id: nil, entries: []}
  end

  def tree_summary(%__MODULE__{tree: %Tree{} = tree} = projection) do
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

  @doc "Returns the first part of the first user message as a preview."
  @spec preview(t(), non_neg_integer()) :: String.t() | nil
  def preview(%__MODULE__{} = projection, limit \\ 200) do
    projection.messages
    |> Enum.find_value(fn
      %{"role" => "user", "content" => content} when is_binary(content) and content != "" ->
        String.slice(content, 0, limit)

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

  defp apply_event(%{"type" => "session.created", "data" => data}, projection) do
    %{
      projection
      | title: Map.get(data, "title", projection.title),
        tags: Map.get(data, "tags", projection.tags),
        model_ref: Map.get(data, "model_ref", projection.model_ref),
        thinking: Map.get(data, "thinking", projection.thinking),
        cwd: Map.get(data, "cwd", projection.cwd),
        tree_enabled?: projection.tree_enabled? or Map.get(data, "tree", false)
    }
  end

  defp apply_event(%{"type" => "session.metadata_changed", "data" => data}, projection) do
    %{
      projection
      | title: Map.get(data, "title", projection.title),
        tags: Map.get(data, "tags", projection.tags)
    }
  end

  defp apply_event(%{"type" => "session.configuration_changed", "data" => data}, projection) do
    %{
      projection
      | model_ref: Map.get(data, "model_ref", projection.model_ref),
        thinking: Map.get(data, "thinking", projection.thinking)
    }
  end

  defp apply_event(%{"type" => "session.recovered", "data" => data}, projection) do
    %{projection | recovered: data, status: :recovered}
  end

  defp apply_event(%{"type" => "session.closed", "data" => data}, projection) do
    %{
      projection
      | status: :closed,
        closed_at: Map.get(data, "closed_at")
    }
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
      input: data["input"],
      pending_tools: []
    }

    %{
      projection
      | turns: Map.put(projection.turns, turn_id, turn),
        active_turn: turn
    }
  end

  defp apply_event(%{"type" => "message.appended", "data" => data}, projection) do
    parent_id = parent_id(data, projection.tree.active_id)
    message = decode_message(Map.fetch!(data, "message"))

    case Tree.append_message(projection.tree, message, parent_id: parent_id) do
      {:ok, tree, _entry} -> %{projection | tree: tree}
      {:error, reason} -> raise ProjectionError, reason: reason
    end
  end

  # Compaction replaces only the active branch's model surface. The canonical
  # archive is never touched, so history stays inspectable and searchable.
  # Sibling branches never inherit the checkpoint because it is an entry on one
  # branch's ancestry.
  defp apply_event(%{"type" => "context.compacted", "data" => data}, projection) do
    parent_id = parent_id(data, projection.tree.active_id)

    case Compaction.decode(data) do
      {:ok, %Record{} = record} ->
        case Tree.append_compaction(projection.tree, record, parent_id: parent_id) do
          {:ok, tree, _entry} ->
            %{projection | tree: tree, compactions: projection.compactions ++ [data]}

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
      started_at: data["started_at"]
    }

    update_active_turn(projection, fn turn ->
      %{turn | pending_tools: turn.pending_tools ++ [pending]}
    end)
  end

  defp apply_event(%{"type" => type, "data" => data} = event, projection)
       when type in @terminal_events do
    settle_turn(projection, event, data)
  end

  defp apply_event(_event, projection), do: projection

  # The archive and the active model surface are both derived projections of the
  # tree, so a single fold implementation serves live appends and replay.
  defp refresh(%__MODULE__{tree: tree} = projection) do
    %{
      projection
      | messages: plain_messages(tree),
        model_messages: plain_model_messages(tree)
    }
  end

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

  defp decode_message(data) do
    case Codec.decode_message(data) do
      {:ok, message} -> message
      {:error, reason} -> raise ProjectionError, reason: reason
    end
  end

  defp parent_id(data, default) do
    if Map.has_key?(data, "parent_id"), do: data["parent_id"], else: default
  end

  defp settle_turn(projection, event, data) do
    turn_id = data["turn_id"] || event["turn_id"]
    status = terminal_status(event["type"])

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
      input: nil,
      pending_tools: []
    }
  end

  defp terminal_status("turn.completed"), do: :completed
  defp terminal_status("turn.errored"), do: :errored
  defp terminal_status("turn.cancelled"), do: :cancelled
  defp terminal_status("turn.crashed"), do: :crashed
  defp terminal_status("turn.abandoned"), do: :abandoned

  defp update_active_turn(%__MODULE__{active_turn: nil} = projection, _fun), do: projection

  defp update_active_turn(%__MODULE__{active_turn: active_turn} = projection, fun) do
    updated = fun.(active_turn)

    %{
      projection
      | active_turn: updated,
        turns: Map.put(projection.turns, updated.turn_id, updated)
    }
  end
end
