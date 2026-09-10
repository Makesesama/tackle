defmodule Tackle.Session.Log do
  @moduledoc """
  Durable journal schema: header, commit envelope, and event algebra.

  The journal's first logical item is a header that identifies the file and its
  durable session. Every following item is one complete commit envelope holding
  one or more versioned domain events and one monotonic session sequence number.

  A commit is the unit of atomicity: the complete envelope is passed to one
  `:disk_log.log/2` call. Several separate calls are never treated as one
  transaction.
  """

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
    "tool.execution_started" => 1,
    "turn.completed" => 1,
    "turn.errored" => 1,
    "turn.cancelled" => 1,
    "turn.crashed" => 1,
    "turn.abandoned" => 1
  }

  @terminal_events ~w(turn.completed turn.errored turn.cancelled turn.crashed turn.abandoned)

  @type event :: %{
          required(String.t()) => term()
        }

  @type commit :: %{required(String.t()) => term()}

  @doc "Returns the supported journal container format version."
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc "Returns the supported commit-envelope schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns every core event type with its current version."
  @spec event_versions() :: %{optional(String.t()) => pos_integer()}
  def event_versions, do: @event_versions

  @doc "Returns the event types that settle a turn."
  @spec terminal_events() :: [String.t()]
  def terminal_events, do: @terminal_events

  @doc "Returns true when `type` is a core event type this build understands."
  @spec known_event?(term()) :: boolean()
  def known_event?(type) when is_binary(type), do: Map.has_key?(@event_versions, type)
  def known_event?(_type), do: false

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
  Validates one commit envelope against the expected session and sequence.

  Required envelope rules are enforced here: matching session, contiguous
  sequence, unique commit identity, a non-empty event list, independently
  versioned events, and a durable plain-data payload.
  """
  @spec validate_commit(term(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def validate_commit(%{"record" => @commit_record} = commit, session_id, expected_seq) do
    cond do
      commit["schema_version"] != @schema_version ->
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
        validate_events(commit["events"])
    end
  end

  def validate_commit(%{}, _session_id, _expected_seq), do: {:error, {:invalid_commit, :record}}
  def validate_commit(other, _session_id, _expected_seq), do: {:error, {:invalid_commit, other}}

  @doc """
  Upcasts one event to the current in-memory schema.

  Reading an older journal never rewrites it. Unknown optional events are kept
  for callers that retain them but are ignored by the core projection.
  """
  @spec upcast_event(term()) :: {:ok, event()} | {:error, term()}
  def upcast_event(%{"type" => type, "version" => version} = event)
      when is_binary(type) and is_integer(version) do
    case Map.fetch(@event_versions, type) do
      {:ok, current} when version == current -> {:ok, event}
      {:ok, current} when version < current -> {:ok, upcast(type, version, event)}
      {:ok, _current} -> {:error, {:unsupported_event_version, type, version}}
      :error -> {:ok, event}
    end
  end

  def upcast_event(other), do: {:error, {:invalid_event, other}}

  @doc "Returns true when `event_type` settles a turn."
  @spec terminal_event?(term()) :: boolean()
  def terminal_event?(type), do: type in @terminal_events

  defp upcast(_type, _from_version, event), do: event

  defp validate_parent(nil), do: :ok

  defp validate_parent(%{"session_id" => session_id, "seq" => seq} = parent)
       when is_binary(session_id) and is_integer(seq) and seq >= 0 do
    case Map.keys(parent) -- ["session_id", "seq"] do
      [] -> :ok
      extra -> {:error, {:invalid_header_parent, extra}}
    end
  end

  defp validate_parent(other), do: {:error, {:invalid_header_parent, other}}

  defp validate_events(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case validate_event(event) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_event(%{"type" => type, "version" => version, "required" => required} = event)
       when is_binary(type) and is_integer(version) and is_boolean(required) do
    cond do
      required and not known_event?(type) ->
        {:error, {:unsupported_required_event, type, version}}

      Map.get(@event_versions, type) == version or not known_event?(type) ->
        case Codec.validate(Map.get(event, "data", %{})) do
          :ok -> :ok
          {:error, reason} -> {:error, {:invalid_event_data, type, reason}}
        end

      true ->
        {:error, {:unsupported_event_version, type, version}}
    end
  end

  defp validate_event(other), do: {:error, {:invalid_event, other}}
end
