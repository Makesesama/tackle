defmodule Tackle.Auth do
  @moduledoc """
  Harness facade for namespaced provider credentials.

  Credentials are stored as plaintext JSON protected by filesystem permissions;
  they are not encrypted. This module never exposes the complete credential
  file and returns only one provider namespace at a time.

  Adapter-driven login, logout, status, and usage flows live in
  `Tackle.Auth.Provider`, which resolves a provider by adapter id and stores the
  credentials returned by the adapter through this module.
  """

  alias Tackle.Auth.Store

  @store Store

  @doc "Fetches opaque credentials for one provider namespace."
  @spec fetch(String.t()) :: {:ok, map()} | :error | {:error, term()}
  def fetch(namespace), do: Store.fetch(@store, namespace)

  @doc "Stores opaque credentials for one provider namespace."
  @spec put(String.t(), map()) :: :ok | {:error, term()}
  def put(namespace, credentials), do: Store.put(@store, namespace, credentials)

  @doc "Deletes credentials for one provider namespace."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(namespace), do: Store.delete(@store, namespace)

  @doc "Reports whether a provider namespace has stored credentials."
  @spec status(String.t()) :: :stored | :missing | {:error, term()}
  def status(namespace), do: Store.status(@store, namespace)

  @doc "Returns the non-secret credential-store handle injected into adapters."
  @spec credential_store() :: Tackle.Lib.CredentialStore.handle()
  def credential_store, do: {Store, @store}
end
