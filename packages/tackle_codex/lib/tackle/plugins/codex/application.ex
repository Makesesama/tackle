defmodule Tackle.Plugins.Codex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Tackle.Plugins.Codex.WebSocket.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Tackle.Plugins.Codex.WebSocket.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: __MODULE__.Supervisor)
  end
end
