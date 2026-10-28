defmodule Tackle.LocalReview.Rules do
  @moduledoc """
  Discovers review rules for a local session and loads them with
  `Tackle.Review.Rules.load/2`.

  Rule files are read flat from three sources, lowest to highest
  precedence:

    1. the built-in rules embedded in `Tackle.Review.Rules`;
    2. `$TACKLE_HOME/review/rules`;
    3. the nearest `.tackle/review/rules` at or above the working directory,
       within the bounds of `Tackle.ProjectFiles.ancestors/3`; `$TACKLE_HOME`
       itself is never a project directory.

  Non-Markdown files and subdirectories are ignored. Files in the workspace
  are read through the session executor (see `Tackle.ProjectFiles`). A file
  larger than `Tackle.Review.Rules.max_file_bytes/1` is a warning and is not
  read, so a workspace full of large files costs the host little memory.

  `check/1` discovers the same rules and also reports where it looked, and
  `format_check/1` renders that report; the `check_review_rules` tool
  (`Tackle.Tools.ReviewRules`) and the CLI's `tackle review rules` share
  them, so a person and an agent see the same result.
  """

  alias Tackle.{Executor, Paths, ProjectFiles}
  alias Tackle.Review.Rules

  # `Tackle.Review.Rules.project_dir/0` within `.tackle`, and the user
  # directory within `$TACKLE_HOME`.
  @rules_dir "review/rules"

  @typedoc """
  Discovery options:

    * `:cwd` - working directory for the project search (default: current);
    * `:executor` - session executor for workspace files (default: local);
    * `:home` and `:user_home` - the Tackle home holding the user rules and
      the user's home directory bounding the project search, `nil` for none
      (default: resolved from the process environment, see
      `Tackle.Paths.homes/1`);
    * `:builtin_dir` - directory to read instead of the embedded built-in
      rules, or `nil` for no built-in rules (default: the embedded rules);
    * `:builtin_rules` and `:max_rule_bytes` - see
      `t:Tackle.Review.Rules.load_option/0`.
  """
  @type option ::
          {:cwd, Path.t()}
          | {:executor, Executor.t() | nil}
          | {:home, Path.t() | nil}
          | {:user_home, Path.t() | nil}
          | {:builtin_dir, Path.t() | nil}
          | {:builtin_rules, :all | [String.t()]}
          | {:max_rule_bytes, pos_integer()}

  @typedoc """
  The result of `check/1`: the rules and warnings `discover/1` returns, and
  where they were looked for.

    * `:user_dir` - `$TACKLE_HOME/review/rules`, `nil` without a Tackle
      home; `:user_dir_found?` says whether it exists;
    * `:project_dir` - the project directory that was read, `nil` when
      there is none;
    * `:new_project_dir` - where a project's rules go when it has no
      directory yet: `.tackle/review/rules` at the top of the project
      search, usually the Git root;
    * `:builtin_ids` - the ids of every built-in rule, selected or not;
    * `:builtin_rules` - the selection, `:all` or the ids kept (the
      `:builtin_rules` option).
  """
  @type check :: %{
          rules: [Rules.Rule.t()],
          warnings: [Rules.warning()],
          user_dir: Path.t() | nil,
          user_dir_found?: boolean(),
          project_dir: Path.t() | nil,
          new_project_dir: Path.t(),
          builtin_ids: [String.t()],
          builtin_rules: :all | [String.t()]
        }

  @doc """
  Discovers rules from all sources (see the module documentation).

  A missing `:builtin_dir` is a warning; missing user and project
  directories are not.
  """
  @spec discover([option()]) :: Rules.discovery()
  def discover(opts \\ []) do
    {discovery, _found} = load(opts)
    discovery
  end

  @doc """
  Discovers rules as `discover/1` does and reports where they were looked
  for, so a user or an agent writing rule files can see whether they load.
  `format_check/1` renders the result.

  A rule file that does not load is a warning, never an error: a review
  skips it and runs with the other rules.
  """
  @spec check([option()]) :: check()
  def check(opts \\ []) do
    {discovery, found} = load(opts)

    Map.merge(discovery, %{
      user_dir: dir_of(found.dirs, :user),
      user_dir_found?: :user in found.existing,
      project_dir: dir_of(found.dirs, :project),
      new_project_dir: new_project_dir(found.files, found.cwd, found.home),
      builtin_ids: builtin_ids(found.builtin, found.sources, found.load_opts),
      builtin_rules: found.builtin_rules
    })
  end

  # The discovery, and what `check/1` reports besides it.
  defp load(opts) do
    homes = opts |> Keyword.take([:home, :user_home]) |> Paths.homes()
    files = ProjectFiles.new(executor: Keyword.get(opts, :executor), user_home: homes[:user_home])
    cwd = opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()
    max_bytes = opts |> Keyword.take([:max_rule_bytes]) |> Rules.max_file_bytes()

    {builtin, sources} =
      case Keyword.fetch(opts, :builtin_dir) do
        :error ->
          {:embedded, []}

        {:ok, nil} ->
          {false, []}

        # A replacement built-in directory is a host directory, not workspace files.
        {:ok, dir} ->
          host_files = ProjectFiles.new(executor: Executor.local())
          {read, _found?} = read_directory(host_files, Path.expand(dir), true, max_bytes)
          {false, [{:builtin, read}]}
      end

    dirs = ProjectFiles.tackle_dirs(files, cwd, homes[:home], @rules_dir)

    discovered =
      Enum.map(dirs, fn {source, dir} ->
        {source, read_directory(files, dir, false, max_bytes)}
      end)

    load_opts = Keyword.take(opts, [:max_rule_bytes])
    builtin_rules = Keyword.get(opts, :builtin_rules, :all)

    discovery =
      Rules.load(
        sources ++ Enum.map(discovered, fn {source, {read, _found?}} -> {source, read} end),
        [builtin: builtin, builtin_rules: builtin_rules] ++ load_opts
      )

    {discovery,
     %{
       files: files,
       cwd: cwd,
       home: homes[:home],
       dirs: dirs,
       existing: for({source, {_read, true}} <- discovered, do: source),
       builtin: builtin,
       sources: sources,
       load_opts: load_opts,
       builtin_rules: builtin_rules
     }}
  end

  defp dir_of(dirs, source) do
    Enum.find_value(dirs, fn {dir_source, dir} -> if dir_source == source, do: dir end)
  end

  # The highest directory of the project search (the Git root, usually)
  # that is in the executor's workspace, so a jailed agent can create it,
  # and whose `.tackle` is not the Tackle home (a working directory under
  # the home directory, outside Git, reaches `~/.tackle`).
  defp new_project_dir(files, cwd, home) do
    root =
      files
      |> ProjectFiles.ancestors(cwd)
      |> Enum.filter(&(files.workspace == nil or ProjectFiles.in_workspace?(files, &1)))
      |> Enum.reject(
        &(is_binary(home) and ProjectFiles.same_dir?(Path.join(&1, ".tackle"), home))
      )
      |> List.last(cwd)

    Path.join([root, ".tackle", @rules_dir])
  end

  defp builtin_ids(:embedded, _sources, _load_opts), do: Rules.builtin_ids()

  defp builtin_ids(false, sources, load_opts) do
    sources
    |> Rules.load([builtin: false] ++ load_opts)
    |> Map.fetch!(:rules)
    |> Enum.map(& &1.id)
  end

  @doc """
  Renders `check/1`'s result as text for a person or a model: a headline,
  the files that did not load and why, the rules in effect, built-in rules
  the selection leaves out, and the rule directories.
  """
  @spec format_check(check()) :: String.t()
  def format_check(check) do
    [
      check_headline(check),
      problems_section(check.warnings),
      rules_section(check),
      unselected_section(check),
      directories_section(check)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp check_headline(%{rules: rules, warnings: warnings}) do
    frequencies = Enum.frequencies_by(rules, & &1.status)

    counts =
      [:active, :suppressed, :retired]
      |> Enum.map(&{&1, Map.get(frequencies, &1, 0)})
      |> Enum.filter(fn {status, count} -> status == :active or count > 0 end)
      |> Enum.map(fn {status, count} -> "#{count} #{status}" end)

    problems =
      case length(warnings) do
        0 -> "no problems"
        1 -> "1 problem"
        count -> "#{count} problems"
      end

    "Review rules: #{Enum.join(counts, ", ")}; #{problems}."
  end

  defp problems_section([]), do: nil

  defp problems_section(warnings) do
    lines =
      Enum.map(warnings, fn
        %{path: nil, message: message} -> "- " <> message
        %{path: path, message: message} -> "- #{path}: #{message}"
      end)

    Enum.join(["Problems (a review skips these files):" | lines], "\n")
  end

  defp rules_section(%{rules: []}), do: "Rules: none."

  defp rules_section(%{rules: rules, builtin_ids: builtin_ids}) do
    lines = Enum.map(rules, &rule_line(&1, &1.source != :builtin and &1.id in builtin_ids))
    Enum.join(["Rules:" | lines], "\n")
  end

  defp rule_line(rule, replaces_builtin?) do
    kind =
      case rule.status do
        :active -> "#{rule.severity} #{rule.category}"
        status -> Atom.to_string(status)
      end

    details =
      [
        kind,
        source_label(rule.source),
        if(replaces_builtin?, do: "replaces the built-in rule"),
        if(rule.status == :active and rule.applies_to != ["**/*"],
          do: "applies to " <> Enum.join(rule.applies_to, ", ")
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    path = if rule.source == :builtin, do: "", else: " (#{rule.path})"
    "- #{rule.id}: #{details}#{path}"
  end

  defp source_label(:builtin), do: "built-in"
  defp source_label(source), do: Atom.to_string(source)

  defp unselected_section(%{builtin_rules: :all}), do: nil

  defp unselected_section(%{builtin_rules: kept, builtin_ids: ids, rules: rules}) do
    loaded = MapSet.new(rules, & &1.id)

    case Enum.reject(ids, &(&1 in kept or MapSet.member?(loaded, &1))) do
      [] -> nil
      off -> "Built-in rules left out by review.default_rules: " <> Enum.join(off, ", ")
    end
  end

  defp directories_section(check) do
    user =
      case check do
        %{user_dir: nil} -> []
        %{user_dir: dir, user_dir_found?: true} -> ["- user: #{dir}"]
        %{user_dir: dir} -> ["- user: #{dir} (does not exist)"]
      end

    project =
      case check.project_dir do
        nil -> "- project: none found; create #{check.new_project_dir}"
        dir -> "- project: #{dir}"
      end

    Enum.join(
      ["Rule directories (project rules replace user rules with the same id):" | user] ++
        [project],
      "\n"
    )
  end

  # The directory's files and whether it exists.
  defp read_directory(files, dir, required?, max_bytes) do
    case ProjectFiles.list_files(files, dir, ".md") do
      {:ok, paths} ->
        {Enum.map(paths, &{&1, read(files, &1, max_bytes)}), true}

      {:error, :enoent} when not required? ->
        {[], false}

      {:error, reason} ->
        message = "could not list rule directory (#{ProjectFiles.format_error(reason)})"
        {[{dir, {:error, message}}], true}
    end
  end

  defp read(files, path, max_bytes) do
    case ProjectFiles.read_text(files, path, max_bytes: max_bytes) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :too_large} ->
        {:error, "file is larger than #{max_bytes} bytes"}

      {:error, reason} ->
        {:error, "could not be read (#{ProjectFiles.format_error(reason)})"}
    end
  end
end
