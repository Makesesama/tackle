defmodule Tackle.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Tackle.TaskSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Tackle.SessionSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Tackle.Supervisor)
  end
end
