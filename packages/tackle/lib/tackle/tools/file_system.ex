defmodule Tackle.Tools.FileSystem do
  @moduledoc false

  @spec resolve_path(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(path, context) when is_binary(path) and is_map(context) do
    with {:ok, cwd} <- cwd(context) do
      {:ok, Path.expand(path, cwd)}
    end
  end

  @spec mutate(String.t(), (-> result)) :: result when result: var
  def mutate(path, operation) when is_binary(path) and is_function(operation, 0) do
    :global.trans({{__MODULE__, path}, self()}, operation)
  end

  @spec format_error(String.t(), Tackle.Executor.reason()) :: String.t()
  def format_error(path, reason), do: "#{path}: #{Tackle.Executor.format_reason(reason)}"

  defp cwd(%{cwd: cwd}), do: normalize_cwd(cwd)
  defp cwd(%{"cwd" => cwd}), do: normalize_cwd(cwd)
  defp cwd(_context), do: File.cwd()

  defp normalize_cwd(cwd) when is_binary(cwd), do: {:ok, Path.expand(cwd)}
  defp normalize_cwd(cwd), do: {:error, "Invalid working directory: #{inspect(cwd)}"}
end
