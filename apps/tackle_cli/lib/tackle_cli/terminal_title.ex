defmodule Tackle.CLI.TerminalTitle do
  @moduledoc """
  Terminal-title output helpers for the shell.

  This module owns the low-level OSC title write path and the sanitization that
  happens immediately before we emit it. It is intentionally narrow: callers
  decide when the title should change and whether an empty title means "leave
  the old title alone" or "clear the title Tackle last wrote". This module does
  not attempt to read or restore the terminal's previous title because that is
  not portable across terminals.

  Sanitization is necessary because title content is assembled from untrusted
  text sources such as model output, session ids, and configuration. Before we
  place that text inside an OSC sequence, we strip:

    * control characters that could terminate or reshape the escape sequence
    * bidi/invisible formatting codepoints that can visually reorder or hide
      text (the same family of issues discussed in Trojan Source writeups)
    * redundant whitespace that would make titles noisy or hard to scan

  GNU Screen truncates Unicode in OSC titles to a byte, which can turn visible
  characters into control bytes and spill title text into the terminal. Under
  Screen, the entire finished title must therefore use printable ASCII. This
  conversion happens here so shared in-shell status rendering keeps its
  Unicode.
  """

  alias Tackle.CLI.Native

  # Practical upper bound on title length, measured in Unicode codepoints.
  #
  # Most terminals silently truncate titles beyond a few hundred characters.
  # 240 leaves headroom for the OSC framing bytes while keeping titles
  # readable in tab bars and window managers.
  @max_chars 240

  @typedoc "Title encoding, ASCII-only under GNU Screen."
  @type encoding :: :unicode | :screen

  @typedoc """
  Outcome of a `set/1` call.

  `:no_visible_content` is distinct from clearing the title: sanitization
  removed every visible character, so no title was emitted. Callers decide
  whether an empty post-sanitization value should result in a no-op, clearing
  the title Tackle manages, or some other fallback.
  """
  @type set_result :: :applied | :no_visible_content

  @doc """
  Writes a sanitized OSC window-title sequence to stdout.

  The input is treated as untrusted display text: control characters,
  invisible formatting characters, and redundant whitespace are removed before
  the title is emitted. If sanitization removes all visible content, returns
  `{:ok, :no_visible_content}` instead of clearing the title, because clearing
  and restoring are policy decisions for higher-level callers. When stdout is
  not a terminal, no write is needed and `{:ok, :applied}` is returned.
  """
  @spec set(String.t()) :: {:ok, set_result()} | {:error, term()}
  def set(title) when is_binary(title) do
    if Native.stdout_is_terminal() do
      case sanitize(title, encoding()) do
        "" -> {:ok, :no_visible_content}
        sanitized -> sanitized |> osc0() |> emit()
      end
    else
      {:ok, :applied}
    end
  end

  @doc """
  Clears the current terminal title by writing an empty OSC title payload.

  This clears the visible title; it does not restore whatever title the shell
  or a previous program may have set before Tackle started managing the title.
  """
  @spec clear() :: :ok | {:error, term()}
  def clear do
    if Native.stdout_is_terminal() do
      case emit(osc0("")) do
        {:ok, :applied} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  @doc """
  Writes `title`, or clears the managed title when `nil`.

  The single seam the interactive shell injects so tests can observe title
  writes without touching the real terminal.
  """
  @spec write(String.t() | nil) :: {:ok, set_result()} | :ok | {:error, term()}
  def write(nil), do: clear()
  def write(title), do: set(title)

  @doc "Returns the OSC 0 window-title sequence for `title`, BEL-terminated."
  @spec osc0(String.t()) :: binary()
  def osc0(title) when is_binary(title), do: "\e]0;" <> title <> "\a"

  @doc """
  Normalizes untrusted title text into a single bounded display line.

  This removes terminal control characters, strips invisible/bidi formatting
  characters, collapses any whitespace run into a single ASCII space, and
  truncates after 240 emitted codepoints. Under `:screen` encoding the
  finished title is printable ASCII, because GNU Screen truncates Unicode
  titles to a byte and can turn visible characters into control bytes.
  """
  @spec sanitize(String.t(), encoding()) :: String.t()
  def sanitize(title, encoding) when is_binary(title) do
    {chars, _count, _pending_space?} =
      title
      |> String.to_charlist()
      |> Enum.reduce({[], 0, false}, fn char, {chars, count, pending_space?} ->
        cond do
          whitespace?(char) ->
            # Only keep a pending space once content exists; this strips
            # leading whitespace without an extra trim pass.
            {chars, count, chars != []}

          disallowed?(char) ->
            {chars, count, pending_space?}

          true ->
            char = encode(char, encoding)

            {chars, count} =
              if pending_space? and @max_chars - count > 1 do
                {[?\s | chars], count + 1}
              else
                {chars, count}
              end

            if count < @max_chars do
              {[char | chars], count + 1, false}
            else
              {chars, count, false}
            end
        end
      end)

    chars |> Enum.reverse() |> List.to_string()
  end

  # Screen remains an output hop when another multiplexer runs inside it.
  # TERM=screen alone is not sufficient: tmux also commonly uses that TERM.
  defp encoding do
    if System.get_env("STY"), do: :screen, else: :unicode
  end

  # `IO.binwrite/2` raises on failure rather than returning an error tuple.
  defp emit(sequence) do
    IO.binwrite(:stdio, sequence)
    {:ok, :applied}
  rescue
    reason -> {:error, reason}
  end

  # Unicode White_Space codepoints, matching Rust's `char::is_whitespace`.
  defp whitespace?(char) do
    char in [
      ?\t,
      ?\n,
      ?\v,
      ?\f,
      ?\r,
      0x20,
      0x85,
      0xA0,
      0x1680,
      0x2028,
      0x2029,
      0x202F,
      0x205F,
      0x3000
    ] or
      char in 0x2000..0x200A
  end

  # Plain control characters plus a curated set of invisible formatting
  # codepoints. The bidi entries cover the Trojan-Source-style
  # text-reordering controls that can make a title render misleadingly
  # relative to its underlying byte sequence.
  defp disallowed?(char) do
    control?(char) or
      char in [
        0x00AD,
        0x034F,
        0x061C,
        0x180E,
        0xFEFF
      ] or
      char in 0x200B..0x200F or
      char in 0x202A..0x202E or
      char in 0x2060..0x206F or
      char in 0xFE00..0xFE0F or
      char in 0xFFF9..0xFFFB or
      char in 0x1BCA0..0x1BCA3 or
      char in 0xE0100..0xE01EF
  end

  # C0 and C1 control characters.
  defp control?(char), do: char < 0x20 or char in 0x7F..0x9F

  # Under Screen the finished title must be printable ASCII. The braille
  # spinner frames keep their visible animation without allowing Screen to
  # turn, for example, U+2807 into BEL; other non-ASCII becomes '?'.
  defp encode(char, :screen) when char in [0x280B, 0x283C, 0x2807], do: ?|
  defp encode(char, :screen) when char in [0x2819, 0x2834, 0x280F], do: ?/
  defp encode(char, :screen) when char in [0x2839, 0x2826], do: ?-
  defp encode(char, :screen) when char in [0x2838, 0x2827], do: ?\\
  defp encode(0x25CF, :screen), do: ?*
  defp encode(char, :screen) when char < 0x80, do: char
  defp encode(_char, :screen), do: ??
  defp encode(char, :unicode), do: char
end
