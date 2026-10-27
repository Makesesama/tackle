defmodule Tackle.Review.Rules do
  @moduledoc """
  Parses, merges, and resolves review rules.

  Rules are Markdown files with front matter. This module reads no files of
  its own except the built-in rules, embedded in it at compile time from
  `lib/tackle/review/builtin_rules` (see `builtin_files/0`). The host reads
  the other rule files and passes their contents to `load/2`, by source,
  lowest to highest precedence: typically the user's rules, then the
  project's (`project_dir/0` in the repository). `read_tree/3` reads a
  project's rule files from a commit instead of a checkout.

  A later source replaces an earlier rule with the same `id`, so a project
  can rewrite a built-in rule or turn it off with `status: suppressed`.
  Invalid files are skipped with a warning.

  The built-in rules are compiled into the module rather than read from
  `priv/`, so every distribution (Mix, escript, and the Nix-built release,
  whose source filter copies only `lib/`) ships them without setup.

  ## Format

      ---
      id: result-tuples            # lowercase letters, numbers, single hyphens
      category: correctness        # correctness | security | performance | maintainability | readability | testing
      severity: medium             # blocker | high | medium | low
      applies_to: ["lib/**/*.ex"]  # globs, default ["**/*"]
      status: active               # active (default) | suppressed | retired
      ---
      Expected failures return result tuples; do not raise for control flow.

      ## Bad
          def fetch(id), do: Repo.get(id) || raise "not found"

      ## Good
          def fetch(id), do: if(r = Repo.get(id), do: {:ok, r}, else: {:error, :not_found})

  The body is the instruction sent to the model, ideally with *Bad* and
  *Good* examples. Active rules need a category, a severity, and a body; a
  suppressed or retired rule only needs its `id` and `status`, so a project
  can turn off a built-in rule with a two-line file. `applies_to` accepts a
  flow list, a block list (`- glob` lines), or comma-separated globs, read
  with `YamlFrontmatter.list/1`; globs use `Tackle.Review.Glob`. Comments start with `#` after whitespace. A value
  that starts with `[` or `{` must be a closed list or quoted, so quote a
  glob such as `"{lib,test}/**"`; a field whose value cannot be read is an
  error rather than a default.

  ## Size caps

  Rules end up in every unit's prompt, so their size is bounded: a rule whose
  body exceeds `:max_rule_bytes` is skipped by `load/2`, and `resolve/3`
  keeps at most `:max_unit_bytes` of rule bodies per unit, preferring higher
  severities and more specific sources. Both report warnings.
  """

  alias Tackle.Review.{Finding, Glob}
  alias YamlFrontmatter, as: Frontmatter

  defmodule Rule do
    @moduledoc "One review rule. See `Tackle.Review.Rules` for the file format."

    @enforce_keys [:id, :status, :applies_to, :globs, :body, :path, :source]
    defstruct [:id, :category, :severity, :status, :applies_to, :globs, :body, :path, :source]

    @typedoc "Where a rule was found."
    @type source :: :builtin | :user | :project

    @typedoc """
    A rule.

    `category` and `severity` are `nil` only for suppressed or retired rules
    that do not set them; `body` is then possibly empty. `globs` are the
    compiled `applies_to` patterns.
    """
    @type t :: %__MODULE__{
            id: String.t(),
            category: Finding.category() | nil,
            severity: Finding.severity() | nil,
            status: :active | :suppressed | :retired,
            applies_to: [String.t()],
            globs: [Glob.t()],
            body: String.t(),
            path: Path.t(),
            source: source()
          }
  end

  @known_fields ~w(id category severity applies_to status)
  @statuses [:active, :suppressed, :retired]
  @id_pattern ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @project_dir ".tackle/review/rules"

  # Embedded at compile time; see the module documentation.
  @builtin_source_dir Path.join(__DIR__, "builtin_rules")
  @builtin_paths @builtin_source_dir
                 |> File.ls!()
                 |> Enum.filter(&String.ends_with?(&1, ".md"))
                 |> Enum.sort()
                 |> Enum.map(&Path.join(@builtin_source_dir, &1))
  for path <- @builtin_paths, do: @external_resource(path)
  @builtin_files Enum.map(@builtin_paths, &{Path.basename(&1), File.read!(&1)})
  @builtin_label "builtin:review/rules"

  @default_max_rule_bytes 4_096
  @default_max_unit_bytes 16_384
  @source_rank %{project: 0, user: 1, builtin: 2}

  @typedoc "A skipped file, unreadable directory, or dropped rule."
  @type warning :: %{path: Path.t() | nil, message: String.t()}

  @typedoc "All loaded rules, whatever their status, sorted by id, and warnings."
  @type discovery :: %{rules: [Rule.t()], warnings: [warning()]}

  @typedoc """
  The files of one source: each file's path (for messages and `Rule.path`)
  and its contents, or `{:error, message}` when the host could not read it,
  which becomes a warning. A host that could not list a directory passes
  the directory with an error the same way.
  """
  @type source_files :: [{Path.t(), {:ok, String.t()} | {:error, String.t()}}]

  @typedoc """
  Options of `load/2`:

    * `:builtin` - `:embedded` (default) loads the embedded built-in rules
      before the given sources; `false` loads none, for a host that passes
      its own `:builtin` source;
    * `:builtin_rules` - `:all` (default) or the ids of the built-in rules to
      keep; rules of other sources are kept whatever their id;
    * `:max_rule_bytes` - largest accepted rule body (default 4,096).
  """
  @type load_option ::
          {:builtin, :embedded | false}
          | {:builtin_rules, :all | [String.t()]}
          | {:max_rule_bytes, pos_integer()}

  @typedoc """
  Resolution options:

    * `:paths` - the change's file paths; required for the change-level
      unit, which a rule applies to when any of them matches;
    * `:max_unit_bytes` - total rule body bytes per unit (default 16,384).
  """
  @type resolve_option :: {:paths, [String.t()]} | {:max_unit_bytes, pos_integer()}

  @typedoc "Rules for one unit, in priority order, the rules dropped by the cap, and warnings."
  @type resolution :: %{rules: [Rule.t()], dropped: [Rule.t()], warnings: [warning()]}

  @doc """
  Returns the embedded built-in rule files as `{file_name, contents}` pairs,
  sorted by file name.

  `load/2` labels their rules with the path `"#{@builtin_label}/<file_name>"`,
  which does not exist on disk.
  """
  @spec builtin_files() :: [{String.t(), String.t()}]
  def builtin_files, do: @builtin_files

  @doc "Returns the ids of the embedded built-in rules, sorted."
  @spec builtin_ids() :: [String.t()]
  def builtin_ids do
    @builtin_files
    |> Enum.flat_map(fn {name, contents} ->
      case parse(contents, Path.join(@builtin_label, name), :builtin) do
        {:ok, rule} -> [rule.id]
        {:error, _message} -> []
      end
    end)
    |> Enum.sort()
  end

  # Recompiles when a built-in rule file is added or removed; edits to
  # existing files are tracked by `@external_resource`.
  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__? do
    case File.ls(@builtin_source_dir) do
      {:ok, names} ->
        names |> Enum.filter(&String.ends_with?(&1, ".md")) |> Enum.sort() !=
          Enum.map(@builtin_paths, &Path.basename/1)

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Returns the embedded built-in rules: `load([], builtin_rules: ids)`.
  """
  @spec builtin(:all | [String.t()]) :: discovery()
  def builtin(ids \\ :all) when ids == :all or is_list(ids), do: load([], builtin_rules: ids)

  @doc """
  The directory, relative to a repository's root, that holds its rules.
  """
  @spec project_dir() :: String.t()
  def project_dir, do: @project_dir

  @doc """
  Loads rules from the embedded built-in rules and `sources`, a list of
  `{source, files}` (see `t:source_files/0`) from lowest to highest
  precedence. See `t:load_option/0`.

  Only files ending in `.md` are read. A rule replaces a rule with the same
  id from an earlier source; within one source, the first file that defines
  an id wins and later ones are warnings. Returns every rule regardless of
  status, sorted by id, so later stages can tell suppressed rules from
  unknown ones.
  """
  @spec load([{Rule.source(), source_files()}], [load_option()]) :: discovery()
  def load(sources, opts \\ []) when is_list(sources) and is_list(opts) do
    max_bytes = positive_option(opts, :max_rule_bytes, @default_max_rule_bytes)
    keep_builtin = Keyword.get(opts, :builtin_rules, :all)

    embedded =
      case Keyword.get(opts, :builtin, :embedded) do
        :embedded -> [{:builtin, embedded_files()}]
        false -> []
      end

    {rules, warnings} =
      Enum.reduce(embedded ++ sources, {%{}, []}, fn {source, files}, {rules, warnings} ->
        {source_rules, warnings} = load_source(source, files, max_bytes, warnings)
        {Map.merge(rules, select_builtin(source, source_rules, keep_builtin)), warnings}
      end)

    %{rules: rules |> Map.values() |> Enum.sort_by(& &1.id), warnings: Enum.reverse(warnings)}
  end

  @doc """
  Returns the size of the largest rule file worth reading: `:max_rule_bytes`
  (default 4,096) plus 1,024 bytes for the front matter and the closing
  fence. A host reading rule files should refuse larger ones unread, as
  `read_tree/3` does, rather than read them whole for `load/2` to reject.
  """
  @spec max_file_bytes(max_rule_bytes: pos_integer()) :: pos_integer()
  def max_file_bytes(opts \\ []) when is_list(opts),
    do: positive_option(opts, :max_rule_bytes, @default_max_rule_bytes) + 1_024

  @doc """
  Reads a project's rule files (`project_dir/0`) as they are at the
  revision `rev` of the repository at `root`, for `load/2` as the
  `:project` source. Reads the object database, not the working tree, so
  a pull request can be reviewed against the rules of its base.

  A file larger than `max_file_bytes/1` is not read and is a warning. Returns `{:error, reason}` (`t:GixEx.error/0`) when the
  repository cannot be opened or `rev` cannot be resolved.
  """
  @spec read_tree(Path.t(), String.t(), max_rule_bytes: pos_integer()) ::
          {:ok, source_files()} | {:error, GixEx.error()}
  def read_tree(root, rev, opts \\ []) when is_binary(root) and is_binary(rev) do
    max_bytes = max_file_bytes(opts)

    with {:ok, repo} <- GixEx.open(root),
         {:ok, entries} <- GixEx.read_dir(repo, rev, @project_dir, max_file_bytes: max_bytes) do
      {:ok,
       for {name, contents} <- Enum.sort(entries), String.ends_with?(name, ".md") do
         path = Path.join(@project_dir, name)

         cond do
           is_nil(contents) -> {path, {:error, "file is larger than #{max_bytes} bytes"}}
           String.valid?(contents) -> {path, {:ok, contents}}
           true -> {path, {:error, "file is not valid UTF-8"}}
         end
       end}
    end
  end

  @doc """
  Parses one rule file.

  Returns `{:error, message}` for malformed front matter, unknown or invalid
  fields, invalid globs, or a missing body on an active rule.
  """
  @spec parse(String.t(), Path.t(), Rule.source()) ::
          {:ok, Rule.t()} | {:error, String.t()}
  def parse(contents, path, source) when is_binary(contents) do
    with {:ok, document} <- parse_document(contents),
         :ok <- validate_fields(document.frontmatter) do
      build(document.frontmatter, document.body, path, source)
    end
  end

  @doc "Returns whether a rule's `applies_to` globs match a path."
  @spec applies?(Rule.t(), String.t()) :: boolean()
  def applies?(%Rule{globs: globs}, path) when is_binary(path), do: Glob.match?(globs, path)

  @doc """
  Selects the active rules for a review unit (see `Tackle.Review.Units`).

  A code unit matches by its path, or its old path for renames and copies;
  the change-level unit matches when any of the `:paths` does. Rules are
  ordered by severity (most severe first), then by source (project, user,
  built-in), then by id. Rules that would exceed `:max_unit_bytes` are
  dropped with a warning; smaller rules after them may still fit.
  """
  @spec resolve([Rule.t()], map(), [resolve_option()]) :: resolution()
  def resolve(rules, unit, opts \\ []) when is_list(rules) do
    max_bytes = positive_option(opts, :max_unit_bytes, @default_max_unit_bytes)
    paths = unit_paths(unit, opts)

    {kept, dropped, _size} =
      rules
      |> Enum.filter(&(&1.status == :active and applies_to_any?(&1, paths)))
      |> Enum.sort_by(&priority/1)
      |> Enum.reduce({[], [], 0}, fn rule, {kept, dropped, size} ->
        rule_size = byte_size(rule.body)

        if size + rule_size <= max_bytes,
          do: {[rule | kept], dropped, size + rule_size},
          else: {kept, [rule | dropped], size}
      end)

    dropped = Enum.reverse(dropped)

    warnings =
      Enum.map(dropped, fn rule ->
        %{
          path: rule.path,
          message:
            "rule #{rule.id} was not applied to #{unit.id}: " <>
              "the unit's rules exceed #{max_bytes} bytes"
        }
      end)

    %{rules: Enum.reverse(kept), dropped: dropped, warnings: warnings}
  end

  ## Loading

  defp embedded_files do
    Enum.map(@builtin_files, fn {name, contents} ->
      {Path.join(@builtin_label, name), {:ok, contents}}
    end)
  end

  defp load_source(source, files, max_bytes, warnings) do
    files
    |> Enum.filter(fn {path, read} -> markdown?(path) or match?({:error, _message}, read) end)
    |> Enum.reduce({%{}, warnings}, fn {path, read}, {rules, warnings} ->
      with {:ok, contents} <- read,
           {:ok, rule} <- parse(contents, path, source),
           :ok <- within_size(rule, max_bytes),
           :ok <- unique(rule, rules) do
        {Map.put(rules, rule.id, rule), warnings}
      else
        {:error, message} -> {rules, [%{path: path, message: message} | warnings]}
      end
    end)
  end

  defp markdown?(path), do: String.ends_with?(path, ".md")

  defp select_builtin(:builtin, rules, ids) when is_list(ids), do: Map.take(rules, ids)
  defp select_builtin(_source, rules, _ids), do: rules

  defp within_size(%Rule{body: body}, max_bytes) do
    if byte_size(body) <= max_bytes,
      do: :ok,
      else: {:error, "rule body is #{byte_size(body)} bytes; the limit is #{max_bytes}"}
  end

  defp unique(%Rule{id: id}, rules) do
    case Map.get(rules, id) do
      nil -> :ok
      %Rule{path: path} -> {:error, "rule id #{id} is already defined in #{path}"}
    end
  end

  ## Parsing

  # The shared front matter parser does not know YAML comments, so they are
  # removed from the front matter block first.
  defp parse_document(contents) do
    contents =
      contents
      |> String.trim_leading("\uFEFF")
      |> String.replace(["\r\n", "\r"], "\n")

    contents =
      case String.split(contents, "\n") do
        ["---" | rest] ->
          {front, body} = Enum.split_while(rest, &(String.trim(&1) != "---"))
          Enum.join(["---" | Enum.map(front, &strip_comment/1)] ++ body, "\n")

        _lines ->
          contents
      end

    case Frontmatter.parse_document(contents) do
      {:ok, document} ->
        {:ok, document}

      {:error, reason} ->
        {:error,
         "malformed front matter (#{reason |> Atom.to_string() |> String.replace("_", " ")})"}
    end
  end

  # Cuts a `#` comment that starts the line or follows whitespace, outside quotes.
  defp strip_comment(line), do: line |> cut_comment(nil, " ", []) |> String.trim_trailing()

  defp cut_comment("", _quote, _previous, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp cut_comment("#" <> _rest, nil, previous, acc) when previous in [" ", "\t"],
    do: cut_comment("", nil, previous, acc)

  defp cut_comment("\\\"" <> rest, ?", _previous, acc),
    do: cut_comment(rest, ?", "\"", ["\\\"" | acc])

  defp cut_comment(<<char::utf8, rest::binary>>, quote, _previous, acc) do
    quote =
      cond do
        quote == nil and char in [?", ?'] -> char
        quote == char -> nil
        true -> quote
      end

    cut_comment(rest, quote, <<char::utf8>>, [<<char::utf8>> | acc])
  end

  # The shared parser reads an unclosed `[` or `{` value, and `null`, as
  # `nil`; a present field must not fall back to its default, which for
  # `applies_to` would widen a rule to every file.
  defp validate_fields(frontmatter) do
    keys = frontmatter |> Map.keys() |> Enum.sort()

    case Enum.reject(keys, &(&1 in @known_fields)) do
      [] ->
        case Enum.filter(keys, &is_nil(Map.fetch!(frontmatter, &1))) do
          [] ->
            :ok

          [key | _rest] ->
            {:error,
             "#{key} has no readable value; close lists with ] and quote values " <>
               "that start with [ or {"}
        end

      unknown ->
        {:error, "unknown front matter fields: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp build(frontmatter, body, path, source) do
    with {:ok, id} <- id(frontmatter),
         {:ok, status} <- status(frontmatter),
         {:ok, category} <- enum(frontmatter, "category", Finding.categories(), status),
         {:ok, severity} <- enum(frontmatter, "severity", Finding.severities(), status),
         {:ok, applies_to} <- applies_to(Map.get(frontmatter, "applies_to")),
         {:ok, globs} <- compile_globs(applies_to),
         :ok <- body(body, status) do
      {:ok,
       %Rule{
         id: id,
         category: category,
         severity: severity,
         status: status,
         applies_to: applies_to,
         globs: globs,
         body: body,
         path: path,
         source: source
       }}
    end
  end

  defp id(frontmatter) do
    case Map.get(frontmatter, "id") do
      id when is_binary(id) ->
        if Regex.match?(@id_pattern, id),
          do: {:ok, id},
          else: {:error, "id must use lowercase letters, numbers, and single hyphens"}

      nil ->
        {:error, "id is required"}

      value ->
        {:error, "id must be a string, got: #{inspect(value)}"}
    end
  end

  defp status(frontmatter) do
    case Map.get(frontmatter, "status") do
      nil -> {:ok, :active}
      value -> parse_enum(value, "status", @statuses)
    end
  end

  defp enum(frontmatter, key, allowed, status) do
    case Map.get(frontmatter, key) do
      nil when status == :active -> {:error, "#{key} is required for an active rule"}
      nil -> {:ok, nil}
      value -> parse_enum(value, key, allowed)
    end
  end

  defp parse_enum(value, key, allowed) do
    case Enum.find(allowed, &(is_binary(value) and Atom.to_string(&1) == value)) do
      nil -> {:error, "#{key} must be one of #{Enum.join(allowed, ", ")}, got: #{inspect(value)}"}
      atom -> {:ok, atom}
    end
  end

  defp applies_to(nil), do: {:ok, ["**/*"]}

  defp applies_to(value) when is_binary(value) do
    case Frontmatter.list(value) do
      {:ok, []} -> {:error, "applies_to must list at least one glob"}
      {:ok, patterns} -> {:ok, patterns}
      {:error, :malformed_list} -> not_a_glob_list(value)
    end
  end

  defp applies_to(value), do: not_a_glob_list(value)

  defp not_a_glob_list(value),
    do: {:error, "applies_to must be a list of globs, got: #{inspect(value)}"}

  defp compile_globs(patterns) do
    case Glob.compile_all(patterns) do
      {:ok, globs} ->
        {:ok, globs}

      {:error, {:invalid_glob, pattern, message}} ->
        {:error, "invalid glob #{inspect(pattern)}: #{message}"}
    end
  end

  defp body("", :active), do: {:error, "an active rule needs a body"}
  defp body(_body, _status), do: :ok

  ## Resolution

  defp applies_to_any?(rule, paths), do: Enum.any?(paths, &applies?(rule, &1))

  defp unit_paths(%{kind: :change} = unit, opts) do
    case Keyword.fetch(opts, :paths) do
      {:ok, paths} when is_list(paths) ->
        paths

      _other ->
        raise ArgumentError, "resolving rules for #{inspect(unit.id)} requires the :paths option"
    end
  end

  defp unit_paths(%{path: path} = unit, _opts),
    do: Enum.uniq(Enum.reject([path, Map.get(unit, :old_path)], &is_nil/1))

  defp priority(rule) do
    {Enum.find_index(Finding.severities(), &(&1 == rule.severity)),
     Map.fetch!(@source_rank, rule.source), rule.id}
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
    end
  end
end
