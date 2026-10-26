defmodule Tackle.Session.Store do
  @moduledoc """
  High-level durable session operations: inspect, list, search, fork, archive,
  and delete.

  These operations read journals and derived catalog data. They never expose
  the journal process or `:disk_log` name, and they never mutate a live journal.
  A fork creates a new self-contained journal; archiving renames a complete
  session directory into `sessions/archive/` and marks it archived in the
  catalog; deletion renames it into `sessions/trash/` before removing it from
  the catalog.
  """

  alias Tackle.Runtime.ID
  alias Tackle.Session.Catalog
  alias Tackle.Session.Journal
  alias Tackle.Session.Log
  alias Tackle.Session.Projection
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage
  alias Tackle.Session.UsageTimeline

  @doc """
  Reads and projects a session without creating an agent scope.

  Returns the durable conversation data, recovery status, and uncertain tool
  executions. It never returns runtime handles. A live session is flushed
  first, so the file includes its write-behind tail.
  """
  @spec inspect_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_session(session_id, opts \\ []) do
    with :ok <- flush_live(session_id),
         {:ok, replay} <- Reader.read(session_id, opts) do
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

  @doc "Returns chronological settled token usage for one durable session."
  @spec usage_timeline(String.t(), keyword()) ::
          {:ok, UsageTimeline.t()} | {:error, term()}
  def usage_timeline(session_id, opts \\ []) do
    with {:ok, projection} <- usage_projection(session_id, reader_opts(opts)) do
      {:ok, UsageTimeline.from_projection(projection, opts)}
    end
  end

  @doc """
  Returns chronological settled token usage across every durable session.

  Session journals are replayed concurrently with a bounded worker count. Pass
  `:usage_concurrency` to override the default, which is capped at eight.
  `:since` and `:until` accept UTC-compatible `DateTime` bounds for the returned
  samples.
  """
  @spec all_usage_timeline(keyword()) :: {:ok, UsageTimeline.t()} | {:error, term()}
  def all_usage_timeline(opts \\ []) do
    reader_opts = reader_opts(opts)

    with {:ok, locations} <- Storage.list_session_locations(reader_opts) do
      results =
        Task.async_stream(
          locations,
          fn {id, location_opts} -> Reader.projection(id, location_opts) end,
          ordered: true,
          max_concurrency: usage_concurrency(opts),
          timeout: :infinity
        )

      {timelines, skipped} =
        locations
        |> Enum.zip(results)
        |> Enum.reduce({[], []}, fn
          {_location, {:ok, {:ok, projection}}}, {timelines, skipped} ->
            {[UsageTimeline.from_projection(projection, opts) | timelines], skipped}

          {{session_id, _opts}, {:ok, {:error, reason}}}, {timelines, skipped} ->
            {timelines, [%{session_id: session_id, reason: reason} | skipped]}

          {{session_id, _opts}, {:exit, reason}}, {timelines, skipped} ->
            {timelines, [%{session_id: session_id, reason: {:reader_exit, reason}} | skipped]}
        end)

      {:ok, UsageTimeline.merge(Enum.reverse(timelines), Enum.reverse(skipped))}
    end
  end

  defp reader_opts(opts), do: Keyword.drop(opts, [:usage_concurrency, :since, :until])

  defp usage_concurrency(opts) do
    default = min(max(System.schedulers_online(), 1), 8)

    case Keyword.get(opts, :usage_concurrency, default) do
      concurrency when is_integer(concurrency) and concurrency > 0 -> concurrency
      _invalid -> default
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

  # Best-effort barrier before reading a live session's file: it writes the
  # write-behind tail to the file, and costs nothing when everything is already
  # synced. A journal that is shutting down syncs and closes its file itself,
  # and a failed one has nothing more to write, so the file is read as it is.
  defp flush_live(session_id) do
    with {:ok, journal} <- Journal.whereis(session_id),
         {:error, reason} <- Journal.await_durable(journal) do
      case reason do
        {:journal_unavailable, _reason} -> :ok
        {:journal_failure, _reason} -> :ok
        other -> {:error, other}
      end
    else
      _ok_or_not_found -> :ok
    end
  end

  @doc """
  Materializes a new self-contained session from validated parent history.

  The child journal records its lineage in the header and a `session.forked`
  event, then copies the parent's validated commits up to `:seq` (by default
  all of them); a `:seq` that is not one of the parent's commit sequence
  numbers is `{:error, {:invalid_fork_seq, seq}}`. A live parent is flushed
  first, so its write-behind tail is included. The child can
  be loaded after the parent is deleted: lineage is for navigation, not replay.
  """
  @spec fork(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fork(source_session_id, opts \\ []) do
    with :ok <- Storage.validate_session_id(source_session_id),
         :ok <- flush_live(source_session_id),
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
    with :ok <- ensure_inactive(session_id), do: trash(session_id, opts)
  end

  @doc """
  Archives an inactive session.

  The session directory moves into `sessions/archive/`, keeping its project
  directory, and the catalog lists it only when archived sessions are
  requested. The journal is untouched, so an archived session can still be
  inspected with `archived: true` and restored with `unarchive/2`. A session
  that is live in this node is refused with `{:error, :session_active}`; one
  owned by another process with `{:error, {:session_in_use, owner}}`.
  """
  @spec archive(String.t(), keyword()) :: :ok | {:error, term()}
  def archive(session_id, opts \\ []), do: relocate(session_id, opts, true)

  @doc """
  Restores an archived session to the active sessions.

  Fails with `{:error, {:session_exists, session_id}}` when an active session
  with the same id exists, and `{:error, {:session_not_found, session_id}}`
  when no archived copy does.
  """
  @spec unarchive(String.t(), keyword()) :: :ok | {:error, term()}
  def unarchive(session_id, opts \\ []), do: relocate(session_id, opts, false)

  defp relocate(session_id, opts, archived?) do
    opts = Keyword.delete(opts, :archived)
    from = Keyword.put(opts, :archived, not archived?)
    to = Keyword.put(opts, :archived, archived?)

    with :ok <- Storage.validate_session_id(session_id),
         :ok <- ensure_inactive(session_id),
         {:ok, dir} <- Storage.move_session(session_id, from, to) do
      reindex(session_id, to, Path.join(dir, "session.dlog"))
    end
  end

  # Like `Catalog.record/1`, tolerate a catalog that is not running: it is a
  # rebuildable projection, not part of the move.
  defp catalog_entry(session_id) do
    if Process.whereis(Catalog), do: Catalog.get(session_id), else: {:error, :no_catalog}
  catch
    :exit, _reason -> {:error, :no_catalog}
  end

  defp ensure_inactive(session_id) do
    case Journal.whereis(session_id) do
      {:ok, journal} when is_pid(journal) ->
        if Process.alive?(journal), do: {:error, :session_active}, else: :ok

      {:error, :not_found} ->
        :ok
    end
  end

  # The summary is location-independent, so a cataloged session only needs its
  # new location; an unindexed one is read from its new location.
  defp reindex(session_id, location, journal_path) do
    archived = Keyword.fetch!(location, :archived)

    summary =
      case catalog_entry(session_id) do
        {:ok, entry} ->
          {:ok, entry}

        {:error, _not_indexed} ->
          with {:ok, projection} <- Reader.projection(session_id, location),
               do: {:ok, summary_map(projection)}
      end

    case summary do
      {:ok, summary} ->
        summary
        |> Map.merge(%{archived: archived, journal_path: journal_path})
        |> Catalog.record()

      {:error, _reason} ->
        # The move succeeded; a stale catalog is rebuilt from the journal.
        :ok
    end
  end

  defp usage_projection(session_id, opts) do
    case Journal.whereis(session_id) do
      {:ok, journal} -> Journal.projection(journal)
      {:error, :not_found} -> Reader.projection(session_id, opts)
    end
  end

  defp trash(session_id, opts) do
    with {:ok, _trashed} <- Storage.trash_session(session_id, opts) do
      Catalog.forget(session_id)
      :ok
    end
  end

  @doc """
  Returns the derived catalog summary for a session, read from its journal
  when the catalog does not index it or is not running.
  """
  @spec summary(String.t(), keyword()) :: {:ok, Catalog.Entry.t()} | {:error, term()}
  def summary(session_id, opts \\ []) do
    case catalog_entry(session_id) do
      {:ok, entry} -> {:ok, entry}
      {:error, _not_indexed} -> summary_from_journal(session_id, opts)
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

    case Keyword.get(opts, :seq, last_seq) do
      upto when is_integer(upto) and upto >= 1 and upto <= last_seq ->
        selected =
          commits
          |> Enum.filter(&(&1["seq"] <= upto))
          |> Enum.map(&strip_events/1)
          |> Enum.reject(&(&1["events"] == []))

        {:ok, selected, upto}

      upto ->
        {:error, {:invalid_fork_seq, upto}}
    end
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
        name
        |> write_fork_items(new_id, parent_id, parent_seq, replay, commits)
        |> close_fork(name)

      {:error, reason} ->
        {:error, {:fork_open_failed, path, reason}}
    end
  end

  # The log is closed whether or not writing it succeeded; a write error wins
  # over a close error.
  defp close_fork(result, name) do
    case {result, :disk_log.close(name)} do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, {:fork_close_failed, reason}}
      {{:error, _reason} = error, _closed} -> error
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

    with :ok <- result, do: sync_fork(name)
  end

  defp sync_fork(name) do
    case :disk_log.sync(name) do
      :ok -> :ok
      {:error, reason} -> {:error, {:fork_sync_failed, reason}}
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
