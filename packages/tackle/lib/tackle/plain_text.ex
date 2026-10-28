defmodule Tackle.PlainText do
  @moduledoc false

  # Text that agent services (`Tackle.Watchdog`, `Tackle.Narrator`) send to a
  # model: command output, tool arguments, and assistant text arrive with
  # terminal control sequences, carriage-return redraws, and invalid bytes,
  # which are noise for the model and break JSON encoding. Every cut keeps
  # whole characters, so the result stays valid UTF-8.

  # CSI (`ESC [ … final`), OSC (`ESC ] … BEL` or `ESC ] … ESC \`), and the
  # other escape sequences: `ESC`, optional intermediate bytes, one final byte
  # (`ESC 7`, `ESC (B`, `ESC M`, …).
  @escape ~r/\e\[[0-?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[ -\/]*[0-~]/u
  # C0 controls except tab and newline, DEL, and C1 controls.
  @control ~r/[\x00-\x08\x0B-\x1F\x7F\x{80}-\x{9F}]/u
  @ellipsis "…"

  @doc """
  Cleans text for a model.

  Drops invalid UTF-8, terminal escape sequences, and control characters
  other than tab and newline. Carriage returns are redraws: each line keeps
  only what follows its last one, as a terminal would finally show it, and
  `\\r\\n` ends a line.
  """
  @spec clean(String.t()) :: String.t()
  def clean(text) when is_binary(text) do
    text
    |> String.replace_invalid("")
    |> String.replace(@escape, "")
    |> String.split("\n")
    |> Enum.map_join("\n", &redraw/1)
    |> String.replace(@control, "")
  end

  defp redraw(line) do
    line |> String.trim_trailing("\r") |> String.split("\r") |> List.last()
  end

  @doc "Cuts `text` to its first `chars` characters, marking a cut with `…`."
  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(text, chars) when is_binary(text) and is_integer(chars) and chars >= 0 do
    if String.length(text) <= chars, do: text, else: String.slice(text, 0, chars) <> @ellipsis
  end

  @doc """
  Cuts `text` to at most `bytes` bytes without splitting a character, marking
  a cut with `…` within that limit (a limit too small for the mark gets none).
  """
  @spec truncate_bytes(String.t(), non_neg_integer()) :: String.t()
  def truncate_bytes(text, bytes) when is_binary(text) and byte_size(text) <= bytes, do: text

  def truncate_bytes(text, bytes)
      when is_binary(text) and is_integer(bytes) and bytes >= byte_size(@ellipsis),
      do: cut_end(text, bytes - byte_size(@ellipsis)) <> @ellipsis

  def truncate_bytes(text, bytes) when is_binary(text) and is_integer(bytes) and bytes >= 0,
    do: cut_end(text, bytes)

  defp cut_end(text, bytes), do: text |> binary_part(0, bytes) |> drop_partial_last()

  @doc "Keeps the last `chars` characters of `text`."
  @spec last_chars(String.t(), non_neg_integer()) :: String.t()
  def last_chars(text, chars) when is_binary(text) and is_integer(chars) and chars >= 0 do
    length = String.length(text)
    if length <= chars, do: text, else: String.slice(text, length - chars, chars)
  end

  @doc "Keeps at most the last `bytes` bytes of `text` without splitting a character."
  @spec last_bytes(binary(), non_neg_integer()) :: binary()
  def last_bytes(text, bytes) when is_binary(text) and byte_size(text) <= bytes, do: text

  def last_bytes(text, bytes) when is_binary(text) and is_integer(bytes) and bytes >= 0,
    do: text |> binary_part(byte_size(text) - bytes, bytes) |> drop_partial_first()

  # A cut at a byte offset can split a UTF-8 character: drop the leftover
  # continuation bytes at the start, or the unfinished character at the end.
  defp drop_partial_first(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_partial_first(rest)

  defp drop_partial_first(text), do: text

  defp drop_partial_last(text) do
    case :unicode.characters_to_binary(text) do
      {:incomplete, valid, _rest} -> valid
      _complete -> text
    end
  end
end
