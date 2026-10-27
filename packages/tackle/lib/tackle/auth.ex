defmodule Tackle.Auth do
  @moduledoc """
  Harness facade for namespaced provider credentials.

  Credentials are stored as plaintext JSON protected by filesystem permissions;
  they are not encrypted. This module never exposes the complete credential
  file and returns only one provider namespace at a time.

  Adapter-driven login, logout, status, and usage flows live in
  `Tackle.Auth.Provider`, which resolves a provider by its id and stores the
  credentials returned by the adapter through this module.

  The same file records provider *accounts*: providers created by
  `tackle auth login ID --as NAME`. Each maps a provider id to a record naming
  the adapter type id that backs it (`"adapter"`) and, when `ID` was a
  provider id, that base provider (`"base"`), whose settings the account
  inherits. `Tackle.Plugins` merges them into the
  available providers. Accounts are not part of the
  `Tackle.Lib.CredentialStore` contract and are reachable only through this
  module.
  """

  alias Tackle.Auth.Store
  alias Tackle.Lib.LLM.Provider

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

  @doc ~S"""
  Returns the recorded accounts: provider id to `%{"adapter" => type_id}`,
  plus `"base"` when set.

  The one way to read them: a store that cannot read `auth.json`, or is not
  running, is `{:error, {:accounts_unavailable, reason}}`.
  """
  @spec accounts() ::
          {:ok, %{optional(String.t()) => Store.account()}}
          | {:error, {:accounts_unavailable, term()}}
  def accounts do
    case Store.accounts(@store) do
      {:ok, accounts} -> {:ok, accounts}
      {:error, reason} -> {:error, {:accounts_unavailable, reason}}
    end
  catch
    :exit, reason -> {:error, {:accounts_unavailable, reason}}
  end

  @doc ~S"""
  Validates one account record, as `auth.json` stores it and
  `Tackle.Plugins` merges it.

  `provider_id`, the record's `"adapter"`, and its `"base"`, when set, must
  be valid provider ids (`Tackle.Lib.LLM.Provider.valid_id?/1`); a `nil` base
  is no base. Returns the record with only those keys, or
  `{:error, {:invalid_account, provider_id}}`.
  """
  @spec validate_account(term(), term()) ::
          {:ok, Store.account()} | {:error, {:invalid_account, term()}}
  def validate_account(provider_id, %{"adapter" => adapter_id} = account) do
    base = Map.get(account, "base")

    if Provider.valid_id?(provider_id) and Provider.valid_id?(adapter_id) and
         (is_nil(base) or Provider.valid_id?(base)) do
      {:ok,
       if(base, do: %{"adapter" => adapter_id, "base" => base}, else: %{"adapter" => adapter_id})}
    else
      {:error, {:invalid_account, provider_id}}
    end
  end

  def validate_account(provider_id, _account), do: {:error, {:invalid_account, provider_id}}

  @doc """
  Records or replaces an account: provider `provider_id` backed by the adapter
  type under `"adapter"`, optionally created from the provider under `"base"`.
  """
  @spec put_account(String.t(), Store.account()) :: :ok | {:error, term()}
  def put_account(provider_id, account), do: Store.put_account(@store, provider_id, account)

  @doc "Deletes an account record; its credentials are left untouched."
  @spec delete_account(String.t()) :: :ok | {:error, term()}
  def delete_account(provider_id), do: Store.delete_account(@store, provider_id)

  @doc "Returns the non-secret credential-store handle injected into adapters."
  @spec credential_store() :: Tackle.Lib.CredentialStore.handle()
  def credential_store, do: {Store, @store}
end
