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

  @doc "Fetches the opaque credentials stored for one provider namespace."
  @spec fetch(handle(), namespace()) :: {:ok, credentials()} | :error | {:error, term()}
  def fetch({module, reference}, namespace) when is_atom(module) and is_binary(namespace) do
    module.fetch(reference, namespace)
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
