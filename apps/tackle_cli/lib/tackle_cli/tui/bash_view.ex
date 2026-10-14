defmodule Tackle.CLI.TUI.BashView do
  @moduledoc """
  Pure helpers that shape a `bash` call for its tool card.

  A card reads like a shell prompt: the directory of a leading `cd <dir> &&`
  (or `;`), an accent `$`, and the command painted in the transcript's own
  palette. A small tokenizer assigns `Tackle.CLI.TUI.Theme` tones rather than
  a syntax theme's colors, so the prompt matches the rest of the UI in light
  and dark terminals: command names take the prompt's accent, arguments the
  text tone, flags and quoted strings recede to muted, and connectors and
  redirections to subtle. Heredoc bodies are another language and stay plain
  text. Only paint is shaped; the inspector, search and copy keep the
  submitted command and output.

  Failed calls end with the bash tool's `Command exited with code N` trailer;
  `outcome/1` lifts the code out so the card can show it as status instead of
  a line of output.
  """

  alias Tackle.CLI.TUI.{MessageView, Theme}

  @cd ~r/\A\s*cd\s+('[^'\n]*'|"[^"\n]*"|[^\s;&|'"<>]+)\s*(?:&&|;)\s*(?=\S)/
  @exit ~r/\n*Command exited with code (-?\d+)\s*\z/
  @heredoc ~r/<<-?\s*(?:'([^']+)'|"([^"]+)"|([A-Za-z_]\w*))/
  # Quoted strings (possibly unterminated), connectors and redirections,
  # flags at a word start, whitespace, and plain words.
  @token ~r/'[^']*'?|"(?:\\.|[^"\\])*"?|&&|\|\||[|;&<>()]+|(?<!\S)--?[A-Za-z0-9][\w.-]*(?:=\S*)?|\s+|[^\s'"|;&<>()]+|./u
  # Tokens after which the next word names a command.
  @command_starts ["&&", "||", "|", ";", "&", "(", "|&"]

  @doc """
  Splits a leading `cd <dir> &&` or `cd <dir>;` from the command.

  Returns `{dir, rest}`, or `{nil, command}` when the command does not start
  in another directory. Quotes are removed and a directory below the current
  working directory is shown relative to it (others below the home directory
  start with `~`); the current directory itself is dropped, since every
  command already runs there.
  """
  @spec split_cwd(String.t()) :: {String.t() | nil, String.t()}
  def split_cwd(command) when is_binary(command) do
    case Regex.run(@cd, command, return: :index) do
      [{0, length}, {start, size} | _] ->
        rest = binary_part(command, length, byte_size(command) - length)

        case command |> binary_part(start, size) |> unquote_dir() |> display_dir() do
          "." -> {nil, rest}
          dir -> {dir, rest}
        end

      _ ->
        {nil, command}
    end
  end

  defp unquote_dir("'" <> rest), do: String.trim_trailing(rest, "'")
  defp unquote_dir("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp unquote_dir(dir), do: dir

  defp display_dir("/" <> _ = dir) do
    case Path.relative_to_cwd(dir) do
      "/" <> _ -> home_relative(dir, System.user_home())
      relative -> relative
    end
  end

  defp display_dir(dir), do: dir

  defp home_relative(dir, home) when is_binary(home) and home not in ["", "/"] do
    cond do
      dir == home -> "~"
      String.starts_with?(dir, home <> "/") -> "~" <> String.replace_prefix(dir, home, "")
      true -> dir
    end
  end

  defp home_relative(dir, _home), do: dir

  @doc """
  Styled spans for each line of `command`, one list per line.

  Lines inside a heredoc are its body, not shell, and stay in the text tone
  up to and including their terminator.
  """
  @spec line_spans(String.t()) :: [[ExRatatui.Text.Span.t()]]
  def line_spans(command) when is_binary(command) do
    command
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map_reduce(nil, &line_spans/2)
    |> elem(0)
  end

  defp line_spans(line, nil), do: {shell_spans(line), heredoc(line)}

  defp line_spans(line, terminator) do
    next = if String.trim(line) == terminator, do: nil, else: terminator
    {text_spans(line), next}
  end

  defp heredoc(line) do
    case Regex.run(@heredoc, line, capture: :all_but_first) do
      nil -> nil
      captures -> Enum.find(captures, &(&1 != ""))
    end
  end

  defp text_spans(""), do: []
  defp text_spans(line), do: [MessageView.span(line, Theme.style(:text))]

  @doc false
  @spec shell_spans(String.t()) :: [ExRatatui.Text.Span.t()]
  def shell_spans(""), do: []

  def shell_spans(line) do
    @token
    |> Regex.scan(line)
    |> Enum.map_reduce(true, fn [token | _], command? -> classify(token, command?) end)
    |> elem(0)
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map(fn chunk ->
      tone = chunk |> hd() |> elem(1)
      MessageView.span(Enum.map_join(chunk, &elem(&1, 0)), Theme.style(tone))
    end)
  end

  # Returns the token's tone and whether the next word is in command position.
  defp classify(token, command?) do
    cond do
      String.trim(token) == "" -> {{token, :text}, command?}
      token in @command_starts -> {{token, :subtle}, true}
      token =~ ~r/\A[|;&<>()]+\z/ -> {{token, :subtle}, false}
      String.starts_with?(token, ["'", "\""]) -> {{token, :muted}, false}
      token =~ ~r/\A--?\w/u -> {{token, :muted}, false}
      # `FOO=bar cmd`: the assignment keeps the next word in command position.
      command? and token =~ ~r/\A[A-Za-z_]\w*=/ -> {{token, :muted}, true}
      command? -> {{token, :accent_soft}, false}
      true -> {{token, :text}, false}
    end
  end

  @doc """
  Splits the exit-code trailer from a failed call's output.

  Returns the output without the tool's `Error: ` prefix and trailer, and the
  exit code when the trailer was present.
  """
  @spec outcome(String.t() | nil) :: {String.t(), integer() | nil}
  def outcome(nil), do: {"", nil}

  def outcome(output) when is_binary(output) do
    output = String.replace_prefix(output, "Error: ", "")

    case Regex.run(@exit, output, return: :index) do
      [{start, _length}, {code_start, code_size}] ->
        code = output |> binary_part(code_start, code_size) |> String.to_integer()
        {binary_part(output, 0, start), code}

      _ ->
        {output, nil}
    end
  end

  @doc "Non-blank, terminal-safe output lines."
  @spec output_lines(String.t()) :: [String.t()]
  def output_lines(output) do
    output
    |> MessageView.sanitize()
    |> String.split("\n", trim: false)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  @doc """
  Removes the leading whitespace every shown line shares, across both groups,
  so their relative indentation survives while the block sits at the rail.
  """
  @spec dedent([String.t()], [String.t()]) :: {[String.t()], [String.t()]}
  def dedent(head, tail) do
    indent =
      (head ++ tail)
      |> Enum.map(fn line -> hd(Regex.run(~r/\A[ \t]*/, line)) end)
      |> Enum.reduce(nil, fn
        prefix, nil -> prefix
        prefix, common -> common_prefix(prefix, common)
      end)

    case indent do
      empty when empty in [nil, ""] ->
        {head, tail}

      indent ->
        strip = &String.replace_prefix(&1, indent, "")
        {Enum.map(head, strip), Enum.map(tail, strip)}
    end
  end

  # Indentation is ASCII spaces and tabs, so a byte prefix is a character one.
  defp common_prefix(left, right),
    do: binary_part(left, 0, :binary.longest_common_prefix([left, right]))

  @doc """
  Observed duration: tenths of a second below ten seconds once settled, whole
  seconds while running or above that, minutes past a minute.
  """
  @spec elapsed(non_neg_integer(), atom()) :: String.t()
  def elapsed(ms, :completed) when ms < 10_000, do: tenths(ms)
  def elapsed(ms, :failed) when ms < 10_000, do: tenths(ms)

  def elapsed(ms, _status) do
    seconds = div(ms, 1_000)
    if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp tenths(ms), do: "#{div(ms, 1_000)}.#{div(rem(ms, 1_000), 100)}s"
end
