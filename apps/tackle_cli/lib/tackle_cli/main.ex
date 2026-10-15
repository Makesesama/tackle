defmodule Tackle.CLI.Main do
  @moduledoc false

  alias Tackle.CLI.Distribution
  alias Tackle.CLI.Parser
  alias Tackle.CLI.MCP, as: MCPCommands
  alias Tackle.CLI.Review
  alias Tackle.CLI.Run
  alias Tackle.CLI.SDK

  @spec main([String.t()]) :: non_neg_integer()
  def main(argv \\ []) do
    result =
      if Burrito.Util.running_standalone?() do
        {:ok, []}
      else
        Application.ensure_all_started(:tackle_cli)
      end

    case result do
      {:ok, _apps} ->
        Distribution.configure()
        parse_and_dispatch(argv)

      {:error, reason} ->
        puts("tackle startup failed: #{inspect(reason)}", :stderr, 1)
    end
  end

  defp parse_and_dispatch(argv) do
    case Parser.parse(argv) do
      {:ok, command} -> dispatch(command)
      {:help, help} -> puts(help, :stdio, 0)
      {:version, version} -> puts(version, :stdio, 0)
      {:error, error} -> puts(error, :stderr, 1)
    end
  end

  defp dispatch({:mcp_list, _}), do: MCPCommands.list()
  defp dispatch({:mcp_add, opts}), do: MCPCommands.add(opts)
  defp dispatch({:mcp_remove, opts}), do: MCPCommands.remove(opts)
  defp dispatch({:mcp_approve, name}), do: MCPCommands.approve(name)
  defp dispatch({:mcp_login, name}), do: MCPCommands.login(name)
  defp dispatch({:mcp_status, name}), do: MCPCommands.status(name)
  defp dispatch({:mcp_logout, name}), do: MCPCommands.logout(name)
  defp dispatch({:run, opts}), do: Run.run(opts)
  defp dispatch({:sdk, %{}}), do: SDK.run()
  defp dispatch({:review, opts}), do: Review.run(opts)
  defp dispatch({:sessions, opts}), do: Run.sessions(opts)
  defp dispatch({:archive, session_id}), do: Run.archive(session_id)
  defp dispatch({:unarchive, session_id}), do: Run.unarchive(session_id)
  defp dispatch({:models, %{}}), do: Run.models()
  defp dispatch({:auth_login, opts}), do: Run.auth_login(opts)
  defp dispatch({:auth_status, opts}), do: Run.auth_status(opts)
  defp dispatch({:auth_usage, opts}), do: Run.auth_usage(opts)
  defp dispatch({:auth_logout, opts}), do: Run.auth_logout(opts)

  defp puts(message, device, status) do
    Owl.IO.puts(message, device)
    status
  end
end
