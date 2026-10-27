defmodule Tackle.Workflows do
  @moduledoc """
  Saved, self-contained Lua workflows co-authored with the user.

  Files live in `$TACKLE_HOME/workflows` and the nearest `.tackle/workflows`
  at or above the working directory, within the bounds of
  `Tackle.ProjectFiles.ancestors/3`; `$TACKLE_HOME` itself is never a project
  directory. Discovery is flat; project files override user files by name.
  There are no parameters or approval gates: configuration belongs in locals
  inside the script.

  Filesystem access uses `Tackle.ProjectFiles`, including its 1 MiB read cap
  and its routing of host symlinks into the workspace through the executor.
  """

  alias Tackle.{Executor, Paths, ProjectFiles}

  defmodule Workflow do
    @moduledoc "Metadata for one saved Lua workflow."
    @enforce_keys [:name, :description, :path, :source]
    defstruct [:name, :description, :path, :source]

    @typedoc "A name, first-line description, absolute path, and discovery source."
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            path: Path.t(),
            source: :user | :project
          }
  end

  @name_pattern ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @typedoc "Discovery options; cwd and environment default to the current process."
  @type option ::
          {:cwd, Path.t()}
          | {:executor, Executor.t() | nil}
          | {:env, %{optional(String.t()) => String.t()}}
  @typedoc "A skipped file or unreadable directory."
  @type warning :: %{path: Path.t(), message: String.t()}
  @typedoc "Saved workflows sorted by name, and discovery warnings."
  @type discovery :: %{workflows: [Workflow.t()], warnings: [warning()]}
  @typedoc "Fetch failure, including executor read errors or invalid UTF-8."
  @type fetch_error :: {:unknown_workflow, String.t(), [String.t()]} | Executor.reason()
  @typedoc "Create failure: an invalid name, no project directory, or a write error."
  @type create_error :: :invalid_name | :no_project_dir | Executor.reason()

  @doc """
  Discovers flat `<name>.lua` files, with project precedence, sorted by name.

  Accepts `:cwd`, `:executor`, and `:env`. Invalid names and unreadable Lua
  files produce warnings; non-Lua files and subdirectories are ignored.
  The description is the trimmed first line after `--`, except `--[[`.
  """
  @spec discover([option()]) :: discovery()
  def discover(opts \\ []) do
    files = ProjectFiles.new(opts)

    {workflows, warnings} =
      Enum.reduce(sources(files, opts), {%{}, []}, fn {source, dir}, acc ->
        load_directory(files, dir, source, acc)
      end)

    %{
      workflows: workflows |> Map.values() |> Enum.sort_by(& &1.name),
      warnings: Enum.reverse(warnings)
    }
  end

  @doc """
  Re-discovers and reads a workflow at call time, returning its metadata and script.

  Unknown names return `{:error, {:unknown_workflow, name, available_names}}`.
  Read failures return `{:error, reason}` (including `:too_large` or
  `:invalid_utf8`). Accepts the discovery options.
  """
  @spec fetch(String.t(), [option()]) :: {:ok, Workflow.t(), String.t()} | {:error, fetch_error()}
  def fetch(name, opts \\ []) do
    files = ProjectFiles.new(opts)

    # Project files override user files, so the project candidate comes first.
    candidate =
      if valid_name?(name) do
        files
        |> sources(opts)
        |> Enum.reverse()
        |> Enum.map(fn {source, dir} -> {source, Path.join(dir, name <> ".lua")} end)
        |> Enum.find(fn {_source, path} -> ProjectFiles.regular?(files, path) end)
      end

    case candidate do
      {source, path} ->
        with {:ok, script} <- ProjectFiles.read_text(files, path) do
          {:ok, workflow(name, path, source, script), script}
        end

      nil ->
        names = opts |> discover() |> Map.fetch!(:workflows) |> Enum.map(& &1.name)
        {:error, {:unknown_workflow, name, names}}
    end
  end

  @doc """
  Returns a live `name -> {:ok, script} | {:error, message}` loader for session context.

  Errors are model-readable; unknown names list available workflows, or explain
  where to save them when none exist. Accepts the discovery options.
  """
  @spec loader([option()]) :: (String.t() -> {:ok, String.t()} | {:error, String.t()})
  def loader(opts \\ []) do
    fn name ->
      case fetch(name, opts) do
        {:ok, _workflow, script} ->
          {:ok, script}

        {:error, {:unknown_workflow, _, []}} ->
          {:error,
           "Unknown workflow #{inspect(name)}. No saved workflows exist. Save them in #{save_location(opts)}."}

        {:error, {:unknown_workflow, _, names}} ->
          {:error,
           "Unknown workflow #{inspect(name)}. Available workflows: #{Enum.join(names, ", ")}."}

        {:error, reason} ->
          {:error,
           "Could not read workflow #{inspect(name)}: #{ProjectFiles.format_error(reason)}"}
      end
    end
  end

  @doc """
  Writes a script, through the executor inside its workspace and locally
  otherwise; a host path whose symlinks lead into the workspace is written
  through the executor (see `Tackle.ProjectFiles`).

  Accepts discovery options plus executor write options `:mode` (default
  `:replace`, or `:create` for exclusive creation) and `:mkdir_p` (default false).
  `:exclusive` set to true is shorthand for `mode: :create`.
  """
  @spec save(Path.t(), String.t(), keyword()) :: :ok | {:error, Executor.reason()}
  def save(path, script, opts \\ []) do
    path = Path.expand(path, cwd(opts))
    write_opts = Keyword.take(opts, [:mode, :mkdir_p])

    write_opts =
      if Keyword.get(opts, :exclusive, false),
        do: Keyword.put(write_opts, :mode, :create),
        else: write_opts

    ProjectFiles.write(ProjectFiles.new(opts), path, script, write_opts)
  end

  @doc """
  Returns the nearest existing project `.tackle/workflows`, or
  `<cwd>/.tackle/workflows`.

  Returns `nil` when that would be the user directory, as in the home
  directory with the default `$TACKLE_HOME`. Does not create directories.
  Accepts the discovery options.
  """
  @spec project_dir([option()]) :: Path.t() | nil
  def project_dir(opts \\ []) do
    case opts |> ProjectFiles.new() |> sources(opts) |> List.keyfind(:project, 0) do
      {:project, dir} ->
        dir

      nil ->
        home = tackle_home(opts)
        tackle = Path.join(cwd(opts), ".tackle")

        if is_nil(home) or not ProjectFiles.same_dir?(tackle, home),
          do: Path.join(tackle, "workflows")
    end
  end

  @doc """
  Creates a named project workflow, including missing directories, exclusively.

  Names use lowercase letters, numbers, and single hyphens. Returns `{:ok, path}`,
  `{:error, :invalid_name}`, `{:error, :no_project_dir}` when `project_dir/1`
  finds none, or a write error (`:eexist` if already present).
  A user workflow with the same name does not prevent project creation.
  Accepts the discovery options; creation is always exclusive.
  """
  @spec create(String.t(), String.t(), [option()]) :: {:ok, Path.t()} | {:error, create_error()}
  def create(name, script, opts \\ []) do
    with true <- valid_name?(name) || {:error, :invalid_name},
         dir when is_binary(dir) <- project_dir(opts) || {:error, :no_project_dir},
         path = Path.join(dir, name <> ".lua"),
         :ok <- save(path, script, Keyword.merge(opts, mode: :create, mkdir_p: true)) do
      {:ok, path}
    end
  end

  @doc "Returns a starter Lua script with a description, configurable locals, and spawn/await."
  @spec template(String.t()) :: String.t()
  def template(name) do
    """
    -- #{name}: describe what this workflow does
    local profile = "scout"
    local prompt = "Inspect the project and report its key modules and relevant tests."

    local result = tackle.await(tackle.spawn(profile, prompt))
    if not result.ok then return "Failed: " .. result.text end
    return result.text
    """
  end

  defp cwd(opts), do: opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()
  defp valid_name?(name), do: is_binary(name) and Regex.match?(@name_pattern, name)

  defp tackle_home(opts) do
    case Paths.home(env: Keyword.get_lazy(opts, :env, &System.get_env/0)) do
      {:ok, home} -> home
      {:error, _reason} -> nil
    end
  end

  # A jailed agent can write only the project directory.
  defp save_location(opts) do
    user =
      cond do
        ProjectFiles.new(opts).workspace -> nil
        home = tackle_home(opts) -> Path.join(home, "workflows")
        true -> "$TACKLE_HOME/workflows"
      end

    case Enum.reject([project_dir(opts), user], &is_nil/1) do
      [] -> ".tackle/workflows"
      locations -> Enum.join(locations, " or ")
    end
  end

  defp sources(files, opts),
    do: ProjectFiles.tackle_dirs(files, cwd(opts), tackle_home(opts), "workflows")

  defp load_directory(files, dir, source, {workflows, warnings} = acc) do
    case ProjectFiles.list_files(files, dir, ".lua") do
      {:ok, paths} ->
        Enum.reduce(paths, acc, &load_file(files, &1, source, &2))

      {:error, :enoent} ->
        acc

      {:error, reason} ->
        message = "could not list directory (#{ProjectFiles.format_error(reason)})"
        {workflows, [%{path: dir, message: message} | warnings]}
    end
  end

  defp load_file(files, path, source, {workflows, warnings}) do
    name = Path.basename(path, ".lua")

    with true <- valid_name?(name),
         {:ok, script} <- ProjectFiles.read_text(files, path) do
      {Map.put(workflows, name, workflow(name, path, source, script)), warnings}
    else
      false ->
        message = "name must use lowercase letters, numbers, and single hyphens"
        {workflows, [%{path: path, message: message} | warnings]}

      {:error, reason} ->
        message = "could not be read (#{ProjectFiles.format_error(reason)})"
        {workflows, [%{path: path, message: message} | warnings]}
    end
  end

  defp workflow(name, path, source, script),
    do: %Workflow{name: name, description: description(script), path: path, source: source}

  defp description(script) do
    case script |> String.split("\n", parts: 2) |> hd() |> String.trim_leading() do
      "--[[" <> _rest -> ""
      "--" <> text -> String.trim(text)
      _line -> ""
    end
  end
end
