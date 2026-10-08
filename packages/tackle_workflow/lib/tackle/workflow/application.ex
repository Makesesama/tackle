defmodule Tackle.Workflow.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Tackle.Workflow.Registry}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tackle.Workflow.Supervisor
    )
  end
end
