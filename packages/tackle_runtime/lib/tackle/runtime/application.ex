defmodule Tackle.Runtime.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Tackle.Runtime.Registry, []},
      {Tackle.AgentSupervisor, name: Tackle.AgentSupervisor}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tackle.Runtime.Supervisor
    )
  end
end
