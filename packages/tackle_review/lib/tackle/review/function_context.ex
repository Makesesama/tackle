defmodule Tackle.Review.FunctionContext do
  @moduledoc """
  Expands the hunks of a diff file to the functions they change, as
  `git diff --function-context` (`-W`) does, using the file's full contents.

  A function's *header* is the paragraph directly above its function line
  (the non-blank lines up to a blank line or another function line): its
  comments, attributes, decorators, or documentation. A paragraph whose
  first line is indented deeper than the function line (allowing one column
  for `*` comment continuations) is the end of a function body instead and
  not a header.

  For every hunk, the region shown reaches

    * up to the header of the function the hunk's first change belongs to:
      the function whose function line or header holds the change, or else
      the nearest function line above it; the top of the file without one;
    * down to the end of the function the hunk's last change belongs to:
      just before the next function line and its header, without the blank
      lines in front of them, or to the end of the file.

  Blank changed lines at either end of a hunk do not choose the function, so
  a hunk that adds a blank line and then a function expands to that
  function. A region always includes the hunk's own context lines. Regions
  that overlap, touch, or are separated only by blank lines are merged, so
  two changes in one function share one region.

  Git's `-W` differs in ways that matter for review: it takes every
  non-blank line above a function line as part of it but ends a function
  right before the next function line, so it often shows the next
  function's documentation; it gives a change in a function's
  documentation, or an added documented function, the function above; and
  it searches function lines in the old file only.

  Function lines are recognised per language, chosen by file name, with
  Git's built-in `userdiff` funcname patterns (`elixir`, `rust`, `python`,
  `golang`, `java`, `kotlin`, `csharp`, `cpp`, `ruby`, `php`, `bash`, `css`,
  `html`, `markdown`) and a pattern of our own for JavaScript and
  TypeScript, which Git lacks. A language is a list of patterns tried in
  order; the first that matches decides, and a negated pattern (`!` in
  Git) that matches means "not a function line". Files of other languages
  use Git's default rule: a line starting with a letter, `_`, or `$`.

  Deviations from Git's patterns, to fit how the languages are written:
  Elixir also recognises `defmacrop`, `defguard`, `defguardp`, and
  `defdelegate`, and Java's negated keywords only match whole words, so a
  method returning `double` or named `format` is still a function line.
  Lines longer than 1,000 bytes are never function lines.

  The unchanged lines between and around hunks come from the file's
  `new_content`. A file without the contents it needs (such as parsed patch
  text) keeps its plain hunks; a deleted file needs none, as its one hunk
  holds every line.
  """

  alias Tackle.Review.Diff

  @max_line_bytes 1_000

  @typedoc "A language's compiled function-line patterns."
  @opaque patterns :: [{:match | :negate, Regex.t()}] | :default

  @typedoc "A language with built-in function-line patterns."
  @type language ::
          :bash
          | :cpp
          | :csharp
          | :css
          | :elixir
          | :golang
          | :html
          | :java
          | :javascript
          | :kotlin
          | :markdown
          | :php
          | :python
          | :ruby
          | :rust

  @extensions %{
    bash: ~w(.sh .bash),
    cpp: ~w(.c .h .cc .cpp .cxx .c++ .hh .hpp .hxx .h++ .ino),
    csharp: ~w(.cs),
    css: ~w(.css .scss .less),
    elixir: ~w(.ex .exs),
    golang: ~w(.go),
    html: ~w(.html .htm .xhtml),
    java: ~w(.java),
    javascript: ~w(.js .jsx .mjs .cjs .ts .tsx .mts .cts),
    kotlin: ~w(.kt .kts),
    markdown: ~w(.md .markdown),
    php: ~w(.php),
    python: ~w(.py .pyi),
    ruby: ~w(.rb .rake .gemspec),
    rust: ~w(.rs)
  }

  @file_names %{"Rakefile" => :ruby, "Gemfile" => :ruby}

  @language_by_extension for {language, extensions} <- @extensions,
                             extension <- extensions,
                             into: %{},
                             do: {extension, language}

  # Git's patterns are POSIX extended regular expressions; these are their
  # PCRE translations. A `]` or `[` inside a bracket expression is escaped,
  # and a backslash inside one, which POSIX takes literally, is doubled.
  # Patterns are matched against bytes, without the `unicode` flag, as Git
  # does; `[[:alnum:]]` and friends are therefore ASCII classes.
  @csharp_name ~S"[\]\[[:alnum:]@_.](<[\]\[[:alnum:]@_, \t<>]+>)?"

  @sources %{
    bash: [
      match:
        ~S"^[ \t]*((([a-zA-Z_][a-zA-Z0-9_]*[ \t]*\([ \t]*\))|(function[ \t]+[a-zA-Z_][a-zA-Z0-9_]*(([ \t]*\([ \t]*\))|([ \t]+)))).*$)"
    ],
    cpp: [
      negate: ~S"^[ \t]*[A-Za-z_][A-Za-z_0-9]*:[[:space:]]*($|/[/*])",
      match: ~S"^((::[[:space:]]*)?[A-Za-z_].*)$"
    ],
    csharp: [
      negate:
        ~S"(^|[ \t]+)(do|while|for|foreach|if|else|new|default|return|switch|case|throw|catch|using|lock|fixed)([ \t(]+|$)",
      match: "^[ \\t]*((#{@csharp_name})+([ \\t]+(#{@csharp_name})+)+[ \\t]*\\([^;]*)$",
      match: "^[ \\t]*((#{@csharp_name})+([ \\t]+(#{@csharp_name})+)+[^;=:,()]*)$",
      match:
        ~S"^[ \t]*(((static|public|internal|private|protected|new|unsafe|sealed|abstract|partial)[ \t]+)*(class|enum|interface|struct|record)[ \t]+.*)$",
      match: ~S"^[ \t]*(namespace[ \t]+.*)$"
    ],
    css: [
      negate: ~S"[:;][[:space:]]*$",
      match: ~S"^[:\[@.#]?[_a-z0-9].*$"
    ],
    elixir: [
      match:
        ~S"^[ \t]*((def(macro|macrop|module|impl|protocol|p|guard|guardp|delegate)?|test)[ \t].*)$"
    ],
    golang: [
      match: ~S"^[ \t]*(func[ \t]*.*(\{[ \t]*)?)",
      match: ~S"^[ \t]*(type[ \t].*(struct|interface)[ \t]*(\{[ \t]*)?)"
    ],
    html: [match: ~S"^[ \t]*(<[Hh][1-6]([ \t].*)?>.*)$"],
    java: [
      negate:
        ~S"^[ \t]*(catch|do|for|if|instanceof|new|return|switch|throw|while)([^A-Za-z0-9_$]|$)",
      match: ~S"^[ \t]*(([a-z-]+[ \t]+)*(class|enum|interface|record)[ \t]+.*)$",
      match:
        ~S"^[ \t]*(([A-Za-z_<>&][\]\[?&<>.,A-Za-z_0-9]*[ \t]+)+[A-Za-z_][A-Za-z_0-9]*[ \t]*\([^;]*)$"
    ],
    javascript: [
      negate:
        ~S"^[ \t]*(if|else|for|while|do|switch|case|catch|return|throw|try|finally|with|new|await|yield|typeof|delete|void)([^A-Za-z0-9_$]|$)",
      # Function declarations and expressions, including generators.
      match:
        ~S"^[ \t]*((export[ \t]+)?(default[ \t]+)?(declare[ \t]+)?(async[ \t]+)?function([ \t]*\*)?([ \t]|\().*)$",
      # Classes and TypeScript declarations.
      match:
        ~S"^[ \t]*((export[ \t]+)?(default[ \t]+)?(declare[ \t]+)?(abstract[ \t]+)?(const[ \t]+)?(class|interface|enum|namespace|module)[ \t]+[A-Za-z_$].*)$",
      match:
        ~S"^[ \t]*((export[ \t]+)?(declare[ \t]+)?type[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[^=]*=.*)$",
      # Functions bound to variables or class fields.
      match:
        ~S"^[ \t]*((export[ \t]+)?(const|let|var)[ \t]+|((public|private|protected|static|readonly|override)[ \t]+)*)[#A-Za-z_$][A-Za-z0-9_$]*[ \t]*(:[^=]*)?=[ \t]*(async[ \t]+)?(function([ \t]|\(|\*)|(\([^)]*\)|[A-Za-z_$][A-Za-z0-9_$]*)[ \t]*(:[^=]*)?=>)",
      # Methods (also callbacks such as `it("works", () => {`): a name, a
      # parameter list, and an opening brace at the end of the line.
      match:
        ~S"^[ \t]*((public|private|protected|static|async|override|readonly|abstract|get|set)[ \t]+)*\*?[#A-Za-z_$][A-Za-z0-9_$]*[ \t]*(<[^>]*>)?[ \t]*\([^;]*\)[^;]*\{[ \t]*$"
    ],
    kotlin: [match: ~S"^[ \t]*(([a-z]+[ \t]+)*(fun|class|interface)[ \t]+.*)$"],
    markdown: [match: ~S"^ {0,3}#{1,6}[ \t].*"],
    php: [
      match: ~S"^[\t ]*(((public|protected|private|static|abstract|final)[\t ]+)*function.*)$",
      match: ~S"^[\t ]*((((final|abstract)[\t ]+)?class|enum|interface|trait).*)$"
    ],
    python: [match: ~S"^[ \t]*((class|(async[ \t]+)?def)[ \t].*)$"],
    ruby: [match: ~S"^[ \t]*((class|module|def)[ \t].*)$"],
    rust: [
      match:
        ~S'^[\t ]*((pub(\([^\\)]+\))?[\t ]+)?((async|const|unsafe|extern([\t ]+"[^"]+"))[\t ]+)?(struct|enum|union|mod|trait|fn|impl|macro_rules!)[< \t]+[^;]*)$'
    ]
  }

  # Git's case-insensitive patterns (`IPATTERN`).
  @caseless [:css]

  @doc "The languages with built-in patterns."
  @spec languages() :: [language()]
  def languages, do: @sources |> Map.keys() |> Enum.sort()

  @doc """
  The language of `path`, by file name and extension, or `nil` when it has no
  built-in patterns.

      iex> Tackle.Review.FunctionContext.language("lib/tackle/review.ex")
      :elixir
      iex> Tackle.Review.FunctionContext.language("notes.txt")
      nil
  """
  @spec language(Path.t()) :: language() | nil
  def language(path) do
    Map.get(@file_names, Path.basename(path)) ||
      Map.get(@language_by_extension, path |> Path.extname() |> String.downcase())
  end

  @doc """
  Compiles the function-line patterns for `path`'s language, or Git's
  default rule for a path without one.
  """
  @spec patterns(Path.t()) :: patterns()
  def patterns(path) do
    case language(path) do
      nil -> :default
      language -> compile(language)
    end
  end

  @doc """
  Whether `line` starts a function according to `patterns`.

      iex> patterns = Tackle.Review.FunctionContext.patterns("a.ex")
      iex> Tackle.Review.FunctionContext.function_line?(patterns, "  defp run(x) do")
      true
      iex> Tackle.Review.FunctionContext.function_line?(patterns, "    run(x)")
      false
  """
  @spec function_line?(patterns(), binary()) :: boolean()
  def function_line?(_patterns, line) when byte_size(line) > @max_line_bytes, do: false

  def function_line?(:default, line),
    do: match?(<<c, _::binary>> when c in ?a..?z or c in ?A..?Z or c in [?_, ?$], line)

  def function_line?(patterns, line) do
    line = String.trim_trailing(line, "\r")

    case Enum.find(patterns, fn {_kind, regex} -> Regex.match?(regex, line) end) do
      {:match, _regex} -> true
      _negated_or_none -> false
    end
  end

  @doc """
  The lines to show for `file`: its hunks expanded to the enclosing
  functions (see the module documentation), one list of lines per region,
  in file order.

  A file without the contents a region needs keeps its plain hunks.
  """
  @spec regions(Diff.diff_file()) :: [[Diff.line()]]
  def regions(%{hunks: []}), do: []

  def regions(%{hunks: hunks} = file) do
    case full_lines(file) do
      {:ok, lines, spans} -> expand(file.path, List.to_tuple(lines), spans)
      :error -> Enum.map(hunks, & &1.lines)
    end
  end

  ## Patterns

  defp compile(language) do
    flags = if language in @caseless, do: "i", else: ""

    Enum.map(Map.fetch!(@sources, language), fn {kind, source} ->
      {kind, Regex.compile!(source, flags)}
    end)
  end

  ## Full file

  # Every line of the file as diff lines: the hunks' lines and, between
  # them, the unchanged lines of the new side as context. Also returns the
  # index span of each hunk in that list. Lines are accumulated in reverse
  # with their count.
  defp full_lines(%{hunks: hunks} = file) do
    content = file_lines(file.new_content)

    {acc, count, spans, cursor} =
      Enum.reduce(hunks, {[], 0, [], {1, 1}}, fn hunk, {acc, count, spans, cursor} ->
        {acc, count} = gap({acc, count}, content, cursor, first_new(hunk) - 1)
        size = length(hunk.lines)
        span = {count, count + size - 1}
        {Enum.reverse(hunk.lines, acc), count + size, [span | spans], next(hunk)}
      end)

    {acc, _count} = tail({acc, count}, content, cursor, file.new_content)
    {:ok, Enum.reverse(acc), Enum.reverse(spans)}
  catch
    :missing_content -> :error
  end

  defp file_lines(nil), do: nil

  defp file_lines(content) do
    lines = String.split(content, "\n")
    lines = if String.ends_with?(content, "\n"), do: Enum.drop(lines, -1), else: lines
    List.to_tuple(lines)
  end

  defp first_new(%{new_count: 0, new_start: start}), do: start + 1
  defp first_new(%{new_start: start}), do: start

  # The old and new numbers of the first line after a hunk. A side without
  # lines starts at the line before the hunk, as in the `@@` header.
  defp next(hunk),
    do: {after_side(hunk.old_start, hunk.old_count), after_side(hunk.new_start, hunk.new_count)}

  defp after_side(start, 0), do: start + 1
  defp after_side(start, count), do: start + count

  # Context lines from the cursor up to new line `last`.
  defp gap(acc, _content, {_old, new}, last) when new > last, do: acc
  defp gap(_acc, nil, _cursor, _last), do: throw(:missing_content)

  defp gap(_acc, content, _cursor, last) when last > tuple_size(content),
    do: throw(:missing_content)

  defp gap({acc, count}, content, {old, new}, last) do
    acc =
      Enum.reduce(new..last//1, acc, fn number, acc ->
        [context(elem(content, number - 1), old + number - new, number) | acc]
      end)

    {acc, count + last - new + 1}
  end

  # Context lines after the last hunk. Without contents, the file is taken to
  # end with it.
  defp tail(acc, nil, _cursor, _content), do: acc

  defp tail(acc, lines, {_old, new} = cursor, content) do
    case gap(acc, lines, cursor, tuple_size(lines)) do
      {[last | rest], count} when new <= tuple_size(lines) ->
        {[%{last | no_newline: not String.ends_with?(content, "\n")} | rest], count}

      acc ->
        acc
    end
  end

  defp context(text, old, new),
    do: %{kind: :context, old: old, new: new, text: text, no_newline: false}

  ## Expansion

  defp expand(path, lines, spans) do
    patterns = patterns(path)

    # Each line is matched once; the expansion looks lines up many times.
    flags =
      lines
      |> Tuple.to_list()
      |> Enum.map(&function_line?(patterns, &1.text))
      |> List.to_tuple()

    file = %{
      lines: lines,
      last: tuple_size(lines) - 1,
      function?: &elem(flags, &1)
    }

    spans
    |> Enum.map(fn {first, last} ->
      {from, to} = anchors(file, first, last)
      start = header_start(file, owner(file, from) || function_above(file, from))
      {min(first, start), max(last, function_end(file, owner(file, to) || to, to))}
    end)
    |> merge(file)
    |> Enum.map(fn {start, stop} -> for index <- start..stop, do: elem(lines, index) end)
  end

  # The first and last non-blank changes of a hunk, or its first and last
  # changes when all of them are blank.
  defp anchors(file, first, last) do
    changes = for index <- first..last, elem(file.lines, index).kind != :context, do: index

    case Enum.reject(changes, &blank?(file, &1)) do
      [] -> {List.first(changes), List.last(changes)}
      non_blank -> {List.first(non_blank), List.last(non_blank)}
    end
  end

  # The function whose function line or header holds `index`, or `nil`.
  defp owner(file, index) do
    with function when is_integer(function) <- function_below(file, index),
         true <- header_start(file, function) <= index do
      function
    else
      _none -> nil
    end
  end

  # The function line at `index` or below it in the same paragraph.
  defp function_below(file, index) do
    cond do
      index > file.last or blank?(file, index) -> nil
      file.function?.(index) -> index
      true -> function_below(file, index + 1)
    end
  end

  # The nearest function line at or above `index`; `nil` without one.
  defp function_above(file, index), do: Enum.find(index..0//-1, file.function?)

  # Where the function at `index` starts with its header: the paragraph
  # directly above the function line (non-blank lines up to a blank line or
  # another function line), when the paragraph's first line is not indented
  # deeper than the function line, allowing one column for `*` comment
  # continuations. A deeper first line is the end of a function body. The
  # top of the file when there is no function.
  defp header_start(_file, nil), do: 0

  defp header_start(file, index) do
    first = paragraph_start(file, index)

    if first < index and indent(file, first) <= indent(file, index) + 1,
      do: first,
      else: index
  end

  defp paragraph_start(file, index) do
    above = index - 1

    if above < 0 or blank?(file, above) or file.function?.(above),
      do: index,
      else: paragraph_start(file, above)
  end

  # The last line of the function at or around `index`: the line before
  # the next function and its header, without blank lines, but not before
  # `floor`; the end of the file without a next function.
  defp function_end(file, index, floor) do
    stop =
      case Enum.find((index + 1)..file.last//1, file.function?) do
        nil -> file.last
        next -> header_start(file, next) - 1
      end

    trim_blank(file, max(stop, floor), floor)
  end

  defp trim_blank(file, stop, floor) do
    if stop > floor and blank?(file, stop), do: trim_blank(file, stop - 1, floor), else: stop
  end

  defp blank?(file, index), do: String.trim(elem(file.lines, index).text) == ""

  # Leading whitespace width, with tabs as eight columns.
  defp indent(file, index) do
    file.lines
    |> elem(index)
    |> Map.fetch!(:text)
    |> :binary.bin_to_list()
    |> Enum.reduce_while(0, fn
      ?\s, width -> {:cont, width + 1}
      ?\t, width -> {:cont, width + 8}
      _char, width -> {:halt, width}
    end)
  end

  # Merges regions that overlap, touch, or are only separated by blank
  # lines.
  defp merge(spans, file) do
    spans
    |> Enum.sort()
    |> Enum.reduce([], fn
      {start, stop}, [{prev_start, prev_stop} | rest] = acc ->
        if Enum.all?((prev_stop + 1)..(start - 1)//1, &blank?(file, &1)),
          do: [{prev_start, max(stop, prev_stop)} | rest],
          else: [{start, stop} | acc]

      span, [] ->
        [span]
    end)
    |> Enum.reverse()
  end
end
