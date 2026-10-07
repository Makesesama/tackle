defmodule Tackle.CLI.SDK do
  @moduledoc false

  # `tackle sdk` serves the Tackle SDK wire protocol (see
  # packages/tackle_sdk/PROTOCOL.md) on stdin/stdout so non-BEAM clients can
  # drive the same adapters and tools as the terminal frontend.

  alias Tackle.CLI.Distribution

  @spec run() :: non_neg_integer()
  def run do
    with {:ok, catalog} <- Distribution.catalog(),
         {:ok, executor} <- Tackle.CLI.Jail.ensure_started() do
      adapters = Tackle.Plugins.Catalog.adapter_modules(catalog)

      # Standalone tools only: the subagent tools need a scoped runtime the
      # plain SDK loop does not host, and MCP tools need live connections.
      tools =
        Tackle.Tools.default() ++
          Enum.map(contributions().tools, & &1.module)

      case Tackle.SDK.run(
             adapters: adapters,
             tools: tools,
             context: context(executor),
             llm_opts: [credential_store: Tackle.Auth.credential_store()]
           ) do
        :ok -> 0
        {:error, reason} -> error(reason)
      end
    else
      {:error, reason} -> error(reason)
      reason -> error(reason)
    end
  end

  defp contributions do
    Application.get_env(:tackle_cli, :plugin_contributions, %{tools: [], adapters: [], hooks: []})
  end

  defp context(nil), do: %{cwd: cwd()}
  defp context(executor), do: %{cwd: cwd(), executor: executor}

  defp cwd do
    case File.cwd() do
      {:ok, cwd} -> cwd
      {:error, _reason} -> "."
    end
  end

  defp error(reason) do
    message = Tackle.CLI.Jail.format_error(reason) || inspect(reason)
    Owl.IO.puts(Owl.Data.tag("error: #{message}", :red), :stderr)
    1
  end
end
