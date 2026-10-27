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
    * `:env` - environment for `TACKLE_HOME` (default: the process's);
    * `:builtin_dir` - directory to read instead of the embedded built-in
      rules, or `nil` for no built-in rules (default: the embedded rules);
    * `:builtin_rules` and `:max_rule_bytes` - see
      `t:Tackle.Review.Rules.load_option/0`.
  """
  @type option ::
          {:cwd, Path.t()}
          | {:executor, Executor.t() | nil}
          | {:env, %{optional(String.t()) => String.t()}}
          | {:builtin_dir, Path.t() | nil}
          | {:builtin_rules, :all | [String.t()]}
          | {:max_rule_bytes, pos_integer()}

  @doc """
  Discovers rules from all sources (see the module documentation).

  A missing `:builtin_dir` is a warning; missing user and project
  directories are not.
  """
  @spec discover([option()]) :: Rules.discovery()
  def discover(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    files = ProjectFiles.new(executor: Keyword.get(opts, :executor), env: env)
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
          {false, [{:builtin, read_directory(host_files, Path.expand(dir), true, max_bytes)}]}
      end

    tackle_home =
      case Paths.home(env: env) do
        {:ok, home} -> home
        {:error, _reason} -> nil
      end

    discovered =
      files
      |> ProjectFiles.tackle_dirs(cwd, tackle_home, @rules_dir)
      |> Enum.map(fn {source, dir} -> {source, read_directory(files, dir, false, max_bytes)} end)

    Rules.load(
      sources ++ discovered,
      [builtin: builtin] ++ Keyword.take(opts, [:builtin_rules, :max_rule_bytes])
    )
  end

  defp read_directory(files, dir, required?, max_bytes) do
    case ProjectFiles.list_files(files, dir, ".md") do
      {:ok, paths} ->
        Enum.map(paths, &{&1, read(files, &1, max_bytes)})

      {:error, :enoent} when not required? ->
        []

      {:error, reason} ->
        [{dir, {:error, "could not list rule directory (#{ProjectFiles.format_error(reason)})"}}]
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
