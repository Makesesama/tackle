defmodule Tackle.Tools.Write do
  @moduledoc "Creates or replaces files for the agent."

  use Tackle.Lib.Tool

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
    with {:ok, absolute_path} <- FileSystem.resolve_path(path, context) do
      FileSystem.mutate(absolute_path, fn -> write_file(absolute_path, path, content) end)
    end
  end

  defp write_file(absolute_path, display_path, content) do
    with :ok <- make_parent(absolute_path, display_path),
         :ok <- write_content(absolute_path, display_path, content) do
      {:ok, "Successfully wrote to #{display_path}"}
    end
  end

  defp make_parent(absolute_path, display_path) do
    case absolute_path |> Path.dirname() |> File.mkdir_p() do
      :ok ->
        :ok

      {:error, reason, _path} ->
        {:error,
         "Could not create parent directory for #{display_path}: #{format_reason(reason)}"}
    end
  end

  defp write_content(absolute_path, display_path, content) do
    case File.write(absolute_path, content) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Could not write #{FileSystem.format_error(display_path, reason)}"}
    end
  end

  defp format_reason(reason), do: reason |> :file.format_error() |> List.to_string()
end
