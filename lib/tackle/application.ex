defmodule Tackle.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    configure_runtime_backend()

    with {:ok, auth_file} <- auth_file() do
      children = [
        {Tackle.Auth.Store, path: auth_file, name: Tackle.Auth.Store},
        {Registry, keys: :unique, name: Tackle.Session.JournalRegistry},
        Tackle.Session.Catalog
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: Tackle.Supervisor)
    end
  end

  defp configure_runtime_backend do
    if is_nil(Application.get_env(:tackle_runtime, :default_backend)) do
      Application.put_env(:tackle_runtime, :default_backend, Tackle.Runtime.RootBackend)
    end
  end

  defp auth_file do
    case Application.get_env(:tackle, :auth_file) do
      nil -> Tackle.Paths.auth_file()
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _path -> {:error, :invalid_auth_file_configuration}
    end
  end
end
