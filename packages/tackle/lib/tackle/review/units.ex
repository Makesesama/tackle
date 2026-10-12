defmodule Tackle.Review.Units do
  @moduledoc """
  Splits a `Tackle.Review.Change` into small review units.

  Small units with bounded context are reviewed more accurately than whole
  diffs, so `split/2`:

    1. skips files that are not worth a line-by-line review: lock files,
       vendored and dependency directories, generated code, binary files,
       deleted files, files without textual changes (pure renames, mode
       changes), and files matching the caller's `:exclude` globs (see
       `Tackle.Review.Glob`);
    2. expands each hunk to its enclosing function using the change's
       function-context diff (`git diff -W`). When a function would add more
       than `max(context_ratio × changed lines, min_context)` lines of
       context, the hunk keeps only `fallback_context` lines around each
       change instead;
    3. packs the pieces of one file into units of at most
       `max_changed_lines` changed lines, splitting larger pieces;
    4. renders every unit with absolute line numbers: `[+ 42]` for an added
       line (new numbering), `[- 17]` for a removed line (old numbering), and
       `[  43]` for context (new numbering);
    5. adds one change-level unit, first, with the mode, commits, file list,
       statistics, and skipped files.

  An empty change has no units.

  Git's default function detection matches lines that start with a letter,
  `_`, or `$`. For languages that indent definitions (such as Elixir, without
  a `diff=elixir` attribute) a "function" can be a whole module, which the
  context cap then reduces to the fallback context.
  """

  alias Tackle.Review.{Change, Diff, Glob}

  @builtin_excludes [
    lock_file: [
      "*.lock",
      "package-lock.json",
      "npm-shrinkwrap.json",
      "pnpm-lock.yaml",
      "bun.lockb",
      "go.sum"
    ],
    vendored: [
      "deps/",
      "_build/",
      "vendor/",
      "node_modules/",
      "third_party/",
      ".nix-mix/",
      ".nix-hex/"
    ],
    generated: [
      "*.min.js",
      "*.min.css",
      "*.map",
      "*.pb.go",
      "*_pb2.py",
      "*_pb2_grpc.py",
      "*.generated.*"
    ]
  ]

  @defaults [max_changed_lines: 50, context_ratio: 4, min_context: 20, fallback_context: 3]
  @max_commit_body 1_000

  @typedoc "Line ranges per side of the diff."
  @type side_ranges :: %{old: [Range.t()], new: [Range.t()]}

  @typedoc """
  A review unit.

  Code units (`kind: :code`) cover part of one file: `side_ranges` are the
  lines shown, `changed_ranges` the added (`new`) and removed (`old`) lines,
  and `lines` the diff lines, in order. The change-level unit
  (`kind: :change`, `id: "change"`) has no path, ranges, or lines;
  its `changed_lines` is the whole change's total.
  """
  @type unit :: %{
          id: String.t(),
          kind: :code | :change,
          path: String.t() | nil,
          old_path: String.t() | nil,
          status: Diff.status() | nil,
          changed_lines: non_neg_integer(),
          side_ranges: side_ranges(),
          changed_ranges: side_ranges(),
          lines: [Diff.line()],
          rendered: String.t()
        }

  @typedoc "Why a file was not split into code units."
  @type skip_reason ::
          :excluded | :lock_file | :vendored | :generated | :binary | :deleted | :no_content

  @typedoc "A file without code units."
  @type skipped :: %{path: String.t(), reason: skip_reason()}

  @typedoc "Units, with the change-level unit first, and skipped files in diff order."
  @type result :: %{units: [unit()], skipped: [skipped()]}

  @typedoc """
  Split options:

    * `:exclude` - extra globs of files to skip (default `[]`);
    * `:max_changed_lines` - changed lines per unit (default 50);
    * `:context_ratio` - context allowed per changed line before a function
      is not shown whole (default 4);
    * `:min_context` - context always allowed for a whole function
      (default 20);
    * `:fallback_context` - context lines around each change when the
      function is too large (default 3).
  """
  @type option ::
          {:exclude, [String.t()]}
          | {:max_changed_lines, pos_integer()}
          | {:context_ratio, non_neg_integer()}
          | {:min_context, non_neg_integer()}
          | {:fallback_context, non_neg_integer()}

  @doc """
  Builds the review units of a change (see the module documentation).

  Returns `{:error, {:invalid_glob, pattern, message}}` for an invalid
  `:exclude` glob. Raises `ArgumentError` for invalid numeric options.
  """
  @spec split(Change.t(), [option()]) ::
          {:ok, result()} | {:error, {:invalid_glob, String.t(), String.t()}}
  def split(%Change{} = change, opts \\ []) do
    config = config(opts)

    with {:ok, user_globs} <- Glob.compile_all(Keyword.get(opts, :exclude, [])) do
      excludes = [{:excluded, user_globs} | builtin_globs()]
      context_files = Map.new(change.context_diff.files, &{{&1.old_path, &1.path}, &1})

      {code_units, skipped} =
        Enum.reduce(
          change.diff.files,
          {[], []},
          &add_file(&1, &2, excludes, context_files, config)
        )

      code_units = code_units |> Enum.reverse() |> List.flatten()
      skipped = Enum.reverse(skipped)

      units =
        if change.diff.files == [],
          do: [],
          else: [change_unit(change, skipped) | code_units]

      {:ok, %{units: units, skipped: skipped}}
    end
  end

  @doc "Describes a skip reason for people."
  @spec describe_skip(skip_reason()) :: String.t()
  def describe_skip(:excluded), do: "excluded"
  def describe_skip(:lock_file), do: "lock file"
  def describe_skip(:vendored), do: "vendored or dependency code"
  def describe_skip(:generated), do: "generated code"
  def describe_skip(:binary), do: "binary file"
  def describe_skip(:deleted), do: "deleted file"
  def describe_skip(:no_content), do: "no textual changes"

  defp config(opts) do
    Map.new(@defaults, fn {key, default} ->
      value = Keyword.get(opts, key, default)
      minimum = if key == :max_changed_lines, do: 1, else: 0

      unless is_integer(value) and value >= minimum do
        raise ArgumentError,
              "#{inspect(key)} must be an integer >= #{minimum}, got: #{inspect(value)}"
      end

      {key, value}
    end)
  end

  # The built-in patterns are constant and covered by tests.
  defp builtin_globs do
    Enum.map(@builtin_excludes, fn {reason, patterns} ->
      {:ok, globs} = Glob.compile_all(patterns)
      {reason, globs}
    end)
  end

  defp add_file(file, {units, skipped}, excludes, context_files, config) do
    case skip_reason(file, excludes) do
      nil -> {[file_units(file, context_files, config) | units], skipped}
      reason -> {units, [%{path: file.path, reason: reason} | skipped]}
    end
  end

  defp skip_reason(file, excludes) do
    Enum.find_value(excludes, fn {reason, globs} ->
      if Glob.match?(globs, file.path), do: reason
    end) ||
      cond do
        file.binary -> :binary
        file.status == :deleted -> :deleted
        file.hunks == [] -> :no_content
        true -> nil
      end
  end

  ## Code units

  defp file_units(file, context_files, config) do
    file
    |> regions(Map.get(context_files, {file.old_path, file.path}))
    |> Enum.flat_map(&fit_context(&1, config))
    |> Enum.flat_map(&split_segment(&1, config.max_changed_lines))
    |> pack(config.max_changed_lines)
    |> Enum.with_index(1)
    |> Enum.map(fn {segments, index} -> code_unit(file, segments, index) end)
  end

  # Function-context hunks replace the plain ones only when they describe the
  # same changes; otherwise the plain hunks are used as they are.
  defp regions(file, %{additions: additions, deletions: deletions} = context_file)
       when additions == file.additions and deletions == file.deletions,
       do: Enum.map(context_file.hunks, & &1.lines)

  defp regions(file, _context_file), do: Enum.map(file.hunks, & &1.lines)

  defp fit_context(lines, config) do
    changed = changed_count(lines)
    cap = max(config.context_ratio * changed, config.min_context)

    if length(lines) - changed <= cap,
      do: [lines],
      else: trim(lines, config.fallback_context)
  end

  # Keeps the lines within `n` lines of a change, as contiguous segments.
  defp trim(lines, n) do
    before = distances(lines)
    after_ = lines |> Enum.reverse() |> distances() |> Enum.reverse()

    lines
    |> Enum.zip(Enum.zip_with(before, after_, &min/2))
    |> Enum.chunk_by(fn {_line, distance} -> distance <= n end)
    |> Enum.filter(fn [{_line, distance} | _] -> distance <= n end)
    |> Enum.map(fn segment -> Enum.map(segment, &elem(&1, 0)) end)
  end

  # Distance of each line to the closest preceding change (0 for a change).
  defp distances(lines) do
    {distances, _last} =
      Enum.map_reduce(lines, :infinity, fn line, last ->
        distance = if changed?(line), do: 0, else: increment(last)
        {distance, distance}
      end)

    distances
  end

  defp increment(:infinity), do: :infinity
  defp increment(distance), do: distance + 1

  # Splits a segment into evenly sized parts of at most `max` changed lines.
  # A part ends right before the change that would exceed its share, so the
  # context between two parts stays with the earlier one.
  defp split_segment(lines, max) do
    changed = changed_count(lines)

    if changed <= max do
      [lines]
    else
      share = ceil_div(changed, ceil_div(changed, max))

      {parts, current, _count} = Enum.reduce(lines, {[], [], 0}, &add_to_part(&1, &2, share))
      Enum.reverse([Enum.reverse(current) | parts])
    end
  end

  defp add_to_part(line, {parts, current, count}, share) do
    cond do
      changed?(line) and count == share -> {[Enum.reverse(current) | parts], [line], 1}
      changed?(line) -> {parts, [line | current], count + 1}
      true -> {parts, [line | current], count}
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  # Groups consecutive segments of a file while they fit in one unit.
  defp pack(segments, max) do
    {groups, current, _count} =
      Enum.reduce(segments, {[], [], 0}, fn segment, {groups, current, count} ->
        changed = changed_count(segment)

        if current != [] and count + changed > max,
          do: {[Enum.reverse(current) | groups], [segment], changed},
          else: {groups, [segment | current], count + changed}
      end)

    groups = if current == [], do: groups, else: [Enum.reverse(current) | groups]
    Enum.reverse(groups)
  end

  defp code_unit(file, segments, index) do
    lines = Enum.concat(segments)

    %{
      id: "#{file.path}##{index}",
      kind: :code,
      path: file.path,
      old_path: file.old_path,
      status: file.status,
      changed_lines: changed_count(lines),
      side_ranges: %{
        old: lines |> Enum.map(& &1.old) |> ranges(),
        new: lines |> Enum.map(& &1.new) |> ranges()
      },
      changed_ranges: %{
        old: for(%{kind: :remove, old: old} <- lines, do: old) |> ranges(),
        new: for(%{kind: :add, new: new} <- lines, do: new) |> ranges()
      },
      lines: lines,
      rendered: render(file, segments, lines)
    }
  end

  defp changed?(%{kind: kind}), do: kind != :context
  defp changed_count(lines), do: Enum.count(lines, &changed?/1)

  defp ranges(numbers) do
    numbers
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> Enum.dedup()
    |> Enum.chunk_while(
      nil,
      fn
        number, nil -> {:cont, number..number}
        number, first..last//_ when number == last + 1 -> {:cont, first..number}
        number, range -> {:cont, range, number..number}
      end,
      fn
        nil -> {:cont, nil}
        range -> {:cont, range, nil}
      end
    )
  end

  ## Rendering

  defp render(file, segments, lines) do
    width =
      lines
      |> Enum.flat_map(&[&1.old, &1.new])
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)
      |> Integer.to_string()
      |> byte_size()

    body =
      Enum.map_join(segments, "\n...\n", fn segment ->
        Enum.map_join(segment, "\n", &render_line(&1, width))
      end)

    "File: #{file.path}#{status_note(file)}\n\n#{body}\n"
  end

  defp render_line(line, width) do
    {marker, number} =
      case line.kind do
        :add -> {"+", line.new}
        :remove -> {"-", line.old}
        :context -> {" ", line.new}
      end

    rendered =
      "[#{marker} #{String.pad_leading(Integer.to_string(number), width)}] " <>
        String.replace_invalid(line.text)

    if line.no_newline, do: rendered <> "\n\\ No newline at end of file", else: rendered
  end

  defp status_note(%{status: :added}), do: " (new file)"
  defp status_note(%{status: :renamed, old_path: old}), do: " (renamed from #{old})"
  defp status_note(%{status: :copied, old_path: old}), do: " (copied from #{old})"
  defp status_note(_file), do: ""

  ## Change-level unit

  defp change_unit(change, skipped) do
    files = change.diff.files
    additions = files |> Enum.map(& &1.additions) |> Enum.sum()
    deletions = files |> Enum.map(& &1.deletions) |> Enum.sum()

    sections = [
      "Change: #{describe_change(change)}\n" <>
        "Files changed: #{length(files)} (+#{additions} -#{deletions})",
      commits_section(change.commits),
      "Files:\n" <> Enum.map_join(files, "\n", &file_entry/1),
      skipped_section(skipped)
    ]

    %{
      id: "change",
      kind: :change,
      path: nil,
      old_path: nil,
      status: nil,
      changed_lines: additions + deletions,
      side_ranges: %{old: [], new: []},
      changed_ranges: %{old: [], new: []},
      lines: [],
      rendered: (sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")) <> "\n"
    }
  end

  defp describe_change(%Change{mode: :branch} = change),
    do:
      "the current branch against #{change.base_ref} " <>
        "(merge base #{short(change.base_sha)}), including uncommitted changes"

  defp describe_change(%Change{mode: :staged} = change),
    do: "staged changes against HEAD (#{short(change.base_sha)})"

  defp describe_change(%Change{head_sha: :worktree} = change),
    do: "#{change.base_ref} (#{short(change.base_sha)}) to the working tree"

  defp describe_change(change),
    do: "#{change.base_ref} (#{short(change.base_sha)}) to #{short(change.head_sha)}"

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)

  defp commits_section([]), do: nil

  defp commits_section(commits) do
    "Commits (newest first):\n" <> Enum.map_join(commits, "\n", &commit_entry/1)
  end

  defp commit_entry(commit) do
    title = "- #{short(commit.sha)} #{String.replace_invalid(commit.subject)}"

    case commit.body |> String.replace_invalid() |> String.slice(0, @max_commit_body) do
      "" ->
        title

      body ->
        title <> "\n" <> (body |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1)))
    end
  end

  defp file_entry(file) do
    letter =
      case file.status do
        :added -> "A"
        :deleted -> "D"
        :modified -> "M"
        :renamed -> "R"
        :copied -> "C"
      end

    path =
      if file.status in [:renamed, :copied],
        do: "#{file.path} (from #{file.old_path})",
        else: file.path

    stats = if file.binary, do: "binary", else: "+#{file.additions} -#{file.deletions}"
    "#{letter} #{path} (#{stats})"
  end

  defp skipped_section([]), do: nil

  defp skipped_section(skipped) do
    "Not reviewed line by line:\n" <>
      Enum.map_join(skipped, "\n", &"- #{&1.path}: #{describe_skip(&1.reason)}")
  end
end
