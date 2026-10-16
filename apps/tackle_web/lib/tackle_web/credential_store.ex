defmodule Tackle.Web.CredentialStore do
  @moduledoc """
  Database credential store for adapters. Always use `handle/0`, including across
  concurrent runs: Codex's refresh lock is keyed on this stable handle. Fetch
  reads the database every time, and writes use a transaction, without a cache.
  Missing providers are never created by credential writes; deleting credentials
  of a missing provider is idempotent. Disabled providers retain their credentials.
  """
  @behaviour Tackle.Lib.CredentialStore

  alias Tackle.Web.Models.Provider
  alias Tackle.Web.Repo

  @spec handle() :: Tackle.Lib.CredentialStore.handle()
  def handle, do: {__MODULE__, :default}

  @impl true
  def fetch(:default, id) do
    with {:ok, provider} <- Provider.get(id) do
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
  def put(:default, id, credentials) when is_map(credentials), do: write(id, credentials, false)

  @impl true
  def delete(:default, id), do: write(id, nil, true)

  defp write(id, credentials, deleting?) do
    case Repo.transaction(fn -> write_in_transaction(id, credentials, deleting?) end) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp write_in_transaction(id, credentials, deleting?) do
    with {:ok, provider} <- Provider.get(id),
         :ok <- update_credentials(provider, id, credentials, deleting?) do
      :ok
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp update_credentials(nil, _id, _credentials, true), do: :ok
  defp update_credentials(nil, id, _credentials, false), do: {:error, {:unknown_provider, id}}

  defp update_credentials(provider, _id, credentials, _deleting?) do
    case Provider.store_credentials(provider, credentials) do
      {:ok, _provider} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
