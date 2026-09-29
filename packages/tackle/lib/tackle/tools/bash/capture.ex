defmodule Tackle.Tools.Bash.Capture do
  @moduledoc false

  alias Tackle.Tools.Output

  @max_bytes Output.max_bytes()
  @max_lines Output.max_lines()
  @private_file_mode 0o600
  @full_output_attempts 3

  @spec new() :: map()
  def new do
    %{
      tail: "",
      prefix: "",
      bytes: 0,
      newlines: 0,
      ends_in_newline?: false,
      file: nil,
      path: nil,
      spill_failed?: false
    }
  end

  @spec append(map(), String.t()) :: map()
  def append(state, ""), do: state

  def append(state, data) do
    prefix = state.prefix

    state = %{
      state
      | bytes: state.bytes + byte_size(data),
        newlines: state.newlines + count_newlines(data),
        ends_in_newline?: String.ends_with?(data, "\n"),
        tail: trim_tail(state.tail <> data)
    }

    cond do
      state.file -> write_spill(state, data)
      state.spill_failed? -> state
      truncated?(state) -> start_spill(state, [prefix, data])
      true -> %{state | prefix: state.prefix <> data}
    end
  end

  @spec discard(map()) :: :ok
  def discard(state) do
    if state.file, do: File.close(state.file)
    if state.path, do: File.rm(state.path)
    :ok
  end

  @spec finish(map()) :: String.t()
  def finish(state) do
    state = close_spill(state)

    if not truncated?(state) and state.path, do: File.rm(state.path)

    format_output(state)
  end

  defp format_output(%{bytes: 0}), do: "(no output)"

  defp format_output(state) do
    result = Output.tail(state.tail)

    if truncated?(state) do
      total = lines(state)
      start_line = total - result.output_lines + 1
      location = if state.path, do: " Full output: #{state.path}", else: ""

      truncated_content(result) <>
        "\n\n[Showing lines #{start_line}-#{total} of #{total}.#{location}]"
    else
      result.content
    end
  end

  defp truncated_content(result) do
    if not result.truncated? and String.ends_with?(result.content, "\n") do
      binary_part(result.content, 0, byte_size(result.content) - 1)
    else
      result.content
    end
  end

  defp lines(%{bytes: 0}), do: 0
  defp lines(state), do: state.newlines + if(state.ends_in_newline?, do: 0, else: 1)
  defp truncated?(state), do: state.bytes > @max_bytes or lines(state) > @max_lines

  # Keep more than the display limit so Output.tail/1 always sees complete
  # candidate lines, even if the retained window began in the middle of one.
  defp trim_tail(data) when byte_size(data) <= @max_bytes * 4, do: data

  defp trim_tail(data) do
    start = byte_size(data) - @max_bytes * 2
    tail = valid_tail(data, start)

    # Copy the retained window so a sub-binary cannot pin a discarded chunk.
    :binary.copy(
      case :binary.match(tail, "\n") do
        {at, 1} when at < byte_size(tail) - 1 ->
          binary_part(tail, at + 1, byte_size(tail) - at - 1)

        _ ->
          tail
      end
    )
  end

  defp valid_tail(data, start) do
    tail = binary_part(data, start, byte_size(data) - start)
    if String.valid?(tail), do: tail, else: valid_tail(data, start + 1)
  end

  defp count_newlines(data), do: length(:binary.matches(data, "\n"))

  defp start_spill(state, data) do
    case open_spill(@full_output_attempts) do
      {:ok, file, path} ->
        state = %{state | file: file, path: path, prefix: ""}
        write_spill(state, data)

      :error ->
        %{state | prefix: "", spill_failed?: true}
    end
  end

  defp write_spill(state, data) do
    case :file.write(state.file, data) do
      :ok ->
        state

      {:error, _} ->
        File.close(state.file)
        File.rm(state.path)
        %{state | file: nil, path: nil, spill_failed?: true}
    end
  end

  defp close_spill(%{file: nil} = state), do: state

  defp close_spill(state) do
    case File.close(state.file) do
      :ok ->
        %{state | file: nil}

      {:error, _} ->
        File.rm(state.path)
        %{state | file: nil, path: nil, spill_failed?: true}
    end
  end

  defp open_spill(0), do: :error

  defp open_spill(attempts) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "tackle-bash-#{suffix}.log")

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        case File.chmod(path, @private_file_mode) do
          :ok ->
            {:ok, file, path}

          {:error, _} ->
            File.close(file)
            File.rm(path)
            :error
        end

      {:error, :eexist} ->
        open_spill(attempts - 1)

      {:error, _} ->
        :error
    end
  end
end
