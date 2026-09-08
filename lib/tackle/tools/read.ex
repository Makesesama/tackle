defmodule Tackle.Tools.Read do
  @moduledoc "Reads UTF-8 text files for the agent."

  use Tackle.Lib.Tool

  alias Tackle.Tools.{FileSystem, Output}

  tool_name("read")

  description(
    "Read a UTF-8 text file. Paths may be relative to the current working directory or absolute. " <>
      "Output is limited to 2,000 lines or 50KB; use offset and limit to continue reading large files."
  )

  input do
    field(:path, :string, required: true, description: "Path to the file to read")
    field(:offset, :integer, description: "1-based line number to start reading from")
    field(:limit, :integer, description: "Maximum number of lines to read")
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"path" => path} = args, context) do
    offset = Map.get(args, "offset", 1)
    limit = Map.get(args, "limit")

    with :ok <- validate_positive(:offset, offset),
         :ok <- validate_optional_positive(:limit, limit),
         {:ok, absolute_path} <- FileSystem.resolve_path(path, context),
         {:ok, content} <- read_utf8(absolute_path, path) do
      select(content, path, offset, limit)
    end
  end

  defp read_utf8(absolute_path, display_path) do
    case File.read(absolute_path) do
      {:ok, content} ->
        if String.valid?(content),
          do: {:ok, content},
          else: {:error, "Could not read #{display_path}: file is not valid UTF-8"}

      {:error, reason} ->
        {:error, "Could not read #{FileSystem.format_error(display_path, reason)}"}
    end
  end

  defp select(content, path, offset, limit) do
    lines = String.split(content, "\n")
    total_lines = length(lines)
    start_index = offset - 1

    if start_index >= total_lines do
      {:error, "Offset #{offset} is beyond end of file (#{total_lines} lines total)"}
    else
      selected_lines = select_lines(lines, start_index, limit)
      selected_content = Enum.join(selected_lines, "\n")
      truncation = Output.head(selected_content)
      format_result(truncation, path, offset, limit, length(selected_lines), total_lines)
    end
  end

  defp select_lines(lines, start_index, nil), do: Enum.drop(lines, start_index)
  defp select_lines(lines, start_index, limit), do: Enum.slice(lines, start_index, limit)

  defp format_result(%{first_line_too_large?: true}, path, offset, _limit, _selected, _total) do
    {:ok,
     "[Line #{offset} exceeds the #{Output.format_size(Output.max_bytes())} read limit. " <>
       "Use bash to inspect a byte range from #{path}.]"}
  end

  defp format_result(%{truncated?: true} = result, _path, offset, _limit, _selected, total) do
    end_line = offset + result.output_lines - 1
    next_offset = end_line + 1
    size_note = if result.truncated_by == :bytes, do: " (50KB limit)", else: ""

    {:ok,
     result.content <>
       "\n\n[Showing lines #{offset}-#{end_line} of #{total}#{size_note}. " <>
       "Use offset=#{next_offset} to continue.]"}
  end

  defp format_result(result, _path, offset, limit, selected, total) do
    consumed = offset - 1 + selected

    if not is_nil(limit) and consumed < total do
      {:ok,
       result.content <>
         "\n\n[#{total - consumed} more lines in file. Use offset=#{consumed + 1} to continue.]"}
    else
      {:ok, result.content}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_optional_positive(_name, nil), do: :ok
  defp validate_optional_positive(name, value), do: validate_positive(name, value)
end
