defmodule Tackle.Session.Store do
  @moduledoc """
  High-level durable session operations: inspect, list, search, fork, delete.

  These operations read journals and derived catalog data. They never expose
  the journal process or `:disk_log` name, and they never mutate a live journal.
  A fork creates a new self-contained journal; deletion renames a complete
  session directory into `sessions/trash/` before removing it from the catalog.
  """

  alias Tackle.Runtime.ID
  alias Tackle.Session.Catalog
  alias Tackle.Session.Journal
  alias Tackle.Session.Log
  alias Tackle.Session.Projection
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage

  @doc """
  Reads and projects a session without creating an agent scope.

  Returns the durable conversation data, recovery status, and uncertain tool
  executions. It never returns runtime handles.
  """
  @spec inspect_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_session(session_id, opts \\ []) do
    with {:ok, replay} <- Reader.read(session_id, opts) do
      projection = replay.projection

      {:ok,
       %{
         session_id: session_id,
         status: projection.status,
         last_seq: projection.last_seq,
         parent: projection.parent,
         metadata: Projection.metadata(projection),
         messages: projection.messages,
         model_messages: projection.model_messages,
         compactions: projection.compactions,
         tree: Projection.tree_summary(projection),
         uncertain_tools: Projection.uncertain_tools(projection)
       }}
    end
  end

  @doc "Lists durable sessions with stable cursor pagination."
  @spec list(map() | keyword()) ::
          {:ok, %{sessions: [Catalog.Entry.t()], next_cursor: String.t() | nil}}
  def list(filters \\ %{}), do: Catalog.list(filters)

  @doc "Searches durable sessions using the default indexed fields."
  @spec search(String.t(), map() | keyword()) ::
          {:ok, %{sessions: [Catalog.Entry.t()], next_cursor: String.t() | nil}}
  def search(query, filters \\ %{}), do: Catalog.search(query, filters)

  @doc "Runs an explicit durability barrier for a live session."
  @spec flush(String.t()) :: :ok | {:error, term()}
  def flush(session_id) do
    case Journal.whereis(session_id) do
      {:ok, journal} -> Journal.flush(journal)
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Materializes a new self-contained session from validated parent history.

  The child journal records its lineage in the header and a `session.forked`
  event, then copies the parent's validated commits up to `:seq`. The child can
  be loaded after the parent is deleted: lineage is for navigation, not replay.
  """
  @spec fork(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fork(source_session_id, opts \\ []) do
    with :ok <- Storage.validate_session_id(source_session_id),
         {:ok, replay} <- Reader.read(source_session_id, opts),
         {:ok, selected, parent_seq} <- select_commits(replay.commits, opts),
         new_id = Keyword.get(opts, :session_id) || ID.generate(),
         :ok <- Storage.validate_session_id(new_id),
         {:ok, final_dir} <- Storage.session_dir(new_id, opts),
         :ok <- ensure_absent(final_dir),
         {:ok, temp_dir} <- Storage.temporary_session_dir(opts) do
      publish_fork(
        temp_dir,
        final_dir,
        new_id,
        source_session_id,
        parent_seq,
        replay,
        selected,
        opts
      )
    end
  end

  @doc """
  Moves an inactive session into the trash and removes it from the catalog.

  Active sessions cannot be deleted. Permanent purge is a separate operation.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(session_id, opts \\ []) do
    case Journal.whereis(session_id) do
      {:ok, journal} when is_pid(journal) ->
        if Process.alive?(journal) do
          {:error, :session_active}
        else
          trash(session_id, opts)
        end

      {:error, :not_found} ->
        trash(session_id, opts)
    end
  end

  defp trash(session_id, opts) do
    with {:ok, _trashed} <- Storage.trash_session(session_id, opts) do
      Catalog.forget(session_id)
      :ok
    end
  end

  @doc "Returns the derived catalog summary for a session."
  @spec summary(String.t(), keyword()) :: {:ok, Catalog.Entry.t()} | {:error, term()}
  def summary(session_id, opts \\ []) do
    case Catalog.get(session_id) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> summary_from_journal(session_id, opts)
    end
  end

  defp summary_from_journal(session_id, opts) do
    with {:ok, projection} <- Reader.projection(session_id, opts) do
      entry =
        projection
        |> summary_map()
        |> Catalog.encode_summary()
        |> Catalog.decode_summary()

      {:ok, Catalog.Entry.public(entry)}
    end
  end

  defp publish_fork(temp_dir, final_dir, new_id, parent_id, parent_seq, replay, selected, opts) do
    with :ok <- write_fork_journal(temp_dir, new_id, parent_id, parent_seq, replay, selected),
         :ok <- validate_fork(temp_dir, new_id, opts),
         :ok <- Storage.publish_directory(temp_dir, final_dir) do
      index_fork(new_id, opts)
      {:ok, new_id}
    end
  after
    _ = File.rm_rf(temp_dir)
  end

  defp validate_fork(temp_dir, new_id, opts) do
    path = Path.join(temp_dir, "session.dlog")

    case Reader.read(new_id, Keyword.put(opts, :path, path)) do
      {:ok, _replay} -> :ok
      {:error, reason} -> {:error, {:fork_validation_failed, reason}}
    end
  end

  defp index_fork(new_id, opts) do
    case Reader.projection(new_id, opts) do
      {:ok, projection} -> Catalog.record(summary_map(projection))
      {:error, _reason} -> :ok
    end
  end

  defp summary_map(%Projection{} = projection) do
    projection
    |> Projection.metadata()
    |> Map.put(:search_text, Projection.search_text(projection))
  end

  defp select_commits(commits, opts) do
    last_seq =
      case List.last(commits) do
        %{"seq" => seq} -> seq
        _other -> 0
      end

    upto = Keyword.get(opts, :seq, last_seq)

    selected =
      commits
      |> Enum.filter(&(&1["seq"] <= upto))
      |> Enum.map(&strip_events/1)
      |> Enum.reject(&(&1["events"] == []))

    {:ok, selected, upto}
  end

  # A fork is a fresh resumable session: the parent's terminal session events
  # describe the parent's lifecycle, not the child's.
  defp strip_events(commit) do
    events =
      Enum.reject(commit["events"], fn event ->
        event["type"] in ["session.closed", "session.recovered"]
      end)

    %{commit | "events" => events}
  end

  defp write_fork_journal(temp_dir, new_id, parent_id, parent_seq, replay, commits) do
    path = Path.join(temp_dir, "session.dlog")
    name = {:tackle_fork, new_id}

    options = [
      name: name,
      file: String.to_charlist(path),
      type: :halt,
      format: :internal,
      mode: :read_write,
      repair: false,
      notify: false,
      size: :infinity
    ]

    case :disk_log.open(options) do
      {:ok, name} ->
        write_fork_items(name, new_id, parent_id, parent_seq, replay, commits)

      {:error, reason} ->
        {:error, {:fork_open_failed, path, reason}}
    end
  end

  defp write_fork_items(name, new_id, parent_id, parent_seq, replay, commits) do
    header =
      Log.header(
        session_id: new_id,
        created_at: now(),
        cwd: replay.header["cwd"],
        parent: %{"session_id" => parent_id, "seq" => parent_seq}
      )

    forked =
      Log.event("session.forked", %{
        "parent_session_id" => parent_id,
        "parent_seq" => parent_seq,
        "forked_at" => now()
      })

    items =
      [header, new_commit(new_id, 1, nil, [forked])] ++
        (commits
         |> Enum.with_index(2)
         |> Enum.map(fn {commit, seq} ->
           new_commit(new_id, seq, commit["turn_id"], commit["events"])
         end))

    result =
      Enum.reduce_while(items, :ok, fn item, :ok ->
        case :disk_log.log(name, item) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:fork_write_failed, reason}}}
        end
      end)

    with :ok <- result,
         :ok <- sync_fork(name) do
      :ok = :disk_log.close(name)
      :ok
    end
  end

  defp sync_fork(name) do
    case :disk_log.sync(name) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = :disk_log.close(name)
        {:error, {:fork_sync_failed, reason}}
    end
  end

  defp new_commit(session_id, seq, turn_id, events) do
    Log.commit(
      session_id: session_id,
      seq: seq,
      commit_id: ID.generate(),
      written_at: now(),
      turn_id: turn_id,
      events: events
    )
  end

  defp ensure_absent(final_dir) do
    if File.exists?(final_dir) do
      {:error, {:session_exists, final_dir}}
    else
      :ok
    end
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
