defmodule Tackle.Watchdog.Digest do
  @moduledoc """
  Bounded observation of one running `bash` call, and the state a decision
  model judges it by.

  A digest keeps the command, its start time, the time of its last output, a
  byte count, and the last 4096 bytes of output. `state/2` turns that into a
  small JSON-compatible map: elapsed time, output rate, silence, how repetitive
  the recent output is, and the cleaned output tail. Times are monotonic
  milliseconds supplied by the caller.

  Local decision models accept only a couple of thousand tokens and never
  truncate input, so the state stays small: the command is cut to 400 bytes,
  runs of identical lines are collapsed, and only the last 800 bytes of the
  cleaned tail are sent.
  """

  @tail_bytes 4096
  @state_tail_bytes 800
  @command_bytes 400
  @repetition_lines 64
  @min_repetition_lines 4
  @ansi ~r/\e\[[0-?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)/

  @enforce_keys [:command, :started_at]
  defstruct [:command, :started_at, :last_output_at, tail: "", bytes: 0]

  @type t :: %__MODULE__{
          command: String.t(),
          started_at: integer(),
          last_output_at: integer() | nil,
          tail: String.t(),
          bytes: non_neg_integer()
        }

  @doc "Starts a digest for `command` observed at `now`."
  @spec new(String.t(), integer()) :: t()
  def new(command, now) when is_binary(command) and is_integer(now),
    do: %__MODULE__{command: command, started_at: now}

  @doc "Records an output chunk received at `now`."
  @spec append(t(), String.t(), integer()) :: t()
  def append(%__MODULE__{} = digest, chunk, now) when is_binary(chunk) and chunk != "" do
    %{
      digest
      | tail: keep_tail(digest.tail <> chunk),
        bytes: digest.bytes + byte_size(chunk),
        last_output_at: now
    }
  end

  def append(%__MODULE__{} = digest, _chunk, _now), do: digest

  @doc "Milliseconds since the command started."
  @spec elapsed_ms(t(), integer()) :: non_neg_integer()
  def elapsed_ms(%__MODULE__{started_at: started_at}, now), do: max(now - started_at, 0)

  @doc "Returns the decision-model state for the command at `now`."
  @spec state(t(), integer()) :: map()
  def state(%__MODULE__{} = digest, now) do
    elapsed_seconds = elapsed_ms(digest, now) / 1_000
    lines = tail_lines(digest.tail)

    %{
      "command" => truncate(digest.command, @command_bytes),
      "elapsed_seconds" => Float.round(elapsed_seconds, 1),
      "output_bytes" => digest.bytes,
      "output_bytes_per_second" => rate(digest.bytes, elapsed_seconds),
      "seconds_since_last_output" => silence(digest, now, elapsed_seconds),
      "output_repetition" => repetition(lines),
      "output_tail" => lines |> collapse_repeats() |> Enum.join("\n") |> last_bytes()
    }
  end

  @doc """
  Fraction (`0.0..1.0`) of recent non-blank output lines that repeat an earlier
  line once digits are ignored, so a loop printing a counter still counts as
  repetitive. Fewer than 4 lines report `0.0`.
  """
  @spec repetition([String.t()]) :: float()
  def repetition(lines) when is_list(lines) do
    recent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.take(-@repetition_lines)
      |> Enum.map(&String.replace(&1, ~r/\d+/, "#"))

    total = length(recent)

    if total < @min_repetition_lines do
      0.0
    else
      Float.round(1 - MapSet.size(MapSet.new(recent)) / total, 2)
    end
  end

  # Terminal control sequences and carriage-return redraws are noise for the
  # model: keep only what a terminal would finally show on each line.
  defp tail_lines(""), do: []

  defp tail_lines(tail) do
    tail
    |> String.replace(@ansi, "")
    |> String.split("\n")
    |> Enum.map(fn line ->
      line |> String.trim_trailing("\r") |> String.split("\r") |> List.last()
    end)
  end

  # `yes`-style output would otherwise fill the tail with one line; the
  # repetition itself is what the model needs to see.
  defp collapse_repeats(lines) do
    lines
    |> Enum.chunk_by(& &1)
    |> Enum.flat_map(fn
      [line] -> [line]
      [line | rest] -> [line, "[previous line repeated #{length(rest)} more times]"]
    end)
  end

  defp last_bytes(text) when byte_size(text) <= @state_tail_bytes, do: text

  defp last_bytes(text) do
    text
    |> binary_part(byte_size(text) - @state_tail_bytes, @state_tail_bytes)
    |> drop_partial_character()
  end

  defp rate(_bytes, elapsed_seconds) when elapsed_seconds <= 0, do: 0.0
  defp rate(bytes, elapsed_seconds), do: Float.round(bytes / elapsed_seconds, 1)

  defp silence(%__MODULE__{last_output_at: nil}, _now, elapsed_seconds),
    do: Float.round(elapsed_seconds, 1)

  defp silence(%__MODULE__{last_output_at: at}, now, _elapsed_seconds),
    do: Float.round(max(now - at, 0) / 1_000, 1)

  defp keep_tail(tail) when byte_size(tail) <= @tail_bytes, do: tail

  defp keep_tail(tail) do
    tail
    |> binary_part(byte_size(tail) - @tail_bytes, @tail_bytes)
    |> drop_partial_character()
  end

  defp truncate(text, bytes) when byte_size(text) <= bytes, do: text

  defp truncate(text, bytes) do
    prefix = binary_part(text, 0, bytes)

    case :unicode.characters_to_binary(prefix) do
      {:incomplete, valid, _rest} -> valid <> "…"
      _valid -> prefix <> "…"
    end
  end

  # Cutting at a byte offset can split a UTF-8 character; drop its leftover
  # continuation bytes so the tail stays valid text.
  defp drop_partial_character(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_partial_character(rest)

  defp drop_partial_character(tail), do: tail
end
