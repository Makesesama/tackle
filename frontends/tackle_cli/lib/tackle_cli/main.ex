defmodule Tackle.CLI.Main do
  @moduledoc false

  alias Tackle.CLI.Parser
  alias Tackle.CLI.Run

  @spec main([String.t()]) :: non_neg_integer()
  def main(argv \\ []) do
    case Parser.parse(argv) do
      {:ok, command} -> dispatch(command)
      {:help, help} -> puts(help, :stdio, 0)
      {:version, version} -> puts(version, :stdio, 0)
      {:error, error} -> puts(error, :stderr, 1)
    end
  end

  defp dispatch({:run, opts}), do: Run.run(opts)
  defp dispatch({:models, %{}}), do: Run.models()

  defp puts(message, device, status) do
    IO.puts(device, message)
    status
  end
end
