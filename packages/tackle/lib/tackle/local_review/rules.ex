defmodule Tackle.LocalReview.Rules do
  @moduledoc """
  Discovers review rules for a local session and loads them with
  `Tackle.Review.Rules.load/2`.

  Rule files are read flat from three sources, lowest to highest
  precedence:

    1. the built-in rules embedded in `Tackle.Review.Rules`;
    2. `$TACKLE_HOME/review/rules`;
    3. the nearest `.tackle/review/rules` at or above the working directory,
       within the bounds of `Tackle.ProjectFiles.ancestors/3`.

  Non-Markdown files and subdirectories are ignored. Files in the workspace
  are read through the session executor (see `Tackle.ProjectFiles`).
  """

  alias Tackle.{Executor, Paths, ProjectFiles}
  alias Tackle.Review.Rules

  @user_dir "review/rules"

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
    files = ProjectFiles.new(opts)
    cwd = opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    {builtin, sources} =
      case Keyword.fetch(opts, :builtin_dir) do
        :error ->
          {:embedded, []}

        {:ok, nil} ->
          {false, []}

        # A replacement built-in directory is a host directory, not workspace files.
        {:ok, dir} ->
          host_files = ProjectFiles.new(executor: Executor.local())
          {false, [{:builtin, read_directory(host_files, Path.expand(dir), true)}]}
      end

    user =
      case Paths.home(env: env) do
        {:ok, home} -> [{:user, read_directory(files, Path.join(home, @user_dir), false)}]
        {:error, _reason} -> []
      end

    project =
      case ProjectFiles.nearest_project_dir(files, cwd, Rules.project_dir()) do
        nil -> []
        dir -> [{:project, read_directory(files, dir, false)}]
      end

    Rules.load(
      sources ++ user ++ project,
      [builtin: builtin] ++ Keyword.take(opts, [:builtin_rules, :max_rule_bytes])
    )
  end

  defp read_directory(files, dir, required?) do
    case ProjectFiles.list(files, dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&ProjectFiles.regular?(files, &1))
        |> Enum.map(&{&1, read(files, &1)})

      {:error, :enoent} when not required? ->
        []

      {:error, reason} ->
        [{dir, {:error, "could not list rule directory (#{Executor.format_reason(reason)})"}}]
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
end
