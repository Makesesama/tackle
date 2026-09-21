defmodule Tackle.CLI.Main do
  @moduledoc false

  alias Tackle.CLI.Distribution
  alias Tackle.CLI.Parser
  alias Tackle.CLI.Run

  @spec main([String.t()]) :: non_neg_integer()
  def main(argv \\ []) do
    Distribution.configure()

    case Parser.parse(argv) do
      {:ok, command} -> dispatch(command)
      {:help, help} -> puts(help, :stdio, 0)
      {:version, version} -> puts(version, :stdio, 0)
      {:error, error} -> puts(error, :stderr, 1)
    end
  end

  defp dispatch({:run, opts}), do: Run.run(opts)
  defp dispatch({:sessions, opts}), do: Run.sessions(opts)
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
