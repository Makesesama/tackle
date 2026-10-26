defmodule Tackle.Lib.CredentialStore do
  @moduledoc """
  Provider-neutral access to host-owned credential storage.

  A credential-store handle contains an implementation module and an opaque
  reference owned by the host. Provider adapters use this module rather than
  invoking the implementation directly. Credential maps are opaque to
  Tackle.Lib and must contain only JSON-compatible values.
  """

  @type handle :: {module(), term()}
  @type namespace :: String.t()
  @type credentials :: map()

  @callback fetch(reference :: term(), namespace()) ::
              {:ok, credentials()} | :error | {:error, term()}
  @callback put(reference :: term(), namespace(), credentials()) ::
              :ok | {:error, term()}
  @callback delete(reference :: term(), namespace()) ::
              :ok | {:error, term()}

  @doc """
  Reads the credential-store handle an adapter was called with.

  Returns `:error` when the options carry none (or `nil`), and
  `{:error, :invalid_credential_store}` when `:credential_store` is not a
  `{module, reference}` handle.
  """
  @spec from_opts(keyword()) :: {:ok, handle()} | :error | {:error, :invalid_credential_store}
  def from_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :credential_store) do
      nil -> :error
      {module, _reference} = handle when is_atom(module) and not is_nil(module) -> {:ok, handle}
      _invalid -> {:error, :invalid_credential_store}
    end
  end

  @doc """
  Fetches the opaque credentials stored for one provider namespace.

  Returns `{:ok, credentials}`, `:error` when the namespace holds nothing,
  or `{:error, {:credential_store_failed, reason}}` when the implementation
  fails. An implementation that returns anything else, such as credentials
  that are not a map, fails with reason `:invalid_result`; the value is not
  echoed, since it may hold a secret.
  """
  @spec fetch(handle(), namespace()) ::
          {:ok, credentials()} | :error | {:error, {:credential_store_failed, term()}}
  def fetch({module, reference}, namespace) when is_atom(module) and is_binary(namespace) do
    case module.fetch(reference, namespace) do
      {:ok, %{} = credentials} when not is_struct(credentials) -> {:ok, credentials}
      :error -> :error
      {:error, reason} -> {:error, {:credential_store_failed, reason}}
      _other -> {:error, {:credential_store_failed, :invalid_result}}
    end
  end

  @doc "Stores opaque credentials in one provider namespace."
  @spec put(handle(), namespace(), credentials()) :: :ok | {:error, term()}
  def put({module, reference}, namespace, credentials)
      when is_atom(module) and is_binary(namespace) and is_map(credentials) do
    module.put(reference, namespace, credentials)
  end

  @doc "Deletes the credentials in one provider namespace."
  @spec delete(handle(), namespace()) :: :ok | {:error, term()}
  def delete({module, reference}, namespace) when is_atom(module) and is_binary(namespace) do
    module.delete(reference, namespace)
  end
end
