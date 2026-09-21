defmodule Tackle.CLI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Tackle.CLI.Standalone]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tackle.CLI.Supervisor
    )
  end
end
