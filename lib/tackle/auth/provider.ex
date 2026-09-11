defmodule Tackle.Auth.Provider do
  @moduledoc """
  Adapter-driven provider account flows for login, logout, status, and usage.

  Frontends and the harness resolve a provider purely by its `adapter_id/0` and
  delegate to the configured `Tackle.Lib.LLM` adapter. No provider-specific
  knowledge lives here: adapters implement the optional `login/1`, `logout/1`,
  `status/1`, and `usage/1` callbacks and own their complete flow.

  Credential storage stays host-owned. `login/2` persists the map returned by
  the adapter under the provider namespace through `Tackle.Auth`; `logout/2` and
  `status/2` fall back to that store when the adapter does not implement the
  callback. `Tackle.Auth.credential_store/0` is injected into the adapter
  options so adapters that manage their own credentials can still read them.
  """

  alias Tackle.Auth
  alias Tackle.Plugins

  @typedoc "A provider contribution exposed by one configured adapter."
  @type provider :: %{
          required(:id) => String.t(),
          required(:module) => module(),
          required(:models) => [String.t()],
          required(:capabilities) => capabilities()
        }

  @type capabilities :: %{
          login: boolean(),
          logout: boolean(),
          status: boolean(),
          usage: boolean()
        }

  @doc "Lists providers contributed by the configured adapters."
  @spec list(keyword()) :: {:ok, [provider()]} | {:error, term()}
  def list(opts \\ []) when is_list(opts) do
    with {:ok, adapters} <- Plugins.available_adapters(opts) do
      {:ok, Enum.map(adapters, &provider/1)}
    end
  end

  @doc """
  Runs one provider's interactive login and stores the returned credentials.

  The adapter must implement `login/1`. Pass `:interaction` for user prompts and
  any adapter-specific options (HTTP seams, base URLs, timeouts).
  """
  @spec login(String.t(), keyword()) :: :ok | {:error, term()}
  def login(provider_id, opts \\ []) when is_list(opts) do
    with {:ok, adapter} <- resolve(provider_id, opts),
         :ok <- require_callback(adapter, :login, 1),
         {:ok, credentials} <- call(adapter, :login, [adapter_opts(opts)]) do
      store(adapter.adapter_id(), credentials)
    end
  end

  @doc """
  Logs out of one provider.

  When the adapter implements `logout/1` it fully owns cleanup; otherwise the
  host deletes the credentials stored under the provider namespace.
  """
  @spec logout(String.t(), keyword()) :: :ok | {:error, term()}
  def logout(provider_id, opts \\ []) when is_list(opts) do
    with {:ok, adapter} <- resolve(provider_id, opts) do
      if function_exported?(adapter, :logout, 1) do
        call(adapter, :logout, [adapter_opts(opts)])
      else
        Auth.delete(adapter.adapter_id())
      end
    end
  end

  @doc """
  Reports one provider's credential status.

  Adapters that implement `status/1` define the reported value; otherwise the
  host reads the credential store and returns `{:ok, :stored} | {:ok, :missing}`.
  """
  @spec status(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def status(provider_id, opts \\ []) when is_list(opts) do
    with {:ok, adapter} <- resolve(provider_id, opts) do
      if function_exported?(adapter, :status, 1) do
        call(adapter, :status, [adapter_opts(opts)])
      else
        stored_status(adapter.adapter_id())
      end
    end
  end

  @doc """
  Returns one provider's account usage report.

  Requires the adapter to implement `usage/1`; otherwise the result is
  `{:error, {:unsupported_provider_flow, provider_id, :usage}}`.
  """
  @spec usage(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def usage(provider_id, opts \\ []) when is_list(opts) do
    with {:ok, adapter} <- resolve(provider_id, opts),
         :ok <- require_callback(adapter, :usage, 1) do
      call(adapter, :usage, [adapter_opts(opts)])
    end
  end

  @doc "Resolves a provider id to its adapter module."
  @spec resolve(String.t(), keyword()) :: {:ok, module()} | {:error, term()}
  def resolve(provider_id, opts \\ []) when is_list(opts) do
    with {:ok, adapters} <- Plugins.available_adapters(opts) do
      find_adapter(provider_id, adapters)
    end
  end

  defp find_adapter(provider_id, adapters) when is_binary(provider_id) and provider_id != "" do
    case Enum.find(adapters, &(safe_adapter_id(&1) == provider_id)) do
      nil ->
        {:error, {:unsupported_auth_provider, provider_id, {:supported, adapter_ids(adapters)}}}

      adapter ->
        {:ok, adapter}
    end
  end

  defp find_adapter(provider_id, adapters) do
    {:error, {:invalid_auth_provider, provider_id, {:supported, adapter_ids(adapters)}}}
  end

  defp provider(adapter) do
    %{
      id: safe_adapter_id(adapter),
      module: adapter,
      models: adapter.models(),
      capabilities: %{
        login: function_exported?(adapter, :login, 1),
        logout: function_exported?(adapter, :logout, 1),
        status: function_exported?(adapter, :status, 1),
        usage: function_exported?(adapter, :usage, 1)
      }
    }
  end

  defp safe_adapter_id(adapter) do
    if function_exported?(adapter, :adapter_id, 0), do: adapter.adapter_id()
  rescue
    _exception -> nil
  end

  defp adapter_ids(adapters),
    do: adapters |> Enum.map(&safe_adapter_id/1) |> Enum.reject(&is_nil/1)

  defp require_callback(adapter, callback, arity) do
    if function_exported?(adapter, callback, arity) do
      :ok
    else
      {:error, {:unsupported_provider_flow, adapter.adapter_id(), callback}}
    end
  end

  defp store(namespace, credentials) when is_map(credentials) do
    Auth.put(namespace, credentials)
  end

  defp store(_namespace, other), do: {:error, {:invalid_credentials, other}}

  defp stored_status(namespace) do
    case Auth.status(namespace) do
      :stored -> {:ok, :stored}
      :missing -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adapter_opts(opts) do
    Keyword.put_new(opts, :credential_store, Auth.credential_store())
  end

  defp call(adapter, callback, args) do
    apply(adapter, callback, args)
  rescue
    exception ->
      {:error, {:adapter_callback_failed, adapter, callback, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:adapter_callback_failed, adapter, callback, {kind, reason}}}
  end
end
