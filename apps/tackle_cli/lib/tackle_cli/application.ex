defmodule Tackle.CLI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Anubis logs HTTP request headers at debug level, including bearer tokens.
    Application.put_env(:anubis_mcp, :log, false)

    children = [
      Tackle.CLI.Standalone,
      {Finch, name: Tackle.CLI.MCP.Finch},
      Tackle.CLI.MCP.Connections
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tackle.CLI.Supervisor
    )
  end
end
