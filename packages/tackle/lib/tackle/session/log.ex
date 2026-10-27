defmodule Tackle.Session.Log do
  @moduledoc """
  Durable journal schema: header, commit envelope, and event algebra.

  The journal's first logical item is a header that identifies the file and its
  durable session. Every following item is one complete commit envelope holding
  one or more versioned domain events and one monotonic session sequence number.

  A commit is the unit of atomicity: the complete envelope is passed to one
  `:disk_log.log/2` call. Several separate calls are never treated as one
  transaction.

  ## Versions

  The header's `format_version`, the envelope's `schema_version`, and each
  event's `version` evolve independently. A reader accepts every version from
  1 up to the current one and rejects newer ones as unsupported: the file may
  be valid under a newer Tackle. `read_commit/4` upcasts an older event to the
  current version in memory, one version at a time through the upcaster
  registered for `{type, from_version}`, before it validates the event, so the
  checks always describe the current schema. Bumping an event's version
  therefore requires an upcaster from every older version; reading never
  rewrites the file.

  ## Writing

  The journal builds each event it writes with the builders below
  (`turn_started/4`, `message_appended/2`, and so on), which only shape data:
  each is pure, takes the time it records, and validates nothing. The journal
  checks once, before it appends a commit, that every event's data is durable
  plain data (`Tackle.Session.Codec.validate/1`), which is what reading
  checks; envelopes and versions are this build's by construction.
  """

  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tree.Change
  alias Tackle.Session.Codec

  @header_record "tackle.session.header"
  @commit_record "tackle.session.commit"

  @format_version 1
  @schema_version 1

  @event_versions %{
    "session.created" => 1,
    "session.metadata_changed" => 1,
    "session.configuration_changed" => 1,
    "session.recovered" => 1,
    "session.closed" => 1,
    "session.forked" => 1,
    "turn.started" => 1,
    "message.appended" => 1,
    "context.compacted" => 1,
    "tree.enabled" => 1,
    "tree.navigated" => 1,
    "tool.execution_started" => 1,
    "turn.completed" => 1,
    "turn.errored" => 1,
    "turn.cancelled" => 1,
    "turn.crashed" => 1,
    "turn.abandoned" => 1
  }

  # `{type, from_version}` => a function from that version's event data to the
  # next version's. Empty while every event is at version 1.
  @upcasters %{}

  # The events that settle a turn, with the status each gives it.
  @terminal_events %{
    "turn.completed" => :completed,
    "turn.errored" => :errored,
    "turn.cancelled" => :cancelled,
    "turn.crashed" => :crashed,
    "turn.abandoned" => :abandoned
  }

  @type event :: %{
          required(String.t()) => term()
        }

  @type commit :: %{required(String.t()) => term()}

  @typedoc """
  The event schema a reader upcasts and validates against: the current
  version of every core event type and the upcasters from older versions.
  """
  @type schema :: %{
          versions: %{optional(String.t()) => pos_integer()},
          upcasters: %{optional({String.t(), pos_integer()}) => (map() -> map())}
        }

  @doc "Returns the event schema of this build: current versions and upcasters."
  @spec schema() :: schema()
  def schema, do: %{versions: @event_versions, upcasters: @upcasters}

  @doc "Builds the immutable session header."
  @spec header(keyword()) :: map()
  def header(opts) do
    %{
      "record" => @header_record,
      "format_version" => @format_version,
      "session_id" => Keyword.fetch!(opts, :session_id),
      "created_at" => Keyword.fetch!(opts, :created_at),
      "cwd" => Keyword.get(opts, :cwd),
      "parent" => Keyword.get(opts, :parent)
    }
  end

  @doc "Builds one versioned event with an explicit `required` flag."
  @spec event(String.t(), map(), keyword()) :: event()
  def event(type, data \\ %{}, opts \\ []) when is_binary(type) do
    %{
      "type" => type,
      "version" => Keyword.get(opts, :version, Map.get(@event_versions, type, 1)),
      "required" => Keyword.get(opts, :required, true),
      "data" => data
    }
  end

  @doc "Builds one complete commit envelope."
  @spec commit(keyword()) :: commit()
  def commit(opts) do
    %{
      "record" => @commit_record,
      "schema_version" => @schema_version,
      "session_id" => Keyword.fetch!(opts, :session_id),
      "seq" => Keyword.fetch!(opts, :seq),
      "commit_id" => Keyword.fetch!(opts, :commit_id),
      "written_at" => Keyword.fetch!(opts, :written_at),
      "turn_id" => Keyword.get(opts, :turn_id),
      "events" => Keyword.fetch!(opts, :events)
    }
  end

  @doc """
  Builds `session.created` for a new journal with `header`.

  `opts` hold the session's creation metadata: `:model_ref`, `:thinking`,
  `:title`, `:tags` (default `[]`), and `:tree`, whether the session may
  branch (default `false`).
  """
  @spec session_created(map(), keyword()) :: event()
  def session_created(header, opts) do
    event("session.created", %{
      "cwd" => header["cwd"],
      "model_ref" => Keyword.get(opts, :model_ref),
      "thinking" => Keyword.get(opts, :thinking),
      "title" => Keyword.get(opts, :title),
      "tags" => Keyword.get(opts, :tags, []),
      "tree" => Keyword.get(opts, :tree, false)
    })
  end

  @doc "Builds `session.recovered` from the reader's repair report."
  @spec session_recovered(map()) :: event()
  def session_recovered(info), do: event("session.recovered", info)

  @doc "Builds `session.forked`, the first event of a fork of `parent_id` at `parent_seq`."
  @spec session_forked(String.t(), non_neg_integer(), String.t()) :: event()
  def session_forked(parent_id, parent_seq, at) do
    event("session.forked", %{
      "parent_session_id" => parent_id,
      "parent_seq" => parent_seq,
      "forked_at" => at
    })
  end

  @doc "Builds `session.configuration_changed` for a model and a normalized thinking level."
  @spec configuration_changed(String.t() | nil, String.t() | nil, String.t()) :: event()
  def configuration_changed(model_ref, thinking, at) do
    event("session.configuration_changed", %{
      "model_ref" => model_ref,
      "thinking" => thinking,
      "changed_at" => at
    })
  end

  @doc """
  Builds `session.metadata_changed` from `attrs` (such as `"title"` and
  `"tags"`), recording `at` unless `attrs` has a `"changed_at"`.
  """
  @spec metadata_changed(map(), String.t()) :: event()
  def metadata_changed(attrs, at),
    do: event("session.metadata_changed", Map.put_new(attrs, "changed_at", at))

  @doc "Builds `turn.started` for the turn `turn_id`."
  @spec turn_started(String.t(), :run | :continue | :repair, String.t() | nil, String.t()) ::
          event()
  def turn_started(turn_id, operation, input, at) when is_atom(operation) do
    event("turn.started", %{
      "turn_id" => turn_id,
      "operation" => Atom.to_string(operation),
      "input" => input,
      "started_at" => at
    })
  end

  @doc """
  Builds `message.appended` for a settled message.

  `parent` is `:none` for a message attached to the active entry, whose
  parent is implied and not written, or `{:tree, parent_id}` for the tree
  entry it attaches to (`nil` for a new root).
  """
  @spec message_appended(Message.t(), :none | {:tree, String.t() | nil}) :: event()
  def message_appended(%Message{} = message, parent) do
    data = %{"message" => Codec.encode_message!(message)}

    case parent do
      :none -> event("message.appended", data)
      {:tree, parent_id} -> event("message.appended", Map.put(data, "parent_id", parent_id))
    end
  end

  @doc """
  Builds `tool.execution_started` for a tool call (a `Tackle.Lib.Tool.Call`,
  or a map with its `id`, `name`, and `arguments`) about to run.
  """
  @spec tool_started(Call.t() | map(), String.t()) :: event()
  def tool_started(call, at) do
    call = normalize_tool_call(call)

    event("tool.execution_started", %{
      "tool_call_id" => Map.get(call, "id"),
      "name" => Map.get(call, "name"),
      "arguments" => Map.get(call, "arguments") || %{},
      "started_at" => at
    })
  end

  @doc """
  Builds the terminal event `type` (see `terminal_event?/1`) that settles the
  turn `turn_id`, with `data` and the time it settled unless `data` has a
  `"settled_at"`.
  """
  @spec turn_settled(String.t(), String.t(), map(), String.t()) :: event()
  def turn_settled(type, turn_id, data, at) do
    event(type, data |> Map.put("turn_id", turn_id) |> Map.put_new("settled_at", at))
  end

  @doc """
  Builds `context.compacted` from encoded compaction data
  (`Tackle.Session.Codec.encode_compaction/1`).
  """
  @spec context_compacted(map()) :: event()
  def context_compacted(data), do: event("context.compacted", data)

  @doc "Builds `tree.navigated` for a committed navigation."
  @spec tree_navigated(Change.t(), String.t()) :: event()
  def tree_navigated(%Change{} = change, at) do
    event("tree.navigated", %{
      "from_id" => change.from_id,
      "to_id" => change.to_id,
      "selected_id" => change.selected_id,
      "mode" => Atom.to_string(change.mode),
      "revision" => change.revision,
      "navigated_at" => at
    })
  end

  @doc "Builds `tree.enabled`, which lets a linear session branch from now on."
  @spec tree_enabled(String.t()) :: event()
  def tree_enabled(at), do: event("tree.enabled", %{"enabled_at" => at})

  defp normalize_tool_call(%Call{} = call) do
    call
    |> Map.from_struct()
    |> Map.take([:id, :name, :arguments])
    |> Codec.normalize()
  end

  defp normalize_tool_call(call), do: Codec.normalize(call)

  @doc """
  Validates the header against the expected session identity.

  Unknown physical format versions are unsupported, not corrupt: the file may
  be perfectly valid under a newer Tackle.
  """
  @spec validate_header(term(), String.t()) :: :ok | {:error, term()}
  def validate_header(%{"record" => @header_record} = header, session_id) do
    cond do
      not is_integer(header["format_version"]) ->
        {:error, {:invalid_header, :format_version}}

      header["format_version"] > @format_version ->
        {:error, {:unsupported_format_version, header["format_version"]}}

      header["format_version"] < 1 ->
        {:error, {:invalid_header, :format_version}}

      header["session_id"] != session_id ->
        {:error, {:header_session_mismatch, header["session_id"], session_id}}

      not is_binary(header["created_at"]) ->
        {:error, {:invalid_header, :created_at}}

      not is_nil(header["cwd"]) and not is_binary(header["cwd"]) ->
        {:error, {:invalid_header, :cwd}}

      true ->
        validate_parent(header["parent"])
    end
  end

  def validate_header(%{}, _session_id), do: {:error, {:invalid_header, :record}}
  def validate_header(other, _session_id), do: {:error, {:invalid_header, other}}

  @doc """
  Reads one stored commit: validates its envelope (a supported schema version,
  matching session, the expected sequence, a commit id, a write time, and a
  non-empty event list), upcasts every event to its current version, then
  validates the events against `schema`.

  Envelope schema versions and event versions from 1 up to the current one are
  accepted; newer ones are unsupported. Unknown optional events are kept
  unchanged for callers that retain them; the core projection ignores them.
  """
  @spec read_commit(term(), String.t(), pos_integer(), schema()) ::
          {:ok, commit()} | {:error, term()}
  def read_commit(commit, session_id, expected_seq, schema \\ schema()) do
    # Version 1 is the only envelope schema so far; a new one adds its upcast
    # here, before the events are read.
    with :ok <- validate_envelope(commit, session_id, expected_seq),
         events = Enum.map(commit["events"], &upcast_event(&1, schema)),
         :ok <- validate_events(events, schema) do
      {:ok, %{commit | "events" => events}}
    end
  end

  # Upcasts one event to the current version `schema` gives its type. Each
  # step applies the upcaster registered for `{type, version}` to the event's
  # data. An event of an unknown type, of the current or a newer version, or
  # without an upcaster for its next step is returned unchanged, so validation
  # reports it.
  defp upcast_event(%{"type" => type, "version" => version} = event, schema)
       when is_binary(type) and is_integer(version) and version >= 1 do
    with {:ok, current} when version < current <- Map.fetch(schema.versions, type),
         {:ok, upcaster} <- Map.fetch(schema.upcasters, {type, version}) do
      event
      |> Map.merge(%{"version" => version + 1, "data" => upcaster.(Map.get(event, "data", %{}))})
      |> upcast_event(schema)
    else
      _current_or_unknown -> event
    end
  end

  defp upcast_event(event, _schema), do: event

  @doc "Returns true when `event_type` settles a turn."
  @spec terminal_event?(term()) :: boolean()
  def terminal_event?(type), do: is_map_key(@terminal_events, type)

  @doc """
  Returns the status a terminal event gives its turn (`"turn.completed"`
  completes it), or `nil` for an event that settles none.
  """
  @spec terminal_status(term()) ::
          :completed | :errored | :cancelled | :crashed | :abandoned | nil
  def terminal_status(type), do: Map.get(@terminal_events, type)

  defp validate_parent(nil), do: :ok

  defp validate_parent(%{"session_id" => session_id, "seq" => seq} = parent)
       when is_binary(session_id) and is_integer(seq) and seq >= 0 do
    case Map.keys(parent) -- ["session_id", "seq"] do
      [] -> :ok
      extra -> {:error, {:invalid_header_parent, extra}}
    end
  end

  defp validate_parent(other), do: {:error, {:invalid_header_parent, other}}

  defp validate_envelope(%{"record" => @commit_record} = commit, session_id, expected_seq) do
    cond do
      not supported_schema_version?(commit["schema_version"]) ->
        {:error, {:unsupported_schema_version, commit["schema_version"]}}

      commit["session_id"] != session_id ->
        {:error, {:commit_session_mismatch, commit["session_id"], session_id}}

      commit["seq"] != expected_seq ->
        {:error, {:sequence_mismatch, expected_seq, commit["seq"]}}

      not is_binary(commit["commit_id"]) ->
        {:error, {:invalid_commit_id, commit["commit_id"]}}

      not is_binary(commit["written_at"]) ->
        {:error, {:invalid_commit, :written_at}}

      not is_list(commit["events"]) or commit["events"] == [] ->
        {:error, {:invalid_commit, :events}}

      true ->
        :ok
    end
  end

  defp validate_envelope(%{}, _session_id, _expected_seq),
    do: {:error, {:invalid_commit, :record}}

  defp validate_envelope(other, _session_id, _expected_seq),
    do: {:error, {:invalid_commit, other}}

  defp supported_schema_version?(version),
    do: is_integer(version) and version >= 1 and version <= @schema_version

  defp validate_events(events, schema) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case validate_event(event, schema) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_event(
         %{"type" => type, "version" => version, "required" => required} = event,
         schema
       )
       when is_binary(type) and is_integer(version) and is_boolean(required) do
    case Map.fetch(schema.versions, type) do
      {:ok, ^version} -> validate_event_data(event, type)
      {:ok, _other} -> {:error, {:unsupported_event_version, type, version}}
      :error when required -> {:error, {:unsupported_required_event, type, version}}
      :error -> validate_event_data(event, type)
    end
  end

  defp validate_event(other, _schema), do: {:error, {:invalid_event, other}}

  # Event data is a plain map; the projection reads its fields by key.
  defp validate_event_data(event, type) do
    case Map.get(event, "data", %{}) do
      %{} = data when not is_struct(data) ->
        case Codec.validate(data) do
          :ok -> :ok
          {:error, reason} -> {:error, {:invalid_event_data, type, reason}}
        end

      _other ->
        {:error, {:invalid_event_data, type, :not_a_map}}
    end
  end
end
