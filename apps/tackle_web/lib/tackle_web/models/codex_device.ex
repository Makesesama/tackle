defmodule Tackle.Web.Models.CodexDevice do
  @moduledoc """
  Trusted server service for Codex device login. Call `request/2`, display only
  the returned device's user code and verification URI, then run `complete/2`
  in a task. Credentials go directly to the encrypted database, not the caller.

  Callers must enforce admin authorisation before starting either operation.
  Options are trusted server options passed to the OAuth helper; `:oauth_module`
  exists for deterministic testing, not user input.
  """

  alias Tackle.Web.CredentialStore
  alias Tackle.Web.Models.Provider

  @type flow :: %{provider_id: String.t(), device: map()}

  @spec request(String.t(), keyword()) :: {:ok, flow()} | {:error, term()}
  def request(provider_id, opts \\ []) do
    with :ok <- codex_provider(provider_id),
         {:ok, device} <- oauth(opts).request_device_code(Keyword.delete(opts, :oauth_module)) do
      {:ok, %{provider_id: provider_id, device: device}}
    end
  end

  @spec complete(flow(), keyword()) :: :ok | {:error, term()}
  def complete(%{provider_id: id, device: device}, opts \\ []) do
    with :ok <- codex_provider(id),
         {:ok, credentials} <-
           oauth(opts).complete_device_code(device, Keyword.delete(opts, :oauth_module)) do
      Tackle.Lib.CredentialStore.put(CredentialStore.handle(), id, credentials)
    end
  end

  defp oauth(opts), do: Keyword.get(opts, :oauth_module, Tackle.Plugins.Codex.OAuth)

  defp codex_provider(id) do
    case Provider.get(id) do
      {:ok, %{adapter: :codex}} -> :ok
      {:ok, nil} -> {:error, {:unknown_provider, id}}
      {:ok, _provider} -> {:error, :not_a_codex_provider}
      {:error, reason} -> {:error, reason}
    end
  end
end
