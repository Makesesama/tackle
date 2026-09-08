defmodule Tackle.Tools.Output do
  @moduledoc false

  @max_lines 2_000
  @max_bytes 50 * 1_024

  @type truncation :: %{
          content: String.t(),
          truncated?: boolean(),
          truncated_by: :lines | :bytes | nil,
          total_lines: non_neg_integer(),
          output_lines: non_neg_integer(),
          first_line_too_large?: boolean()
        }

  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec head(String.t()) :: truncation()
  def head(content) when is_binary(content) do
    lines = lines(content)
    truncate_lines(lines, content, :head)
  end

  @spec tail(String.t()) :: truncation()
  def tail(content) when is_binary(content) do
    lines = lines(content)
    truncate_lines(lines, content, :tail)
  end

  @spec format_size(non_neg_integer()) :: String.t()
  def format_size(bytes) when bytes < 1_024, do: "#{bytes}B"

  def format_size(bytes) when bytes < 1_024 * 1_024 do
    :erlang.float_to_binary(bytes / 1_024, decimals: 1) <> "KB"
  end

  def format_size(bytes) do
    :erlang.float_to_binary(bytes / (1_024 * 1_024), decimals: 1) <> "MB"
  end

  defp truncate_lines(lines, content, direction) do
    total_lines = length(lines)

    if total_lines <= @max_lines and byte_size(content) <= @max_bytes do
      result(content, false, nil, total_lines, total_lines, false)
    else
      selected = select(lines, direction)
      first_line_too_large? = direction == :head and selected == [] and lines != []

      truncated_by =
        if length(lines) > @max_lines and length(selected) == @max_lines,
          do: :lines,
          else: :bytes

      result(
        Enum.join(selected, "\n"),
        true,
        truncated_by,
        total_lines,
        length(selected),
        first_line_too_large?
      )
    end
  end

  defp select(lines, :head) do
    lines
    |> Enum.take(@max_lines)
    |> Enum.reduce_while({[], 0}, fn line, {selected, bytes} ->
      separator_bytes = if selected == [], do: 0, else: 1
      next_bytes = bytes + separator_bytes + byte_size(line)

      if next_bytes <= @max_bytes,
        do: {:cont, {[line | selected], next_bytes}},
        else: {:halt, {selected, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp select(lines, :tail) do
    lines
    |> Enum.take(-@max_lines)
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn line, {selected, bytes} ->
      separator_bytes = if selected == [], do: 0, else: 1
      next_bytes = bytes + separator_bytes + byte_size(line)

      cond do
        next_bytes <= @max_bytes ->
          {:cont, {[line | selected], next_bytes}}

        selected == [] ->
          tail = take_tail_bytes(line, @max_bytes)
          {:halt, {[tail], byte_size(tail)}}

        true ->
          {:halt, {selected, bytes}}
      end
    end)
    |> elem(0)
  end

  defp take_tail_bytes(content, max_bytes) do
    start = max(byte_size(content) - max_bytes, 0)
    take_valid_tail(content, start)
  end

  defp take_valid_tail(content, start) do
    tail = binary_part(content, start, byte_size(content) - start)

    cond do
      String.valid?(tail) -> tail
      start < byte_size(content) -> take_valid_tail(content, start + 1)
      true -> ""
    end
  end

  defp lines(""), do: []

  defp lines(content) do
    lines = String.split(content, "\n")
    if String.ends_with?(content, "\n"), do: Enum.drop(lines, -1), else: lines
  end

  defp result(content, truncated?, truncated_by, total_lines, output_lines, first_line?) do
    %{
      content: content,
      truncated?: truncated?,
      truncated_by: truncated_by,
      total_lines: total_lines,
      output_lines: output_lines,
      first_line_too_large?: first_line?
    }
  end
end
