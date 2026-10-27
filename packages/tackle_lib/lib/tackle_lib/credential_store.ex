defmodule Tackle.Lib.CredentialStore do
  @moduledoc """
  Provider-neutral access to host-owned credential storage.

  A credential-store handle contains an implementation module and an opaque
  reference owned by the host. Provider adapters use this module rather than
  invoking the implementation directly. Credential maps are opaque to
  Tackle.Lib and must contain only JSON-compatible values.

  Adapters that refresh credentials with a rotating refresh token run the
  whole refresh inside `with_lock/3`, so that only one process at a time,
  across every process sharing the storage, spends a refresh token.
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
  Runs `fun` while holding an exclusive lock on `namespace` and returns its
  result; see `with_lock/3` for the semantics.

  The lock covers every process, including other operating-system processes,
  that uses the same storage. `fun` runs in the calling process, and `fetch/2`,
  `put/3`, and `delete/2` on the same store must work inside it. A failure to
  get the lock returns `{:error, {:credential_lock_failed, reason}}`.

  Optional: without it, `with_lock/3` locks within this BEAM only.
  """
  @callback with_lock(reference :: term(), namespace(), (-> result)) ::
              result | {:error, {:credential_lock_failed, term()}}
            when result: term()

  @optional_callbacks with_lock: 3

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

  @doc """
  Runs the zero-arity `fun` while holding an exclusive lock on one provider
  namespace, and returns its result.

  The lock is shared by every process, including other operating-system
  processes, that uses the same storage, and it is released when `fun`
  returns, raises, throws, or the caller dies. `fun` runs in the caller;
  `fetch/2`, `put/3`, and `delete/2` on the same store work inside it. Others
  may have changed the credentials while the caller waited (another process
  may already have refreshed them), so `fun` must fetch them again after the
  lock is held. The lock is not re-entrant: do not call `with_lock/3` for the
  same namespace inside `fun`.

  A failure to get the lock returns `{:error, {:credential_lock_failed,
  reason}}`. Stores that do not implement the optional `c:with_lock/3`
  callback get a lock within this BEAM (and the nodes connected to it) only,
  through `:global.trans/2` on `{Tackle.Lib.CredentialStore, handle,
  namespace}`, which waits as long as it takes.
  """
  @spec with_lock(handle(), namespace(), (-> result)) ::
          result | {:error, {:credential_lock_failed, term()}}
        when result: term()
  def with_lock({module, reference} = handle, namespace, fun)
      when is_atom(module) and is_binary(namespace) and is_function(fun, 0) do
    if Code.ensure_loaded?(module) and function_exported?(module, :with_lock, 3) do
      module.with_lock(reference, namespace, fun)
    else
      global_lock(handle, namespace, fun)
    end
  end

  # The result is tagged so that a function returning `:aborted` is not taken
  # for a failed lock.
  defp global_lock(handle, namespace, fun) do
    lock_id = {{__MODULE__, handle, namespace}, self()}

    case :global.trans(lock_id, fn -> {__MODULE__, :locked, fun.()} end) do
      {__MODULE__, :locked, result} -> result
      :aborted -> {:error, {:credential_lock_failed, :aborted}}
    end
  end
end
