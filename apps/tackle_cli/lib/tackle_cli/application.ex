defmodule Tackle.CLI.Application do
  @moduledoc false

  use Application

  # Lumis downloads and compiles a parser the first time a language is
  # highlighted; warm the common ones in the background so the first edit card
  # of a session does not stall on it. Failures are logged by lumis, never
  # fatal, and any other language still loads on demand.
  @highlight_languages ~w(elixir erlang heex markdown bash json yaml toml lua)

  @impl true
  def start(_type, _args) do
    # Anubis logs HTTP request headers at debug level, including bearer tokens.
    Application.put_env(:anubis_mcp, :log, false)
    warm_highlight_languages()

    with :ok <- Tackle.CLI.Distribution.load_plugins() do
      start_supervisor()
    end
  end

  defp warm_highlight_languages do
    if Application.get_env(:tackle_cli, :highlight, true) do
      languages =
        Application.get_env(:tackle_cli, :highlight_languages, @highlight_languages)

      Lumis.Languages.async_load(languages)
    end
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
