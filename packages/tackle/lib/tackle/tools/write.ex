defmodule Tackle.Tools.Write do
  @moduledoc "Creates or replaces files for the agent."

  use Tackle.Lib.Tool

  alias Tackle.Executor
  alias Tackle.Tools.FileSystem

  tool_name("write")

  description(
    "Write UTF-8 content to a file. Creates missing parent directories and overwrites an existing file. " <>
      "Paths may be relative to the current working directory or absolute."
  )

  input do
    field(:path, :string, required: true, description: "Path to the file to write")
    field(:content, :string, required: true, description: "Complete content to write")
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"path" => path, "content" => content}, context) do
    executor = Executor.from_context(context)

    with {:ok, absolute_path} <- FileSystem.resolve_path(path, context) do
      FileSystem.mutate(absolute_path, fn ->
        write_file(executor, absolute_path, path, content)
      end)
    end
  end

  defp write_file(executor, absolute_path, display_path, content) do
    case Executor.write(executor, absolute_path, content, mkdir_p: true) do
      :ok ->
        {:ok, "Successfully wrote to #{display_path}"}

      {:error, reason} ->
        {:error, "Could not write #{FileSystem.format_error(display_path, reason)}"}
    end
  end
end
