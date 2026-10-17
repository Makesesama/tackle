defmodule Tackle.Web.Models.CodexDevice do
  @moduledoc """
  Trusted server service for Codex device login. Call `request/3`, display only
  the returned device's user code and verification URI, then run `complete/2`
  in a task. Credentials go directly to the encrypted database, not the caller.

  Providers are named by their owner's user id and the provider's name, as in
  the credential store (`Tackle.Web.CredentialStore.handle/1`). Callers must
  pass the signed-in user's own id: this service does not authorise.
  Options are trusted server options passed to the OAuth helper;
  `:oauth_module` exists for deterministic testing, not user input.
  """

  alias Tackle.Web.CredentialStore
  alias Tackle.Web.Models.Provider

  @type flow :: %{owner_id: Ecto.UUID.t(), provider: String.t(), device: map()}

  @spec request(Ecto.UUID.t(), String.t(), keyword()) :: {:ok, flow()} | {:error, term()}
  def request(owner_id, name, opts \\ []) do
    with :ok <- codex_provider(owner_id, name),
         {:ok, device} <- oauth(opts).request_device_code(Keyword.delete(opts, :oauth_module)) do
      {:ok, %{owner_id: owner_id, provider: name, device: device}}
    end
  end

  @spec complete(flow(), keyword()) :: :ok | {:error, term()}
  def complete(%{owner_id: owner_id, provider: name, device: device}, opts \\ []) do
    with :ok <- codex_provider(owner_id, name),
         {:ok, credentials} <-
           oauth(opts).complete_device_code(device, Keyword.delete(opts, :oauth_module)) do
      Tackle.Lib.CredentialStore.put(CredentialStore.handle(owner_id), name, credentials)
    end
  end

  defp oauth(opts), do: Keyword.get(opts, :oauth_module, Tackle.Plugins.Codex.OAuth)

  defp codex_provider(owner_id, name) do
    case Provider.get_named(owner_id, name) do
      {:ok, %{adapter: :codex}} -> :ok
      {:ok, nil} -> {:error, {:unknown_provider, name}}
      {:ok, _provider} -> {:error, :not_a_codex_provider}
      {:error, reason} -> {:error, reason}
    end
  end
end
