defmodule Tackle.Review.Diff do
  @moduledoc """
  The diff of a change: files, hunks, and numbered lines.

  This is the provider-neutral shape the review works on
  (`Tackle.Review.Units`, `Tackle.Review.Finding`, and the frontends).
  `Tackle.Review.Change` builds it from `GixEx` diffs; `parse/1` builds it
  from unified diff text, as produced by `git diff`, for patches from other
  sources and for test fixtures.

  Every line carries its kind and its absolute line numbers: removed lines
  have only an `old` number, added lines only a `new` number, and context
  lines both. A `\\ No newline at end of file` note is not a line of its own;
  it sets `no_newline: true` on the line it annotates.

  A file may carry the full text of both of its sides (`old_content` and
  `new_content`), which `Tackle.Review.FunctionContext` uses to show the
  functions around each change. Parsed patch text has no contents.

  `parse/1` understands Git's extended headers: renames and copies
  (`rename from` / `rename to`), new and deleted files, mode changes, and
  binary markers (`Binary files ... differ` or `GIT binary patch`). Paths may
  be C-quoted, as Git does for unusual characters. Plain `diff -u` output
  without a `diff --git` line is accepted too. Text before the first file
  header, such as warnings, is ignored.

  Hunk bodies are consumed by the line counts in their `@@` header, so content
  that happens to look like a header (a removed `-- comment` line printed as
  `--- comment`) is still read as content. A hunk that ends before its counts
  are satisfied is malformed.
  """

  defstruct files: []

  @typedoc "The kind of a diff line."
  @type kind :: :add | :remove | :context

  @typedoc """
  One diff line without its `+`/`-`/space marker.

  `old` is the line number in the old file and `new` in the new file; a side
  the line does not exist on is `nil`. `no_newline` is true when the line is
  the last of its file version and has no trailing newline.
  """
  @type line :: %{
          kind: kind(),
          old: pos_integer() | nil,
          new: pos_integer() | nil,
          text: String.t(),
          no_newline: boolean()
        }

  @typedoc "A hunk with its raw `@@` header, parsed ranges, and section heading."
  @type hunk :: %{
          header: String.t(),
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          new_start: non_neg_integer(),
          new_count: non_neg_integer(),
          section: String.t(),
          lines: [line()]
        }

  @typedoc """
  How a file changed. An `:unmerged` file has a merge conflict in the index
  and no hunks.
  """
  @type status :: :added | :deleted | :modified | :renamed | :copied | :unmerged

  @typedoc """
  One file of the diff.

  `path` is the new path, or the old path of a deleted file. `old_path` is
  `nil` for added files and equal to `path` for modified ones.
  `old_content` and `new_content` are the full text of each side, or `nil`
  when they were not loaded, the side does not exist, or the file is binary.
  """
  @type diff_file :: %{
          path: String.t(),
          old_path: String.t() | nil,
          status: status(),
          binary: boolean(),
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          hunks: [hunk()],
          old_content: binary() | nil,
          new_content: binary() | nil
        }

  @typedoc "A parsed diff."
  @type t :: %__MODULE__{files: [diff_file()]}

  @typedoc "Parse failure with the 1-based line number of the diff text."
  @type error :: {:malformed_diff, pos_integer(), String.t()}

  @hunk_header ~r/\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)\z/

  @doc """
  Parses unified diff text. The files have no contents.

  Empty text is an empty diff. Returns
  `{:error, {:malformed_diff, line_number, message}}` for an invalid hunk
  header or a truncated hunk.

      iex> {:ok, diff} = Tackle.Review.Diff.parse(\"""
      ...> diff --git a/a.txt b/a.txt
      ...> --- a/a.txt
      ...> +++ b/a.txt
      ...> @@ -1 +1 @@
      ...> -old
      ...> +new
      ...> \""")
      iex> [%{path: "a.txt", status: :modified, hunks: [%{lines: lines}]}] = diff.files
      iex> Enum.map(lines, &{&1.kind, &1.old, &1.new, &1.text})
      [{:remove, 1, nil, "old"}, {:add, nil, 1, "new"}]
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, error()}
  def parse(text) when is_binary(text) do
    lines = text |> split_lines() |> Enum.with_index(1)

    with {:ok, files} <- parse_preamble(lines, []) do
      {:ok, %__MODULE__{files: files}}
    end
  end

  defp split_lines(""), do: []

  defp split_lines(text) do
    lines = String.split(text, "\n")
    if String.ends_with?(text, "\n"), do: Enum.drop(lines, -1), else: lines
  end

  # Outside any file: skip everything until a file header.
  defp parse_preamble([], files), do: {:ok, Enum.reverse(files)}

  defp parse_preamble([{"diff --git " <> rest, _n} | tail], files),
    do: parse_file(tail, git_file(rest), files)

  defp parse_preamble([{"--- " <> _, _n}, {"+++ " <> _, _m} | _] = lines, files),
    do: parse_file(lines, new_file(nil, nil), files)

  defp parse_preamble([_line | tail], files), do: parse_preamble(tail, files)

  defp parse_file([], file, files), do: {:ok, Enum.reverse([finish(file) | files])}

  defp parse_file([{"diff --git " <> rest, _n} | tail], file, files),
    do: parse_file(tail, git_file(rest), [finish(file) | files])

  # In a plain diff, the next `---`/`+++` pair after a hunk starts a new file.
  defp parse_file(
         [{"--- " <> _, _n}, {"+++ " <> _, _m} | _] = lines,
         %{hunks: [_ | _]} = file,
         files
       ),
       do: parse_file(lines, new_file(nil, nil), [finish(file) | files])

  defp parse_file([{"@@" <> _ = header, n} | tail], file, files) do
    with {:ok, hunk, rest} <- parse_hunk(header, n, tail) do
      parse_file(rest, %{file | hunks: [hunk | file.hunks]}, files)
    end
  end

  defp parse_file([{line, _n} | tail], file, files),
    do: parse_file(tail, header_line(line, file), files)

  defp header_line("--- " <> path, file), do: %{file | old: header_path(path, "a/")}
  defp header_line("+++ " <> path, file), do: %{file | new: header_path(path, "b/")}
  defp header_line("new file mode " <> _, file), do: %{file | status: :added}
  defp header_line("deleted file mode " <> _, file), do: %{file | status: :deleted}
  defp header_line("rename from " <> path, file), do: %{file | old: unquote_path(path)}

  defp header_line("rename to " <> path, file),
    do: %{file | new: unquote_path(path), status: :renamed}

  defp header_line("copy from " <> path, file), do: %{file | old: unquote_path(path)}

  defp header_line("copy to " <> path, file),
    do: %{file | new: unquote_path(path), status: :copied}

  defp header_line("Binary files " <> _, file), do: %{file | binary: true}
  defp header_line("GIT binary patch" <> _, file), do: %{file | binary: true}
  # index, similarity, mode lines and binary patch data carry nothing we need.
  defp header_line(_line, file), do: file

  defp new_file(old, new),
    do: %{old: old, new: new, status: nil, binary: false, hunks: []}

  defp git_file(rest) do
    {old, new} = git_header_paths(rest)
    new_file(old, new)
  end

  defp finish(file) do
    old = if file.old == :null, do: nil, else: file.old
    new = if file.new == :null, do: nil, else: file.new
    hunks = Enum.reverse(file.hunks)
    status = status(file.status, file.old, file.new)
    lines = Enum.flat_map(hunks, & &1.lines)

    %{
      path: new || old,
      old_path: if(status == :added, do: nil, else: old || new),
      status: status,
      binary: file.binary,
      additions: Enum.count(lines, &(&1.kind == :add)),
      deletions: Enum.count(lines, &(&1.kind == :remove)),
      hunks: hunks,
      old_content: nil,
      new_content: nil
    }
  end

  defp status(status, _old, _new) when status != nil, do: status
  defp status(nil, :null, _new), do: :added
  defp status(nil, _old, :null), do: :deleted
  defp status(nil, old, new) when is_binary(old) and is_binary(new) and old != new, do: :renamed
  defp status(nil, _old, _new), do: :modified

  # `--- a/path`, `+++ b/path`, or `/dev/null`. Git appends a tab after a path
  # containing a space, and plain diffs append a tab and a timestamp.
  defp header_path(raw, prefix) do
    raw = raw |> String.split("\t", parts: 2) |> hd()

    case unquote_path(raw) do
      "/dev/null" -> :null
      path -> strip_prefix(path, prefix)
    end
  end

  defp strip_prefix(path, prefix) do
    if String.starts_with?(path, prefix),
      do: binary_part(path, byte_size(prefix), byte_size(path) - byte_size(prefix)),
      else: path
  end

  # The `diff --git a/old b/new` line is ambiguous when unquoted paths contain
  # spaces. Its paths are only used when no `---`/`+++` or rename lines follow
  # (binary files, mode changes), where both paths are equal.
  defp git_header_paths("\"" <> _ = rest) do
    case take_quoted(rest) do
      {:ok, old, " " <> new} -> {strip_prefix(old, "a/"), strip_prefix(unquote_path(new), "b/")}
      _other -> split_git_header(rest)
    end
  end

  defp git_header_paths(rest) do
    if String.ends_with?(rest, "\"") and String.contains?(rest, " \"") do
      [old, new] = split_last(rest, " \"")
      {strip_prefix(old, "a/"), strip_prefix(unquote_path("\"" <> new), "b/")}
    else
      split_git_header(rest)
    end
  end

  defp split_git_header(rest) do
    half = div(byte_size(rest) - 1, 2)

    with true <- byte_size(rest) >= 5 and rem(byte_size(rest), 2) == 1,
         <<old::binary-size(^half), " ", new::binary-size(^half)>> <- rest,
         "a/" <> old_path <- old,
         "b/" <> ^old_path <- new do
      {old_path, old_path}
    else
      _other ->
        case :binary.split(rest, " b/") do
          [old, new] -> {strip_prefix(old, "a/"), new}
          [single] -> {strip_prefix(single, "a/"), strip_prefix(single, "a/")}
        end
    end
  end

  defp split_last(string, separator) do
    parts = String.split(string, separator)
    [parts |> Enum.drop(-1) |> Enum.join(separator), List.last(parts)]
  end

  defp unquote_path("\"" <> _ = quoted) do
    case take_quoted(quoted) do
      {:ok, path, ""} -> path
      _other -> quoted
    end
  end

  defp unquote_path(path), do: path

  # Git quotes paths as C strings with octal escapes for non-ASCII bytes.
  defp take_quoted("\"" <> rest), do: take_quoted(rest, [])
  defp take_quoted(_other), do: :error

  defp take_quoted("", _acc), do: :error
  defp take_quoted("\"" <> rest, acc), do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp take_quoted(<<"\\", a, b, c, rest::binary>>, acc)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
       do: take_quoted(rest, [(a - ?0) * 64 + (b - ?0) * 8 + (c - ?0) | acc])

  defp take_quoted(<<"\\", char, rest::binary>>, acc),
    do: take_quoted(rest, [escape(char) | acc])

  defp take_quoted(<<char, rest::binary>>, acc), do: take_quoted(rest, [char | acc])

  defp escape(?n), do: ?\n
  defp escape(?t), do: ?\t
  defp escape(?r), do: ?\r
  defp escape(?a), do: 7
  defp escape(?b), do: ?\b
  defp escape(?f), do: ?\f
  defp escape(?v), do: ?\v
  defp escape(char), do: char

  defp parse_hunk(header, n, lines) do
    case Regex.run(@hunk_header, header, capture: :all_but_first) do
      [old_start, old_count, new_start, new_count, section] ->
        hunk = %{
          header: header,
          old_start: String.to_integer(old_start),
          old_count: count(old_count),
          new_start: String.to_integer(new_start),
          new_count: count(new_count),
          section: section,
          lines: []
        }

        position = {hunk.old_start, hunk.new_start}

        with {:ok, body, rest} <-
               hunk_body(lines, hunk.old_count, hunk.new_count, position, n, []) do
          {:ok, %{hunk | lines: body}, rest}
        end

      nil ->
        {:error, {:malformed_diff, n, "invalid hunk header"}}
    end
  end

  # An omitted count means one line.
  defp count(""), do: 1
  defp count(digits), do: String.to_integer(digits)

  defp hunk_body([{"\\" <> _, _n} | tail], old_left, new_left, position, start, acc),
    do: hunk_body(tail, old_left, new_left, position, start, mark_no_newline(acc))

  defp hunk_body(lines, 0, 0, _position, _start, acc), do: {:ok, Enum.reverse(acc), lines}

  defp hunk_body([{line, n} | tail], old_left, new_left, {old, new}, start, acc) do
    case {line, old_left > 0, new_left > 0} do
      {"-" <> text, true, _new?} ->
        line = line(:remove, old, nil, text)
        hunk_body(tail, old_left - 1, new_left, {old + 1, new}, start, [line | acc])

      {"+" <> text, _old?, true} ->
        line = line(:add, nil, new, text)
        hunk_body(tail, old_left, new_left - 1, {old, new + 1}, start, [line | acc])

      {" " <> text, true, true} ->
        line = line(:context, old, new, text)
        hunk_body(tail, old_left - 1, new_left - 1, {old + 1, new + 1}, start, [line | acc])

      # Some tools strip the trailing space of an empty context line.
      {"", true, true} ->
        line = line(:context, old, new, "")
        hunk_body(tail, old_left - 1, new_left - 1, {old + 1, new + 1}, start, [line | acc])

      _other ->
        {:error, {:malformed_diff, n, "unexpected line in hunk"}}
    end
  end

  defp hunk_body([], _old_left, _new_left, _position, start, _acc),
    do: {:error, {:malformed_diff, start, "hunk ends before its line counts"}}

  defp line(kind, old, new, text),
    do: %{kind: kind, old: old, new: new, text: text, no_newline: false}

  defp mark_no_newline([last | rest]), do: [%{last | no_newline: true} | rest]
  defp mark_no_newline([]), do: []
end
