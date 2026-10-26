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
          optional(:status) => atom() | String.t() | nil,
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
  Records a summary produced by a durable journal commit.

  Safe to call before the catalog is started and from any process; a missing
  catalog is a stale projection, not a durable failure.
  """
  @spec record(map()) :: :ok
  def record(summary) when is_map(summary) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:record, summary})
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

  @doc "Returns one indexed session summary."
  @spec get(String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get(session_id), do: GenServer.call(__MODULE__, {:get, session_id})

  @doc "Lists sessions with stable cursor pagination."
  @spec list(filters() | keyword()) ::
          {:ok, %{sessions: [Entry.t()], next_cursor: String.t() | nil}}
  def list(filters \\ %{}) do
    filters = normalize_filters(filters)

    # Metadata filters run in the catalog, ordered after earlier `record/1`
    # casts. Text matching may build search text, so it runs in the caller.
    with {:ok, entries} <- GenServer.call(__MODULE__, {:candidates, filters}) do
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

  Valid, current sidecars are used directly; missing, stale, corrupt, or
  incompatible summaries are rebuilt by folding the journal. Sessions whose
  journal cannot be read within the per-session rebuild timeout are omitted and
  reported as skipped rather than blocking the entire catalog.
  """
  @spec rebuild(keyword()) :: %{indexed: non_neg_integer(), skipped: non_neg_integer()}
  def rebuild(opts \\ []) do
    GenServer.call(__MODULE__, {:rebuild, opts}, :infinity)
  end

  @doc "Encodes one summary map into durable sidecar plain data."
  @spec encode_summary(map()) :: map()
  def encode_summary(summary) do
    summary
    |> Enum.map(fn {key, value} -> {to_string(key), encode_value(value)} end)
    |> Map.new()
  end

  @doc "Decodes a sidecar summary back into the internal entry shape."
  @spec decode_summary(map()) :: Entry.t()
  def decode_summary(data) when is_map(data) do
    %Entry{
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
      archived: data["archived"] == true,
      context_tokens: data["context_tokens"],
      search_text: data["search_text"]
    }
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

    {:ok, %{table: table, opts: opts}, {:continue, :rebuild}}
  end

  # The state holds only the table and options, but the last message can
  # carry a summary's preview or a session's whole search text, which crash
  # reports and `:sys.get_status/1` must not show.
  @impl true
  def format_status(status),
    do: StatusRedaction.format_status(status, &%{&1 | opts: StatusRedaction.keys(&1.opts)})

  @impl true
  def handle_continue(:rebuild, state) do
    _ = rebuild_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record, summary}, state) do
    insert(state.table, to_entry(summary))
    {:noreply, state}
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
    {:noreply, state}
  end

  @impl true
  def handle_call({:get, session_id}, _from, state) do
    case :ets.lookup(state.table, session_id) do
      [{^session_id, entry}] -> {:reply, {:ok, Entry.public(entry)}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:candidates, filters}, _from, state) do
    entries = state.table |> :ets.tab2list() |> Enum.map(fn {_id, entry} -> entry end)
    {:reply, {:ok, filter(entries, filters)}, state}
  end

  def handle_call({:rebuild, opts}, _from, state) do
    {:reply, rebuild_state(Map.put(state, :opts, opts)), state}
  end

  defp rebuild_state(state) do
    opts = Map.get(state, :opts, [])
    :ets.delete_all_objects(state.table)

    case Storage.list_session_locations(opts) do
      {:ok, locations} -> index_sessions(state.table, locations, opts)
      {:error, _reason} -> %{indexed: 0, skipped: 0}
    end
  end

  defp index_sessions(table, locations, opts) do
    timeout = Keyword.get(opts, :rebuild_session_timeout, @rebuild_session_timeout)

    locations
    |> Task.async_stream(fn {id, location_opts} -> safely_index(table, id, location_opts) end,
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{indexed: 0, skipped: 0}, fn
      {:ok, :ok}, acc -> %{acc | indexed: acc.indexed + 1}
      _skipped, acc -> %{acc | skipped: acc.skipped + 1}
    end)
  end

  # The tasks are linked to the catalog, so a session that raises (a malformed
  # journal the reader did not anticipate) is skipped instead of taking the
  # catalog down.
  defp safely_index(table, session_id, opts) do
    index_session(table, session_id, opts)
  rescue
    error -> {:error, {:exception, error.__struct__}}
  end

  # A compressed journal never changes and compression brought its sidecar up
  # to date, so the sidecar is used without decompressing the journal.
  defp index_session(table, session_id, opts) do
    case read_sidecar(session_id, opts) do
      {:ok, %{"last_indexed_seq" => last_seq} = sidecar} ->
        if compressed?(session_id, opts) or Reader.last_seq(session_id, opts) == {:ok, last_seq} do
          entry = decode_summary(sidecar["summary"] || %{"session_id" => session_id})
          insert(table, located(entry, session_id, opts))
          :ok
        else
          index_from_journal(table, session_id, opts)
        end

      _other ->
        index_from_journal(table, session_id, opts)
    end
  end

  defp compressed?(session_id, opts) do
    case Storage.journal_path(session_id, opts) do
      {:ok, path} -> not File.exists?(path) and File.regular?(Storage.compressed_path(path))
      {:error, _reason} -> false
    end
  end

  defp index_from_journal(table, session_id, opts) do
    with {:ok, projection} <- Reader.projection(session_id, opts) do
      entry = to_entry(summary_for(projection))
      insert(table, located(entry, session_id, opts))
      :ok
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
         true <- payload["session_id"] == session_id do
      {:ok, payload}
    else
      _other -> :error
    end
  end

  @doc false
  # Encodes the summary sidecar for a replayed projection, in the format the
  # journal writes when its owner stops.
  @spec sidecar(Projection.t()) :: binary()
  def sidecar(%Projection{} = projection) do
    payload = %{
      "schema_version" => @summary_schema_version,
      "session_id" => projection.session_id,
      "last_indexed_seq" => projection.last_seq,
      "summary" => projection |> summary_for() |> encode_summary()
    }

    :erlang.term_to_binary(payload, [:compressed])
  end

  defp decode_sidecar(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp summary_for(%Projection{} = projection) do
    projection
    |> Projection.metadata()
    |> Map.put(:search_text, Projection.search_text(projection))
  end

  defp insert(table, %{} = entry) do
    :ets.insert(table, {entry.session_id, entry})
    :ok
  end

  defp to_entry(summary) do
    %Entry{
      session_id: fetch_value(summary, :session_id),
      title: fetch_value(summary, :title),
      cwd: fetch_value(summary, :cwd),
      created_at: fetch_value(summary, :created_at),
      updated_at: fetch_value(summary, :updated_at),
      status: summary |> fetch_value(:status) |> decode_status(),
      model: fetch_value(summary, :model),
      tags: fetch_value(summary, :tags, []),
      message_count: fetch_value(summary, :message_count, 0),
      preview: fetch_value(summary, :preview),
      last_indexed_seq: fetch_value(summary, :last_indexed_seq, 0),
      parent_session_id: fetch_value(summary, :parent_session_id),
      archived: fetch_value(summary, :archived, false) == true,
      context_tokens: fetch_value(summary, :context_tokens),
      search_text: fetch_value(summary, :search_text),
      journal_path: fetch_value(summary, :journal_path)
    }
  end

  defp fetch_value(summary, key, default \\ nil) do
    case Map.get(summary, key) do
      nil -> Map.get(summary, to_string(key), default)
      value -> value
    end
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

  defp normalize_filters(filters) when is_map(filters), do: filters

  defp decode_status(nil), do: nil
  defp decode_status(status) when is_atom(status), do: status

  defp decode_status(status) when is_binary(status) do
    case status do
      "clean" -> :clean
      # Written by earlier versions for a session that is clean now.
      "closed" -> :clean
      "interrupted" -> :interrupted
      "recovered" -> :recovered
      "corrupt" -> :corrupt
      "unsupported" -> :unsupported
      "active" -> :active
      _other -> :clean
    end
  end

  defp encode_value(nil), do: nil
  defp encode_value(value) when is_boolean(value), do: value
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(value) when is_map(value), do: encode_summary(value)
  defp encode_value(value), do: value
end
