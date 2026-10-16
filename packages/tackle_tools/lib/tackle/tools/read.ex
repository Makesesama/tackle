defmodule Tackle.Tools.Read do
  @moduledoc "Reads UTF-8 text files and supported images for the agent."

  use Tackle.Lib.Tool

  alias Tackle.Executor
  alias Tackle.Lib.Tool.Content
  alias Tackle.Tools.{FileSystem, Output}

  # Images travel to the model as base64 content parts and stay in the durable
  # session, so they are capped well below the session codec's binary limit.
  @max_image_bytes 5 * 1_024 * 1_024
  @chunk_bytes 64 * 1_024

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

  # Reading changes nothing, so a durable session need not sync the tool intent
  # before it runs.
  @impl true
  def effect, do: :read_only

  @spec run(map(), map()) :: {:ok, String.t() | Content.t()} | {:error, String.t()}
  def run(%{"path" => path} = args, context) do
    offset = Map.get(args, "offset", 1)
    limit = Map.get(args, "limit")

    with :ok <- positive(:offset, offset),
         :ok <- optional_positive(:limit, limit),
         {:ok, absolute} <- FileSystem.resolve_path(path, context) do
      read(Executor.from_context(context), absolute, path, offset, limit)
    end
  end

  # The file is read as a sequence of byte ranges through the executor, so the
  # same logic works locally and inside a jail.
  defp read(executor, path, display, offset, limit) do
    source = %{executor: executor, path: path, offset: 0, eof: false}

    case next_chunk(source) do
      {:ok, first, size, source} -> read_content(source, first, size, display, offset, limit)
      :eof -> text(source, <<>>, display, offset, limit)
      {:error, reason} -> read_error(display, reason)
    end
  end

  # The first chunk decides whether the file is a supported image or text.
  defp read_content(source, first, size, display, offset, limit) do
    case media(first) do
      nil ->
        text(source, first, display, offset, limit)

      type ->
        with {:ok, data} <- image(source, first, size, type, display) do
          render_image(data, display, offset, limit)
        end
    end
  end

  defp next_chunk(%{eof: true}), do: :eof

  defp next_chunk(source) do
    case Executor.read(source.executor, source.path, source.offset, @chunk_bytes) do
      {:ok, %{data: ""}} ->
        :eof

      {:ok, %{data: data, size: size, eof: eof}} ->
        {:ok, data, size, %{source | offset: source.offset + byte_size(data), eof: eof}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp text(source, prefix, path, offset, limit) do
    state = %{
      pending: "",
      line_no: 1,
      offset: offset,
      limit: limit,
      content: "",
      retained_newlines: 0
    }

    case text_chunks(source, prefix, state) do
      {:error, :invalid} ->
        {:error,
         "Could not read #{path}: file is not valid UTF-8 and is not a supported image " <>
           "(PNG, JPEG, GIF, WebP)"}

      {:error, reason} ->
        read_error(path, reason)

      {:ok, state} ->
        total = state.line_no

        if offset > total do
          {:error, "Offset #{offset} is beyond end of file (#{total} lines total)"}
        else
          selected = min(total - offset + 1, limit || total)
          result = Output.head(state.content)
          format_result(result, path, offset, limit, selected, total)
        end
    end
  end

  defp text_chunks(source, data, state) do
    case :unicode.characters_to_binary(state.pending <> data, :utf8, :utf8) do
      valid when is_binary(valid) ->
        next_text_chunk(source, scan(%{state | pending: ""}, valid))

      {:incomplete, valid, rest} ->
        next_text_chunk(source, scan(%{state | pending: IO.iodata_to_binary(rest)}, valid))

      {:error, _, _} ->
        {:error, :invalid}
    end
  end

  defp next_text_chunk(source, state) do
    case next_chunk(source) do
      :eof -> if state.pending == "", do: {:ok, state}, else: {:error, :invalid}
      {:error, reason} -> {:error, reason}
      {:ok, data, _size, source} -> text_chunks(source, data, state)
    end
  end

  defp scan(state, ""), do: state

  defp scan(state, <<10, rest::binary>>) do
    # A newline belongs to the selection only when both adjacent fields do.
    state =
      if selected_line?(state, state.line_no + 1) and selected_line?(state, state.line_no),
        do: retain(state, "\n"),
        else: state

    scan(%{state | line_no: state.line_no + 1}, rest)
  end

  defp scan(state, binary) do
    {part, rest} =
      case :binary.match(binary, "\n") do
        {at, 1} -> {binary_part(binary, 0, at), binary_part(binary, at, byte_size(binary) - at)}
        :nomatch -> {binary, ""}
      end

    state = if selected_line?(state, state.line_no), do: retain(state, part), else: state
    scan(state, rest)
  end

  defp selected_line?(state, line_no) do
    line_no >= state.offset and
      (is_nil(state.limit) or line_no < state.offset + state.limit)
  end

  # Retain a prefix with enough extra bytes/lines to witness truncation. The
  # existing Output.head/1 then preserves all boundary and newline semantics.
  # Never retain the rest of a huge line, even while scanning it for validation.
  defp retain(state, data) do
    if byte_size(state.content) > Output.max_bytes() or
         state.retained_newlines > Output.max_lines() do
      state
    else
      room = Output.max_bytes() + 4 - byte_size(state.content)
      prefix = binary_part(data, 0, min(byte_size(data), room)) |> valid_prefix()
      state = %{state | content: state.content <> prefix}
      %{state | retained_newlines: state.retained_newlines + if(data == "\n", do: 1, else: 0)}
    end
  end

  defp valid_prefix(data) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _} -> IO.iodata_to_binary(valid)
    end
  end

  # Reject an oversized image from its reported size before transferring it.
  defp image(_source, _first, size, _type, path) when size > @max_image_bytes,
    do: {:error, image_too_large(path, size)}

  defp image(source, first, _size, type, path) do
    case image_chunks(source, [first], byte_size(first)) do
      {:ok, size, chunks} when size <= @max_image_bytes ->
        encoded = chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Base.encode64()
        {:ok, {:image, type, size, encoded}}

      {:ok, size, _} ->
        {:error, image_too_large(path, size)}

      {:error, reason} ->
        read_error(path, reason)
    end
  end

  # The file can grow while it is read, so the limit is checked again here.
  defp image_chunks(source, chunks, size) do
    case next_chunk(source) do
      :eof ->
        {:ok, size, chunks}

      {:error, reason} ->
        {:error, reason}

      {:ok, data, _size, source} ->
        n = size + byte_size(data)

        if n <= @max_image_bytes,
          do: image_chunks(source, [data | chunks], n),
          else: {:ok, n, []}
    end
  end

  defp image_too_large(path, size) do
    "Could not read #{path}: image is #{Output.format_size(size)}, larger than the " <>
      "#{Output.format_size(@max_image_bytes)} image read limit. Downscale it (for example " <>
      "with bash) and read it again."
  end

  defp media(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>), do: "image/png"
  defp media(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp media(<<"GIF87a", _::binary>>), do: "image/gif"
  defp media(<<"GIF89a", _::binary>>), do: "image/gif"
  defp media(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp media(_), do: nil

  defp render_image({:image, type, size, data}, path, 1, nil),
    do:
      {:ok,
       Content.new(
         "Read image #{path} (#{type}, #{Output.format_size(size)}). The image is attached to this tool result.",
         [Content.image(type, data)]
       )}

  defp render_image({:image, _, _, _}, _, _, _),
    do: {:error, "offset and limit apply only to text files"}

  defp format_result(%{first_line_too_large?: true}, path, offset, _limit, _selected, _total),
    do:
      {:ok,
       "[Line #{offset} exceeds the #{Output.format_size(Output.max_bytes())} read limit. Use bash to inspect a byte range from #{path}.]"}

  defp format_result(%{truncated?: true} = result, _path, offset, _limit, _selected, total) do
    output_lines = result.output_lines
    end_line = offset + output_lines - 1
    next_offset = end_line + 1
    note = if result.truncated_by == :bytes, do: " (50KB limit)", else: ""

    {:ok,
     result.content <>
       "\n\n[Showing lines #{offset}-#{end_line} of #{total}#{note}. Use offset=#{next_offset} to continue.]"}
  end

  defp format_result(result, _path, offset, limit, selected, total) do
    consumed = offset - 1 + selected

    if limit && consumed < total,
      do:
        {:ok,
         result.content <>
           "\n\n[#{total - consumed} more lines in file. Use offset=#{consumed + 1} to continue.]"},
      else: {:ok, result.content}
  end

  defp read_error(path, reason),
    do: {:error, "Could not read #{FileSystem.format_error(path, reason)}"}

  defp positive(_name, n) when is_integer(n) and n > 0, do: :ok
  defp positive(name, _), do: {:error, "#{name} must be a positive integer"}
  defp optional_positive(_name, nil), do: :ok
  defp optional_positive(name, n), do: positive(name, n)
end
