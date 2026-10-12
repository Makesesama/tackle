defmodule Tackle.Review.Rules do
  @moduledoc """
  Discovers review rules and resolves the ones that apply to a review unit.

  Rules are Markdown files with front matter, read flat from three
  directories, lowest to highest precedence:

    1. the built-in rules, embedded in this module at compile time from
       `lib/tackle/review/builtin_rules` (see `builtin_files/0`);
    2. `$TACKLE_HOME/review/rules`;
    3. the nearest `.tackle/review/rules` at or above the working directory,
       stopping at the Git root.

  A later source replaces an earlier rule with the same `id`, so a project
  can rewrite a built-in rule or turn it off with `status: suppressed`.
  Non-Markdown files and subdirectories are ignored; invalid files are
  skipped with a warning. Files in the workspace are read through the
  session executor (see `Tackle.ProjectFiles`).

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
  flow list, a block list (`- glob` lines), or a single glob; globs use
  `Tackle.Review.Glob`. Comments start with `#` after whitespace. A value
  that starts with `[` or `{` must be a closed list or quoted, so quote a
  glob such as `"{lib,test}/**"`; a field whose value cannot be read is an
  error rather than a default.

  ## Size caps

  Rules end up in every unit's prompt, so their size is bounded: a rule whose
  body exceeds `:max_rule_bytes` is skipped at discovery, and `resolve/3`
  keeps at most `:max_unit_bytes` of rule bodies per unit, preferring higher
  severities and more specific sources. Both report warnings.
  """

  alias Tackle.{Executor, Paths, ProjectFiles}
  alias Tackle.Review.{Finding, Glob}
  alias Tackle.Skills.Frontmatter

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
  @relative_dir "review/rules"

  # Embedded at compile time; see the module documentation.
  @builtin_source_dir Path.join(__DIR__, "builtin_rules")
  @builtin_paths @builtin_source_dir
                 |> File.ls!()
                 |> Enum.filter(&String.ends_with?(&1, ".md"))
                 |> Enum.sort()
                 |> Enum.map(&Path.join(@builtin_source_dir, &1))
  for path <- @builtin_paths, do: @external_resource(path)
  @builtin_files Enum.map(@builtin_paths, &{Path.basename(&1), File.read!(&1)})
  @builtin_label "builtin:" <> @relative_dir

  @default_max_rule_bytes 4_096
  @default_max_unit_bytes 16_384
  @source_rank %{project: 0, user: 1, builtin: 2}

  @typedoc "A skipped file, unreadable directory, or dropped rule."
  @type warning :: %{path: Path.t() | nil, message: String.t()}

  @typedoc "All discovered rules, whatever their status, sorted by id, and warnings."
  @type discovery :: %{rules: [Rule.t()], warnings: [warning()]}

  @typedoc """
  Discovery options:

    * `:cwd` - working directory for the project search (default: current);
    * `:executor` - session executor for workspace files (default: local);
    * `:env` - environment for `TACKLE_HOME` (default: the process's);
    * `:builtin_dir` - directory to read instead of the embedded built-in
      rules, or `nil` for no built-in rules (default: the embedded rules);
    * `:max_rule_bytes` - largest accepted rule body (default 4,096).
  """
  @type discover_option ::
          {:cwd, Path.t()}
          | {:executor, Executor.t() | nil}
          | {:env, %{optional(String.t()) => String.t()}}
          | {:builtin_dir, Path.t() | nil}
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

  Discovery labels their rules with the path `"#{@builtin_label}/<file_name>"`,
  which does not exist on disk.
  """
  @spec builtin_files() :: [{String.t(), String.t()}]
  def builtin_files, do: @builtin_files

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
  Discovers rules from all sources (see the module documentation).

  Returns every rule regardless of status, so later stages can tell
  suppressed rules from unknown ones. A missing `:builtin_dir` is a
  warning; missing user and project directories are not.
  """
  @spec discover([discover_option()]) :: discovery()
  def discover(opts \\ []) do
    files = ProjectFiles.new(opts)
    max_bytes = positive_option(opts, :max_rule_bytes, @default_max_rule_bytes)

    {rules, warnings} =
      opts
      |> sources(files)
      |> Enum.reduce({%{}, []}, fn
        {:builtin, :embedded}, acc ->
          load_embedded(max_bytes, acc)

        {source, dir, reader, required?}, acc ->
          load_directory(reader, dir, source, required?, max_bytes, acc)
      end)

    %{rules: rules |> Map.values() |> Enum.sort_by(& &1.id), warnings: Enum.reverse(warnings)}
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

  ## Discovery

  defp sources(opts, files) do
    cwd = opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    builtin =
      case Keyword.fetch(opts, :builtin_dir) do
        :error ->
          [{:builtin, :embedded}]

        {:ok, nil} ->
          []

        # A replacement built-in directory is a host directory, not workspace files.
        {:ok, dir} ->
          [{:builtin, Path.expand(dir), ProjectFiles.new(executor: Executor.local()), true}]
      end

    user =
      case Paths.home(env: env) do
        {:ok, home} -> [{:user, Path.join(home, @relative_dir), files, false}]
        {:error, _reason} -> []
      end

    project =
      case ProjectFiles.nearest_project_dir(files, cwd, Path.join(".tackle", @relative_dir)) do
        nil -> []
        dir -> [{:project, dir, files, false}]
      end

    builtin ++ user ++ project
  end

  defp load_directory(files, dir, source, required?, max_bytes, {rules, warnings} = acc) do
    case ProjectFiles.list(files, dir) do
      {:ok, entries} ->
        {source_rules, warnings} =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&ProjectFiles.regular?(files, &1))
          |> Enum.reduce({%{}, warnings}, &load_file(files, &1, source, max_bytes, &2))

        {Map.merge(rules, source_rules), warnings}

      {:error, :enoent} when not required? ->
        acc

      {:error, reason} ->
        message = "could not list rule directory (#{Executor.format_reason(reason)})"
        {rules, [%{path: dir, message: message} | warnings]}
    end
  end

  defp load_embedded(max_bytes, {rules, warnings}) do
    {builtin_rules, warnings} =
      Enum.reduce(@builtin_files, {%{}, warnings}, fn {name, contents}, acc ->
        add_rule({:ok, contents}, Path.join(@builtin_label, name), :builtin, max_bytes, acc)
      end)

    {Map.merge(rules, builtin_rules), warnings}
  end

  defp load_file(files, path, source, max_bytes, acc),
    do: add_rule(read(files, path), path, source, max_bytes, acc)

  defp add_rule(read_result, path, source, max_bytes, {rules, warnings}) do
    with {:ok, contents} <- read_result,
         {:ok, rule} <- parse(contents, path, source),
         :ok <- within_size(rule, max_bytes),
         :ok <- unique(rule, rules) do
      {Map.put(rules, rule.id, rule), warnings}
    else
      {:error, message} -> {rules, [%{path: path, message: message} | warnings]}
    end
  end

  defp read(files, path) do
    case ProjectFiles.read(files, path) do
      {:ok, contents} ->
        if String.valid?(contents), do: {:ok, contents}, else: {:error, "file is not valid UTF-8"}

      {:error, reason} ->
        {:error, "could not be read (#{Executor.format_reason(reason)})"}
    end
  end

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
    value = String.trim(value)

    patterns =
      cond do
        String.starts_with?(value, "[") and String.ends_with?(value, "]") -> flow_list(value)
        String.starts_with?(value, "- ") -> block_list(value)
        true -> [value]
      end

    cond do
      not Enum.all?(patterns, &is_binary/1) ->
        {:error, "applies_to must contain only globs"}

      Enum.reject(patterns, &(&1 == "")) == [] ->
        {:error, "applies_to must list at least one glob"}

      true ->
        {:ok, Enum.reject(patterns, &(&1 == ""))}
    end
  end

  defp applies_to(value),
    do: {:error, "applies_to must be a list of globs, got: #{inspect(value)}"}

  # `["a", "b"]` is JSON; otherwise split at commas outside quotes and braces,
  # since globs such as `*.{ex,exs}` contain commas.
  defp flow_list(value) do
    case JSON.decode(value) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, &trim_item/1)

      _other ->
        value
        |> String.slice(1..-2//1)
        |> split_items(nil, 0, [], [])
        |> Enum.map(&unquote_item/1)
    end
  end

  defp trim_item(item) when is_binary(item), do: String.trim(item)
  defp trim_item(item), do: item

  defp split_items("", _quote, _depth, current, items),
    do: Enum.reverse([current |> Enum.reverse() |> IO.iodata_to_binary() | items])

  defp split_items("," <> rest, nil, 0, current, items),
    do:
      split_items(rest, nil, 0, [], [current |> Enum.reverse() |> IO.iodata_to_binary() | items])

  defp split_items(<<char::utf8, rest::binary>>, quote, depth, current, items) do
    {quote, depth} =
      cond do
        quote == nil and char in [?", ?'] -> {char, depth}
        quote == char -> {nil, depth}
        quote == nil and char == ?{ -> {nil, depth + 1}
        quote == nil and char == ?} -> {nil, max(depth - 1, 0)}
        true -> {quote, depth}
      end

    split_items(rest, quote, depth, [<<char::utf8>> | current], items)
  end

  defp block_list(value) do
    value
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("-") |> unquote_item()))
  end

  defp unquote_item(item) do
    item = String.trim(item)

    case item do
      <<quote, rest::binary>> when quote in [?", ?'] and byte_size(rest) > 0 ->
        if :binary.last(rest) == quote,
          do: binary_part(rest, 0, byte_size(rest) - 1),
          else: item

      _other ->
        item
    end
  end

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
