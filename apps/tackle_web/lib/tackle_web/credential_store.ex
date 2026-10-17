defmodule Tackle.Web.CredentialStore do
  @moduledoc """
  Database credential store for adapters, per provider owner
  (docs/TACKLE_WEB_PLAN.md §7.2, §7.12). A handle names one user's
  providers, and ids are provider names, as in model references. Always use
  `handle/1`, including across concurrent runs: Codex's refresh lock is keyed
  on this stable handle. Fetch reads the database every time, and writes use
  a transaction, without a cache. Missing providers are never created by
  credential writes; deleting credentials of a missing provider is
  idempotent. Disabled providers retain their credentials.
  """
  @behaviour Tackle.Lib.CredentialStore

  alias Tackle.Web.Models.Provider

  @doc "The stable handle for the providers of the user `owner_id`."
  @spec handle(Ecto.UUID.t()) :: Tackle.Lib.CredentialStore.handle()
  def handle(owner_id) when is_binary(owner_id), do: {__MODULE__, owner_id}

  @impl true
  def fetch(owner_id, name) do
    with {:ok, provider} <- Provider.get_named(owner_id, name) do
      read_credentials(provider)
    end
  end

  defp read_credentials(nil), do: :error

  defp read_credentials(provider) do
    with {:ok, loaded} <- Ash.load(provider, :credentials) do
      if is_nil(loaded.credentials), do: :error, else: {:ok, loaded.credentials}
    end
  end

  @impl true
  def put(owner_id, name, credentials) when is_map(credentials),
    do: write(owner_id, name, credentials, false)

  @impl true
  def delete(owner_id, name), do: write(owner_id, name, nil, true)

  # Ash sends the provider's notification (Tackle.Web.Updates) once the
  # transaction commits. A failure comes before any write, so it commits
  # nothing.
  defp write(owner_id, name, credentials, deleting?) do
    case Ash.transact(Provider, fn ->
           write_in_transaction(owner_id, name, credentials, deleting?)
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:failed, error}} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  defp write_in_transaction(owner_id, name, credentials, deleting?) do
    with {:ok, provider} <- Provider.get_named(owner_id, name),
         :ok <- update_credentials(provider, name, credentials, deleting?) do
      :ok
    else
      {:error, error} -> {:failed, error}
    end
  end

  defp update_credentials(nil, _name, _credentials, true), do: :ok
  defp update_credentials(nil, name, _credentials, false), do: {:error, {:unknown_provider, name}}

  defp update_credentials(provider, _name, credentials, _deleting?) do
    case Provider.store_credentials(provider, credentials) do
      {:ok, _provider} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
