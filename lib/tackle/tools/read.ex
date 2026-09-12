defmodule Tackle.Tools.Read do
  @moduledoc "Reads UTF-8 text files and supported images for the agent."

  use Tackle.Lib.Tool

  alias Tackle.Lib.Tool.Content
  alias Tackle.Tools.{FileSystem, Output}

  # Images travel to the model as base64 content parts and stay in the durable
  # session, so they are capped well below the session codec's binary limit.
  @max_image_bytes 5 * 1_024 * 1_024

  tool_name("read")

  description(
    "Read a file. Text files return their UTF-8 contents (limited to 2,000 lines or 50KB; use offset " <>
      "and limit to continue reading large files). PNG, JPEG, GIF, and WebP images return a short " <>
      "summary and attach the image itself for visual inspection. Paths may be relative to the " <>
      "current working directory or absolute."
  )

  input do
    field(:path, :string, required: true, description: "Path to the file to read")

    field(:offset, :integer,
      description: "1-based line number to start reading text from (text files only)"
    )

    field(:limit, :integer, description: "Maximum number of text lines to read (text files only)")
  end

  @spec run(map(), map()) :: {:ok, String.t() | Content.t()} | {:error, String.t()}
  def run(%{"path" => path} = args, context) do
    offset = Map.get(args, "offset", 1)
    limit = Map.get(args, "limit")

    with :ok <- validate_positive(:offset, offset),
         :ok <- validate_optional_positive(:limit, limit),
         {:ok, absolute_path} <- FileSystem.resolve_path(path, context),
         {:ok, file} <- read_file(absolute_path, path) do
      render(file, path, offset, limit)
    end
  end

  defp read_file(absolute_path, display_path) do
    case File.read(absolute_path) do
      {:ok, data} ->
        classify(data, display_path)

      {:error, reason} ->
        {:error, "Could not read #{FileSystem.format_error(display_path, reason)}"}
    end
  end

  defp classify(data, display_path) do
    case image_media_type(data) do
      nil ->
        if String.valid?(data) do
          {:ok, {:text, data}}
        else
          {:error,
           "Could not read #{display_path}: file is not valid UTF-8 and is not a supported image " <>
             "(PNG, JPEG, GIF, WebP)"}
        end

      media_type ->
        read_image(data, media_type, display_path)
    end
  end

  defp image_media_type(<<0x89, "PNG\r\n", 0x1A, 0x0A, _rest::binary>>), do: "image/png"
  defp image_media_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  defp image_media_type(<<"GIF87a", _rest::binary>>), do: "image/gif"
  defp image_media_type(<<"GIF89a", _rest::binary>>), do: "image/gif"

  defp image_media_type(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>),
    do: "image/webp"

  defp image_media_type(_data), do: nil

  defp read_image(data, media_type, display_path) do
    size = byte_size(data)

    if size > @max_image_bytes do
      {:error,
       "Could not read #{display_path}: image is #{Output.format_size(size)}, larger than the " <>
         "#{Output.format_size(@max_image_bytes)} image read limit. Downscale it (for example with " <>
         "bash) and read it again."}
    else
      {:ok, {:image, media_type, size, Base.encode64(data)}}
    end
  end

  defp render({:image, media_type, size, data}, path, offset, limit) do
    if offset == 1 and is_nil(limit) do
      {:ok,
       Content.new(
         "Read image #{path} (#{media_type}, #{Output.format_size(size)}). " <>
           "The image is attached to this tool result.",
         [Content.image(media_type, data)]
       )}
    else
      {:error, "offset and limit apply only to text files"}
    end
  end

  defp render({:text, content}, path, offset, limit), do: select(content, path, offset, limit)

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
