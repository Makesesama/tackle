defmodule Tackle.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, auth_file} <- auth_file() do
      children = [
        {Tackle.Auth.Store, path: auth_file, name: Tackle.Auth.Store},
        {Task.Supervisor, name: Tackle.TaskSupervisor},
        {DynamicSupervisor, strategy: :one_for_one, name: Tackle.SessionSupervisor}
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: Tackle.Supervisor)
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
