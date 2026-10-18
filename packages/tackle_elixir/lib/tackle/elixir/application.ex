defmodule Tackle.Elixir.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(Tackle.Elixir.ProjectNodes.child_specs(),
      strategy: :one_for_one,
      name: Tackle.Elixir.Supervisor
    )
  end
end
