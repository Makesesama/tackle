defmodule Tackle.CLI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Anubis logs HTTP request headers at debug level, including bearer tokens.
    Application.put_env(:anubis_mcp, :log, false)

    with {:ok, contributions} <- Tackle.Plugins.Loader.load(),
         {:ok, _catalog} <- validate_contributions(contributions) do
      Application.put_env(:tackle_cli, :plugin_contributions, contributions)
      start_supervisor()
    end
  end

  defp validate_contributions(contributions) do
    Tackle.Plugins.Catalog.new(
      adapters:
        Enum.map(
          Application.get_env(:tackle, :adapters, Tackle.CLI.Distribution.default_adapters()),
          &%{module: &1, source: :cli}
        ) ++ contributions.adapters,
      tools:
        Enum.map(Tackle.Tools.default(), &%{module: &1, source: :tackle}) ++
          Enum.map(
            [Tackle.Tools.Subagent, Tackle.Tools.SubagentStatus, Tackle.Tools.SubagentWait],
            &%{module: &1, source: :tackle}
          ) ++ contributions.tools,
      hooks: contributions.hooks
    )
  end

  defp start_supervisor do
    children = [
      {Finch, name: Tackle.CLI.MCP.Finch},
      Tackle.CLI.MCP.Connections,
      Tackle.CLI.Standalone
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tackle.CLI.Supervisor
    )
  end
end
