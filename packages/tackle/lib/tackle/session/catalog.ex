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
  """

  use GenServer

  alias Tackle.Session.Catalog.Entry
  alias Tackle.Session.Projection
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage

  @table __MODULE__
  @summary_schema_version 1
  @rebuild_session_timeout 2_000

  @type filters :: %{
          optional(:text) => String.t() | nil,
          optional(:cwd) => String.t() | nil,
          optional(:session_ids) => [String.t()] | nil,
          optional(:status) => atom() | String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:tags) => [String.t()],
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
    GenServer.call(__MODULE__, {:list, normalize_filters(filters)})
  end

  @doc "Searches session summaries using the default indexed fields."
  @spec search(String.t(), filters() | keyword()) ::
          {:ok, %{sessions: [Entry.t()], next_cursor: String.t() | nil}}
  def search(query, filters \\ %{}) when is_binary(query) do
    filters = filters |> normalize_filters() |> Map.put(:text, query)
    GenServer.call(__MODULE__, {:list, filters})
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
      search_text: data["search_text"] || ""
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

  def handle_call({:list, filters}, _from, state) do
    entries = state.table |> :ets.tab2list() |> Enum.map(fn {_id, entry} -> entry end)
    {:reply, {:ok, paginate(filter(entries, filters), filters)}, state}
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
    |> Task.async_stream(fn {id, location_opts} -> index_session(table, id, location_opts) end,
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

  defp index_session(table, session_id, opts) do
    case read_sidecar(session_id, opts) do
      {:ok, %{"last_indexed_seq" => last_seq} = sidecar} ->
        case Reader.last_seq(session_id, opts) do
          {:ok, ^last_seq} ->
            insert(table, decode_summary(sidecar["summary"] || %{"session_id" => session_id}))
            :ok

          _other ->
            index_from_journal(table, session_id, opts)
        end

      _other ->
        index_from_journal(table, session_id, opts)
    end
  end

  defp index_from_journal(table, session_id, opts) do
    with {:ok, projection} <- Reader.projection(session_id, opts) do
      insert(table, to_entry(summary_for(projection)))
      :ok
    end
  end

  defp read_sidecar(session_id, opts) do
    with {:ok, path} <- Storage.summary_path(session_id, opts),
         {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, binary} <- File.read(path),
         {:ok, payload} <- decode_sidecar(binary),
         true <- payload["schema_version"] == @summary_schema_version,
         true <- payload["session_id"] == session_id do
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
      search_text: fetch_value(summary, :search_text, "")
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
    matches_text?(entry, Map.get(filters, :text)) and
      matches_field?(entry.cwd, Map.get(filters, :cwd)) and
      matches_session_ids?(entry.session_id, Map.get(filters, :session_ids)) and
      matches_field?(entry.status, Map.get(filters, :status)) and
      matches_field?(entry.model, Map.get(filters, :model)) and
      Enum.all?(Map.get(filters, :tags) || [], &(&1 in entry.tags))
  end

  defp matches_field?(_value, nil), do: true
  defp matches_field?(value, expected), do: value == expected

  defp matches_session_ids?(_session_id, nil), do: true
  defp matches_session_ids?(session_id, ids), do: session_id in ids

  defp matches_text?(_entry, nil), do: true
  defp matches_text?(_entry, ""), do: true

  defp matches_text?(entry, text) do
    haystack = String.downcase(entry.search_text || "")
    needle = String.downcase(text)

    needle
    |> String.split(~r/\s+/, trim: true)
    |> Enum.all?(&String.contains?(haystack, &1))
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
      "closed" -> :closed
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
