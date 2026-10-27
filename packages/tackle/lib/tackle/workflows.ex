defmodule Tackle.Workflows do
  @moduledoc """
  Saved, self-contained Lua workflows co-authored with the user.

  Files live in `$TACKLE_HOME/workflows` and the nearest `.tackle/workflows`
  at or above the working directory, within the bounds of
  `Tackle.ProjectFiles.ancestors/3`. Discovery is flat; project files override
  user files by name. There are no parameters or approval gates: configuration
  belongs in locals inside the script.

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
        with {:ok, script} <- read_script(files, path) do
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
          {:error, "Could not read workflow #{inspect(name)}: #{read_reason(reason)}"}
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
  Returns the nearest existing project `.tackle/workflows`, or `<cwd>/.tackle/workflows`.

  Does not create directories. Accepts the discovery options.
  """
  @spec project_dir([option()]) :: Path.t()
  def project_dir(opts \\ []) do
    ProjectFiles.nearest_project_dir(ProjectFiles.new(opts), cwd(opts), ".tackle/workflows") ||
      Path.join(cwd(opts), ".tackle/workflows")
  end

  @doc """
  Creates a named project workflow, including missing directories, exclusively.

  Names use lowercase letters, numbers, and single hyphens. Returns `{:ok, path}`,
  `{:error, :invalid_name}`, or a write error (`:eexist` if already present).
  A user workflow with the same name does not prevent project creation.
  Accepts the discovery options; creation is always exclusive.
  """
  @spec create(String.t(), String.t(), [option()]) ::
          {:ok, Path.t()} | {:error, Executor.reason()}
  def create(name, script, opts \\ []) do
    if valid_name?(name) do
      path = Path.join(project_dir(opts), name <> ".lua")

      case save(path, script, Keyword.merge(opts, mode: :create, mkdir_p: true)) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_name}
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

  defp user_dir(opts) do
    case Paths.home(env: Keyword.get_lazy(opts, :env, &System.get_env/0)) do
      {:ok, home} -> Path.join(home, "workflows")
      {:error, _reason} -> nil
    end
  end

  defp save_location(opts) do
    project = project_dir(opts)

    if ProjectFiles.new(opts).workspace do
      project
    else
      project <> " or " <> (user_dir(opts) || "$TACKLE_HOME/workflows")
    end
  end

  defp sources(files, opts) do
    project = ProjectFiles.nearest_project_dir(files, cwd(opts), ".tackle/workflows")
    user = user_dir(opts)
    if(user, do: [{:user, user}], else: []) ++ if(project, do: [{:project, project}], else: [])
  end

  defp load_directory(files, dir, source, {workflows, warnings} = acc) do
    case ProjectFiles.list(files, dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".lua"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&ProjectFiles.regular?(files, &1))
        |> Enum.reduce(acc, &load_file(files, &1, source, &2))

      {:error, :enoent} ->
        acc

      {:error, reason} ->
        message = "could not list directory (#{Executor.format_reason(reason)})"
        {workflows, [%{path: dir, message: message} | warnings]}
    end
  end

  defp load_file(files, path, source, {workflows, warnings}) do
    name = Path.basename(path, ".lua")

    with true <- valid_name?(name),
         {:ok, script} <- read_script(files, path) do
      {Map.put(workflows, name, workflow(name, path, source, script)), warnings}
    else
      false ->
        message = "name must use lowercase letters, numbers, and single hyphens"
        {workflows, [%{path: path, message: message} | warnings]}

      {:error, reason} ->
        message = "could not be read (#{read_reason(reason)})"
        {workflows, [%{path: path, message: message} | warnings]}
    end
  end

  defp workflow(name, path, source, script),
    do: %Workflow{name: name, description: description(script), path: path, source: source}

  defp read_script(files, path) do
    with {:ok, script} <- ProjectFiles.read(files, path) do
      if String.valid?(script), do: {:ok, script}, else: {:error, :invalid_utf8}
    end
  end

  defp read_reason(:invalid_utf8), do: "file is not valid UTF-8"
  defp read_reason(reason), do: Executor.format_reason(reason)

  defp description(script) do
    case script |> String.split("\n", parts: 2) |> hd() |> String.trim_leading() do
      "--[[" <> _rest -> ""
      "--" <> text -> String.trim(text)
      _line -> ""
    end
  end
end
