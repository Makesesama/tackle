defmodule Tackle.Tools.Bash.Capture do
  @moduledoc false

  # Retains a bounded tail of command output. Once output exceeds the display
  # limits, everything is also spilled to a private file through the executor,
  # so the file is where the model's `read` tool looks for it.

  alias Tackle.Executor
  alias Tackle.Tools.Output

  @max_bytes Output.max_bytes()
  @max_lines Output.max_lines()
  @full_output_attempts 3

  @spec new(Executor.t()) :: map()
  def new(executor \\ Executor.local()) do
    %{
      executor: executor,
      tail: "",
      prefix: "",
      bytes: 0,
      newlines: 0,
      ends_in_newline?: false,
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
      state.path -> write_spill(state, data)
      state.spill_failed? -> state
      truncated?(state) -> start_spill(state, [prefix, data])
      true -> %{state | prefix: state.prefix <> data}
    end
  end

  @spec discard(map()) :: :ok
  def discard(state) do
    if state.path, do: Executor.delete(state.executor, state.path)
    :ok
  end

  @spec finish(map()) :: String.t()
  def finish(state) do
    if not truncated?(state) and state.path, do: Executor.delete(state.executor, state.path)

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
    case create_spill(state.executor, IO.iodata_to_binary(data), @full_output_attempts) do
      {:ok, path} -> %{state | path: path, prefix: ""}
      :error -> %{state | prefix: "", spill_failed?: true}
    end
  end

  defp write_spill(state, data) do
    case Executor.write(state.executor, state.path, data, mode: :append) do
      :ok ->
        state

      {:error, _reason} ->
        Executor.delete(state.executor, state.path)
        %{state | path: nil, spill_failed?: true}
    end
  end

  defp create_spill(_executor, _data, 0), do: :error

  defp create_spill(executor, data, attempts) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    path = Path.join(Executor.tmp_dir(executor), "tackle-bash-#{suffix}.log")

    case Executor.write(executor, path, data, mode: :create) do
      :ok -> {:ok, path}
      {:error, :eexist} -> create_spill(executor, data, attempts - 1)
      {:error, _reason} -> :error
    end
  end
end
