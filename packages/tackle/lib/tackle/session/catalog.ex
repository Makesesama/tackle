defmodule Tackle.Session.Catalog do
  @moduledoc """
  Derived, rebuildable index of durable sessions for listing and search.

  The catalog is a projection over journals, never a second source of truth. It
  receives updates only after journal commits have succeeded, and every indexed
  record carries `last_indexed_seq` so startup and repair can detect a stale
  projection. A failed catalog update never rolls back a durable commit; it
  leaves the projection stale and rebuildable from the journal.

  Default full-text search indexes the explicit or derived title, user and
  assistant message text, `cwd`, and explicit tags. It excludes reasoning,
  provider continuation state, tool arguments, and tool output to bound index
  size and accidental secret exposure.

  Search text is built lazily. Live journals record summaries without it,
  because building it costs time proportional to the whole session. A text
  search builds the missing text for each candidate, from the live journal's
  projection or by replaying the session's file, in the searching process, and
  caches it on the entry until the session's next indexed commit. Startup
  indexing takes it from summary sidecars or the replay it already does.

  At startup the catalog rebuilds its index (`rebuild/1`) in a task: a
  session's summary sidecar is used as it is while its journal file is
  unchanged, and other sessions are replayed. Journal updates are recorded
  meanwhile, and reads wait until the index is complete.

  Archived sessions are indexed too, marked `archived: true`. Listing excludes
  them unless the `:archived` filter is `true` (archived only) or `:all`.
  """

  use GenServer

  alias Tackle.Session.Catalog.Entry
  alias Tackle.Session.Journal
  alias Tackle.Session.Projection
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage
  alias Tackle.StatusRedaction

  @table __MODULE__
  @summary_schema_version 1
  @rebuild_session_timeout 2_000
  @search_text_timeout 5_000

  @type filters :: %{
          optional(:text) => String.t() | nil,
          optional(:cwd) => String.t() | nil,
          optional(:session_ids) => [String.t()] | nil,
          optional(:status) => Entry.status() | String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:tags) => [String.t()],
          optional(:archived) => boolean() | :all,
          optional(:limit) => pos_integer() | nil,
          optional(:cursor) => String.t() | nil
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records the entry of a session, such as one a durable journal commit
  produced (`Tackle.Session.Catalog.Entry.from_projection/2`).

  Safe to call before the catalog is started and from any process; a missing
  catalog is a stale projection, not a durable failure.
  """
  @spec record(Entry.t()) :: :ok
  def record(%Entry{} = entry) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:record, entry})
    end

    :ok
  end

  @doc "Removes a session from the derived index."
  @spec forget(String.t()) :: :ok
  def forget(session_id) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:forget, session_id})
    end

    :ok
  end

  @doc """
  Returns one indexed session summary.

  Like `list/1`, it waits for a running rebuild (see `rebuild/1`).
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(session_id), do: GenServer.call(__MODULE__, {:get, session_id}, :infinity)

  @doc """
  Lists sessions with stable cursor pagination.

  The `:status` filter takes a `t:Tackle.Session.Catalog.Entry.status/0` or
  its name as a string (`"active"`). A listing waits for a running rebuild,
  such as the one at startup, so it never reports a partial index; the wait
  is bounded by the rebuild's per-session timeouts (see `rebuild/1`).
  """
  @spec list(filters() | keyword()) ::
          {:ok, %{sessions: [Entry.t()], next_cursor: String.t() | nil}}
  def list(filters \\ %{}) do
    filters = normalize_filters(filters)

    # Metadata filters run in the catalog, ordered after earlier `record/1`
    # casts. Text matching may build search text, so it runs in the caller.
    with {:ok, entries} <- GenServer.call(__MODULE__, {:candidates, filters}, :infinity) do
      {:ok, entries |> filter_text(Map.get(filters, :text)) |> paginate(filters)}
    end
  end

  @doc "Searches session summaries using the default indexed fields."
  @spec search(String.t(), filters() | keyword()) ::
          {:ok, %{sessions: [Entry.t()], next_cursor: String.t() | nil}}
  def search(query, filters \\ %{}) when is_binary(query) do
    filters |> normalize_filters() |> Map.put(:text, query) |> list()
  end

  @doc """
  Rebuilds the derived index from journals and sidecars.

  A session's summary sidecar is used as it is when it records the journal's
  current size and modification time, or when the journal is stored
  compressed (a compressed journal never changes). Any other session is
  replayed from its journal. Each step has the per-session rebuild timeout
  (`:rebuild_session_timeout`, two seconds by default). A replay that times
  out falls back to the session's sidecar, if it has a valid one, as an entry
  marked `stale: true`; a session without one, or whose journal cannot be
  read, is skipped. Returns how many sessions were indexed, how many of those
  are stale, and how many were skipped.

  The rebuild runs in a task, so the catalog keeps recording journal updates
  meanwhile, and those win over what the rebuild read. Reads wait until it
  has finished.
  """
  @spec rebuild(keyword()) :: %{
          indexed: non_neg_integer(),
          stale: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def rebuild(opts \\ []) do
    GenServer.call(__MODULE__, {:rebuild, opts}, :infinity)
  end

  @doc false
  # Encodes the summary sidecar of a projection, with its search text.
  # `journal` is what `journal_stat/1` returned for the journal file the
  # projection describes, so a rebuild can tell whether the file changed since.
  @spec sidecar(Projection.t(), map() | nil) :: binary()
  def sidecar(%Projection{} = projection, journal) do
    payload = %{
      "schema_version" => @summary_schema_version,
      "session_id" => projection.session_id,
      "last_indexed_seq" => projection.last_seq,
      "journal" => journal,
      "summary" => projection |> Entry.from_projection(search_text: true) |> Entry.to_sidecar()
    }

    :erlang.term_to_binary(payload, [:compressed])
  end

  @doc false
  # The size and modification time of a journal file, as a sidecar records
  # them, or `nil` when it is not a readable regular file.
  @spec journal_stat(String.t()) :: map() | nil
  def journal_stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        %{"size" => size, "mtime" => mtime}

      _other ->
        nil
    end
  end

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    {:ok, %{table: table, opts: opts, rebuild: nil, deferred: []}, {:continue, :rebuild}}
  end

  # The last message, and the requests waiting for a rebuild, can carry a
  # summary's preview, a search query, or a session's whole search text,
  # which crash reports and `:sys.get_status/1` must not show.
  @impl true
  def format_status(status), do: StatusRedaction.format_status(status, &redact_state/1)

  defp redact_state(state) do
    state
    |> Map.replace_lazy(:opts, &StatusRedaction.keys/1)
    |> Map.replace_lazy(:deferred, fn deferred ->
      Enum.map(deferred, fn {request, _from} -> StatusRedaction.message(request) end)
    end)
  end

  @impl true
  def handle_continue(:rebuild, state), do: {:noreply, start_rebuild(state, state.opts, nil)}

  @impl true
  def handle_cast({:record, %Entry{} = entry}, state) do
    insert(state.table, entry)
    {:noreply, touch(state, entry.session_id, :recorded)}
  end

  # A search built this text from the session at `seq`. Keep it only while the
  # entry still describes that commit; a newer record replaces it with nil.
  def handle_cast({:cache_search_text, session_id, seq, text}, state) do
    case :ets.lookup(state.table, session_id) do
      [{^session_id, %Entry{last_indexed_seq: ^seq, search_text: nil} = entry}] ->
        insert(state.table, %{entry | search_text: text})

      _other ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:forget, session_id}, state) do
    :ets.delete(state.table, session_id)
    {:noreply, touch(state, session_id, :forgotten)}
  end

  # While a rebuild runs, every request waits for it, in arrival order.
  @impl true
  def handle_call(request, from, %{rebuild: %{}} = state),
    do: {:noreply, %{state | deferred: [{request, from} | state.deferred]}}

  def handle_call({:rebuild, opts}, from, state),
    do: {:noreply, start_rebuild(state, opts, from)}

  def handle_call(request, _from, state), do: {:reply, read(request, state.table), state}

  @impl true
  def handle_info({ref, result}, %{rebuild: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    install(state.table, result.entries, state.rebuild.touched)
    if state.rebuild.caller, do: GenServer.reply(state.rebuild.caller, result.report)
    run_deferred(%{state | rebuild: nil, deferred: []}, Enum.reverse(state.deferred))
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp read({:get, session_id}, table) do
    case :ets.lookup(table, session_id) do
      [{^session_id, entry}] -> {:ok, Entry.public(entry)}
      [] -> {:error, :not_found}
    end
  end

  defp read({:candidates, filters}, table) do
    entries = table |> :ets.tab2list() |> Enum.map(fn {_id, entry} -> entry end)
    {:ok, filter(entries, filters)}
  end

  # The task is linked to the catalog; the work for each session never raises
  # (`bounded/3`), so only a bug in the rebuild itself can take the catalog
  # down with it.
  defp start_rebuild(state, opts, caller) do
    task = Task.async(fn -> build_index(opts) end)
    %{state | rebuild: %{task: task, caller: caller, touched: %{}}}
  end

  # Remembers which sessions journal updates or `forget/1` changed while a
  # rebuild runs, so its older reading does not overwrite them.
  defp touch(%{rebuild: nil} = state, _session_id, _change), do: state

  defp touch(%{rebuild: rebuild} = state, session_id, change),
    do: %{state | rebuild: %{rebuild | touched: Map.put(rebuild.touched, session_id, change)}}

  # Replaces the index with the rebuilt entries. A session recorded during the
  # rebuild keeps its recorded entry, which describes a newer commit than the
  # file the rebuild read, and one forgotten meanwhile stays forgotten.
  defp install(table, entries, touched) do
    recorded =
      for {session_id, :recorded} <- touched,
          [{^session_id, entry}] <- [:ets.lookup(table, session_id)],
          do: entry

    :ets.delete_all_objects(table)

    entries
    |> Enum.reject(&Map.has_key?(touched, &1.session_id))
    |> Enum.concat(recorded)
    |> Enum.each(&insert(table, &1))
  end

  # A rebuild requested meanwhile starts once the previous one has finished,
  # and the requests after it wait again.
  defp run_deferred(state, []), do: {:noreply, state}

  defp run_deferred(state, [{{:rebuild, opts}, from} | rest]),
    do: {:noreply, %{start_rebuild(state, opts, from) | deferred: Enum.reverse(rest)}}

  defp run_deferred(state, [{request, from} | rest]) do
    GenServer.reply(from, read(request, state.table))
    run_deferred(state, rest)
  end

  defp build_index(opts) do
    case Storage.list_session_locations(opts) do
      {:ok, locations} ->
        index_sessions(locations, opts)

      {:error, _reason} ->
        %{entries: [], report: %{indexed: 0, stale: 0, skipped: 0}}
    end
  end

  # First every session's sidecar is read and checked against its journal;
  # then the sessions without a current one are replayed.
  defp index_sessions(locations, opts) do
    timeout = Keyword.get(opts, :rebuild_session_timeout, @rebuild_session_timeout)
    checked = bounded(locations, timeout, fn {id, location} -> from_sidecar(id, location) end)

    {current, pending, skipped} =
      Enum.zip_reduce(locations, checked, {[], [], 0}, fn
        _location, {:ok, {:current, entry}}, {current, pending, skipped} ->
          {[entry | current], pending, skipped}

        location, {:ok, {:replay, fallback}}, {current, pending, skipped} ->
          {current, [{location, fallback} | pending], skipped}

        _location, _failed, {current, pending, skipped} ->
          {current, pending, skipped + 1}
      end)

    replayed =
      bounded(pending, timeout, fn {{id, location}, _fallback} -> from_journal(id, location) end)

    initial = %{entries: current, report: %{indexed: length(current), stale: 0, skipped: skipped}}

    Enum.zip_reduce(pending, replayed, initial, fn
      _pending, {:ok, {:ok, entry}}, acc ->
        add_entry(acc, entry, :indexed)

      {_location, %Entry{} = fallback}, {:exit, :timeout}, acc ->
        add_entry(acc, %{fallback | stale: true}, :stale)

      _pending, _failed, acc ->
        update_in(acc.report.skipped, &(&1 + 1))
    end)
  end

  defp add_entry(acc, entry, :indexed) do
    %{
      acc
      | entries: [entry | acc.entries],
        report: %{acc.report | indexed: acc.report.indexed + 1}
    }
  end

  defp add_entry(acc, entry, :stale) do
    acc = add_entry(acc, entry, :indexed)
    %{acc | report: %{acc.report | stale: acc.report.stale + 1}}
  end

  # Runs `fun` for each item in its own task with a deadline. The tasks are
  # linked to the caller, so a session whose work raises (a malformed file the
  # reader did not anticipate) only fails that session.
  defp bounded(items, timeout, fun) do
    items
    |> Task.async_stream(fn item -> safely(fn -> fun.(item) end) end,
      max_concurrency: System.schedulers_online(),
      ordered: true,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, error.__struct__}}
  end

  # A sidecar is current when the journal is stored compressed (it never
  # changes, and compression wrote the sidecar from a full replay) or still
  # has the size and modification time the sidecar recorded. A sidecar
  # written before it recorded them is never current, so its session is
  # replayed; it is still the fallback when replaying takes too long.
  defp from_sidecar(session_id, opts) do
    case read_sidecar(session_id, opts) do
      {:ok, sidecar} ->
        entry = sidecar["summary"] |> Entry.from_sidecar() |> located(session_id, opts)
        if current?(sidecar, session_id, opts), do: {:current, entry}, else: {:replay, entry}

      :error ->
        {:replay, nil}
    end
  end

  defp current?(sidecar, session_id, opts) do
    case Storage.journal_path(session_id, opts) do
      {:ok, path} ->
        compressed?(path) or
          (is_map(sidecar["journal"]) and sidecar["journal"] == journal_stat(path))

      {:error, _reason} ->
        false
    end
  end

  defp compressed?(path),
    do: not File.exists?(path) and File.regular?(Storage.compressed_path(path))

  defp from_journal(session_id, opts) do
    with {:ok, projection} <- Reader.projection(session_id, opts) do
      {:ok, projection |> Entry.from_projection(search_text: true) |> located(session_id, opts)}
    end
  end

  # The location, not the summary, decides whether a session is archived.
  defp located(entry, session_id, opts) do
    %{
      entry
      | journal_path: journal_path(session_id, opts),
        archived: Keyword.get(opts, :archived, false) == true
    }
  end

  defp journal_path(session_id, opts) do
    case Storage.journal_path(session_id, opts) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp read_sidecar(session_id, opts) do
    case Storage.summary_path(session_id, opts) do
      {:ok, path} -> read_sidecar_file(path, session_id)
      {:error, _reason} -> :error
    end
  end

  @doc false
  # Reads and validates one summary sidecar file.
  @spec read_sidecar_file(String.t(), String.t()) :: {:ok, map()} | :error
  def read_sidecar_file(path, session_id) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, binary} <- File.read(path),
         {:ok, payload} <- decode_sidecar(binary),
         true <- payload["schema_version"] == @summary_schema_version,
         true <- payload["session_id"] == session_id,
         true <- is_map(payload["summary"]) do
      {:ok, payload}
    else
      _other -> :error
    end
  end

  defp decode_sidecar(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp insert(table, %{} = entry) do
    :ets.insert(table, {entry.session_id, entry})
    :ok
  end

  defp filter(entries, filters) do
    Enum.filter(entries, &matches_filters?(&1, filters))
  end

  defp matches_filters?(entry, filters) do
    matches_archived?(entry.archived, Map.get(filters, :archived, false)) and
      matches_field?(entry.cwd, Map.get(filters, :cwd)) and
      matches_session_ids?(entry.session_id, Map.get(filters, :session_ids)) and
      matches_field?(entry.status, Map.get(filters, :status)) and
      matches_field?(entry.model, Map.get(filters, :model)) and
      Enum.all?(Map.get(filters, :tags) || [], &(&1 in entry.tags))
  end

  defp matches_archived?(_archived, :all), do: true
  defp matches_archived?(archived, expected) when is_boolean(expected), do: archived == expected
  defp matches_archived?(archived, nil), do: archived == false
  defp matches_archived?(archived, expected), do: archived == expected

  defp matches_field?(_value, nil), do: true
  defp matches_field?(value, expected), do: value == expected

  defp matches_session_ids?(_session_id, nil), do: true
  defp matches_session_ids?(session_id, ids), do: session_id in ids

  defp filter_text(entries, nil), do: entries
  defp filter_text(entries, ""), do: entries

  defp filter_text(entries, text) do
    case text |> String.downcase() |> String.split(~r/\s+/, trim: true) do
      [] -> entries
      needles -> match_text(entries, needles)
    end
  end

  # A session whose text cannot be built in time (a stalled live journal, a
  # very large file) is matched on its title, cwd, and tags only.
  defp match_text(entries, needles) do
    entries
    |> Task.async_stream(&search_text/1,
      max_concurrency: System.schedulers_online(),
      timeout: @search_text_timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(entries)
    |> Enum.flat_map(fn
      {{:ok, haystack}, entry} ->
        haystack = String.downcase(haystack)
        if Enum.all?(needles, &String.contains?(haystack, &1)), do: [entry], else: []

      {_timed_out, entry} ->
        if matches_metadata?(entry, needles), do: [entry], else: []
    end)
  end

  defp matches_metadata?(entry, needles) do
    haystack = entry |> metadata_text() |> String.downcase()
    Enum.all?(needles, &String.contains?(haystack, &1))
  end

  defp search_text(%Entry{search_text: text}) when is_binary(text), do: text

  # Runs in a task linked to the searching process: a session whose text
  # cannot be built, even one that raises, is matched on its metadata.
  defp search_text(%Entry{} = entry) do
    case session_projection(entry) do
      {:ok, projection} ->
        text = Projection.search_text(projection)

        GenServer.cast(
          __MODULE__,
          {:cache_search_text, entry.session_id, projection.last_seq, text}
        )

        text

      _unavailable ->
        metadata_text(entry)
    end
  rescue
    _error -> metadata_text(entry)
  end

  # A live session is read from its journal owner, which also holds unsynced
  # commits; any other from its file.
  defp session_projection(%Entry{session_id: session_id, journal_path: path}) do
    case Journal.whereis(session_id) do
      {:ok, journal} -> Journal.projection(journal)
      {:error, :not_found} when is_binary(path) -> Reader.projection(session_id, path: path)
      {:error, :not_found} -> {:error, :no_journal_path}
    end
  catch
    :exit, reason -> {:error, {:journal_unavailable, reason}}
  end

  defp metadata_text(%Entry{} = entry) do
    [entry.title, entry.cwd, Enum.join(entry.tags, " ")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp paginate(entries, filters) do
    limit = Map.get(filters, :limit) || 50
    cursor = Map.get(filters, :cursor)

    remaining =
      entries
      |> Enum.sort(&compare_entries/2)
      |> drop_through_cursor(cursor)

    {page, rest} = Enum.split(remaining, limit)

    next_cursor =
      case {page, rest} do
        {[], _rest} -> nil
        {_page, []} -> nil
        {page, _rest} -> page |> List.last() |> cursor()
      end

    %{sessions: Enum.map(page, &Entry.public/1), next_cursor: next_cursor}
  end

  defp drop_through_cursor(entries, nil), do: entries

  defp drop_through_cursor(entries, cursor) do
    case decode_cursor(cursor) do
      {:ok, cursor_key} -> Enum.drop_while(entries, &past_cursor?(&1, cursor_key))
      :error -> entries
    end
  end

  # Mirrors `compare_entries/2`: an entry that sorts before the cursor was
  # already returned on an earlier page.
  defp past_cursor?(entry, {updated_at, session_id}) do
    cond do
      entry.updated_at > updated_at -> true
      entry.updated_at < updated_at -> false
      true -> entry.session_id <= session_id
    end
  end

  defp compare_entries(a, b) do
    cond do
      a.updated_at > b.updated_at -> true
      a.updated_at < b.updated_at -> false
      true -> a.session_id <= b.session_id
    end
  end

  defp cursor(entry) do
    Base.url_encode64("#{entry.updated_at}|#{entry.session_id}", padding: false)
  end

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [updated_at, session_id] <- String.split(decoded, "|", parts: 2) do
      {:ok, {updated_at, session_id}}
    else
      _other -> :error
    end
  end

  defp decode_cursor(_cursor), do: :error

  defp normalize_filters(filters) when is_list(filters),
    do: filters |> Map.new() |> normalize_filters()

  # A status may be named by a string, as a JSON host sends it; one that names
  # no status matches nothing.
  defp normalize_filters(%{status: status} = filters) when is_binary(status) do
    case Entry.status_named(status) do
      {:ok, status} -> %{filters | status: status}
      :error -> filters
    end
  end

  defp normalize_filters(filters) when is_map(filters), do: filters
end
