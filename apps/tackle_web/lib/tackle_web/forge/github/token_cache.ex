defmodule Tackle.Web.Forge.GitHub.TokenCache do
  @moduledoc """
  Keeps GitHub installation access tokens in memory until shortly before
  they expire. Tokens are never written to disk or the database.

  A public ETS table owned by this process: readers do not go through it,
  and losing the process loses only the cache. Two callers that miss at once
  both fetch a token, which is harmless.
  """

  use GenServer

  @table __MODULE__

  # Refresh this long before GitHub's expiry (tokens live an hour).
  @margin_seconds 300

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The cached token for `key` if it is valid for a while yet."
  @spec fetch(term(), integer()) :: {:ok, String.t()} | :error
  def fetch(key, now \\ System.os_time(:second)) do
    case :ets.lookup(@table, key) do
      [{^key, token, expires_at}] when expires_at - @margin_seconds > now -> {:ok, token}
      _missing_or_expiring -> :error
    end
  end

  @doc "Caches `token` for `key` until `expires_at` (Unix seconds)."
  @spec put(term(), String.t(), integer()) :: :ok
  def put(key, token, expires_at) do
    :ets.insert(@table, {key, token, expires_at})
    :ok
  end

  @doc "Forgets the token for `key`, such as one the forge rejected."
  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
