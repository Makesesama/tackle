defmodule Tackle.Config.Sources do
  @moduledoc """
  Everything a `Tackle.Config` is built from, read once.

  `read/1` takes the options of `Tackle.Config.load/1` and reads the sources
  they name: the environment, the working directory, `$TACKLE_HOME/config.json`
  and the project's `.tackle/config.json`, the recorded accounts, the skills,
  and the system prompt files (`SYSTEM.md`, `APPEND_SYSTEM.md`, `AGENTS.md`).
  `Tackle.Config.from_sources/2` then builds configurations from them without
  reading anything, so a host that builds several configurations for one
  workspace, such as `Tackle.Coding.scope_spec/2` for the root and every
  subagent profile, reads each source once.

  Workspace files are read through the executor of the `:overrides` context,
  which is validated before anything is read. With `instructions: false`,
  neither the instruction files (`APPEND_SYSTEM.md`, `AGENTS.md`) nor the
  skills are read. A prompt file that cannot be read fails only the
  configurations whose prompt uses it, and skill files that are skipped are
  logged once, here.

  The fields are the read sources; build configurations with
  `Tackle.Config.from_sources/2` rather than reading them.
  """

  require Logger

  alias Tackle.Config.File, as: ConfigFile
  alias Tackle.Config.Options
  alias Tackle.Executor
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Plugins.Catalog
  alias Tackle.ProjectFiles
  alias Tackle.Skills
  alias Tackle.Skills.Skill
  alias Tackle.SystemPrompt

  @option_keys [
    :accounts,
    :available_adapters,
    :builtin_skills,
    :catalog,
    :cwd,
    :env,
    :instructions,
    :overrides
  ]

  @project_config_file ".tackle/config.json"

  @enforce_keys [:env, :cwd, :home, :providers, :file_options, :layers, :overrides]
  defstruct [
    :env,
    :cwd,
    :home,
    :providers,
    :file_options,
    :layers,
    :overrides,
    catalog_hooks: nil,
    instructions: true,
    skills: [],
    prompt_files: %{system: {:ok, nil}, append: {:ok, nil}, context_files: {:ok, []}}
  ]

  @type t :: %__MODULE__{
          env: %{optional(String.t()) => String.t()},
          cwd: Path.t(),
          home: Path.t(),
          providers: [Provider.t()],
          file_options: keyword(),
          layers: [{Path.t(), keyword()}],
          overrides: keyword(),
          catalog_hooks: [module()] | nil,
          instructions: boolean(),
          skills: [Skill.t()],
          prompt_files: SystemPrompt.files()
        }

  @doc "The options `read/1` and `Tackle.Config.load/1` accept."
  @spec option_keys() :: [atom()]
  def option_keys, do: @option_keys

  @doc """
  Reads the sources named by `Tackle.Config.load/1`'s options; see that
  function for the options and their errors.
  """
  @spec read(keyword()) :: {:ok, t()} | {:error, term()}
  def read(opts) do
    with :ok <-
           Options.validate_list(
             opts,
             @option_keys,
             {:invalid_loader_options, :duplicate_loader_option, :unknown_loader_options}
           ),
         {:ok, overrides} <- fetch_overrides(opts),
         :ok <- validate_override_context(overrides),
         {:ok, adapters} <- fetch_available_adapters(opts),
         {:ok, accounts} <- fetch_accounts(opts),
         {:ok, builtin_skills} <- fetch_builtin_skills(opts),
         {:ok, instructions} <- fetch_instructions(opts),
         {:ok, catalog_hooks} <- fetch_catalog_hooks(opts, overrides),
         {:ok, env} <- fetch_environment(opts),
         context = Keyword.get(overrides, :context, %{}),
         executor = Executor.from_context(context),
         {:ok, cwd} <- fetch_cwd(opts, context),
         {:ok, config_path} <- Tackle.Paths.config_file(env: env),
         home = Path.dirname(config_path),
         {:ok, project_file} <- read_project_config(cwd, executor, home),
         {:ok, file_opts, layers} <- ConfigFile.load(config_path, project_file),
         {declared, file_opts} = Keyword.pop(file_opts, :providers, %{}),
         {:ok, entries} <-
           Tackle.Plugins.provider_entries(
             adapters: adapters,
             accounts: accounts,
             config_providers: declared
           ),
         {:ok, prompt_files} <-
           SystemPrompt.read(
             cwd: cwd,
             home: home,
             executor: executor,
             instructions: instructions
           ) do
      {:ok,
       %__MODULE__{
         env: env,
         cwd: cwd,
         home: home,
         providers: Enum.map(entries, & &1.provider),
         file_options: file_opts,
         layers: layers,
         overrides: overrides,
         catalog_hooks: catalog_hooks,
         instructions: instructions,
         skills:
           if(instructions, do: discover_skills(cwd, env, executor, builtin_skills), else: []),
         prompt_files: prompt_files
       }}
    end
  end

  @doc """
  Checks overrides given in addition to the sources' own: a keyword list
  that sets neither `:providers` (which come from the sources) nor
  `:context` (whose executor the sources were read through), nor `:hooks`
  when a catalog selected them.
  """
  @spec validate_overrides(t(), term()) :: :ok | {:error, term()}
  def validate_overrides(%__MODULE__{} = sources, overrides) do
    cond do
      not Keyword.keyword?(overrides) -> {:error, {:invalid_option, :overrides, overrides}}
      Keyword.has_key?(overrides, :providers) -> {:error, {:reserved_override, :providers}}
      Keyword.has_key?(overrides, :context) -> {:error, {:reserved_override, :context}}
      sources.catalog_hooks && Keyword.has_key?(overrides, :hooks) -> conflicting_hooks()
      true -> :ok
    end
  end

  defp fetch_overrides(opts) do
    overrides = Keyword.get(opts, :overrides, [])

    cond do
      not Keyword.keyword?(overrides) -> {:error, {:invalid_option, :overrides, overrides}}
      Keyword.has_key?(overrides, :providers) -> {:error, {:reserved_override, :providers}}
      true -> {:ok, overrides}
    end
  end

  # The project file and instruction files are read through the context's
  # executor, so it is validated before anything is read: a malformed one must
  # not fall back to reading the workspace unjailed.
  defp validate_override_context(overrides) do
    case Keyword.fetch(overrides, :context) do
      {:ok, context} -> Options.validate_context(context)
      :error -> :ok
    end
  end

  defp fetch_available_adapters(opts) do
    case {Keyword.fetch(opts, :catalog), Keyword.fetch(opts, :available_adapters)} do
      {{:ok, %Catalog{adapters: []}}, :error} -> {:error, :no_adapters_configured}
      {{:ok, %Catalog{} = catalog}, :error} -> {:ok, Catalog.adapter_modules(catalog)}
      {{:ok, %Catalog{}}, {:ok, _}} -> {:error, :conflicting_adapter_sources}
      {{:ok, value}, _} -> {:error, {:invalid_option, :catalog, value}}
      {:error, {:ok, adapters}} when is_list(adapters) and adapters != [] -> {:ok, adapters}
      {:error, {:ok, adapters}} -> {:error, {:invalid_option, :available_adapters, adapters}}
      {:error, :error} -> Tackle.Plugins.available_adapters()
    end
  end

  defp fetch_accounts(opts) do
    case Keyword.fetch(opts, :accounts) do
      {:ok, %{} = accounts} -> {:ok, accounts}
      {:ok, accounts} -> {:error, {:invalid_option, :accounts, accounts}}
      :error -> stored_accounts()
    end
  end

  defp stored_accounts do
    case Tackle.Auth.accounts() do
      {:ok, accounts} -> {:ok, accounts}
      {:error, reason} -> {:error, {:accounts_unavailable, reason}}
    end
  catch
    :exit, reason -> {:error, {:accounts_unavailable, reason}}
  end

  defp fetch_catalog_hooks(opts, overrides) do
    case Keyword.fetch(opts, :catalog) do
      {:ok, %Catalog{} = catalog} ->
        if Keyword.has_key?(overrides, :hooks),
          do: conflicting_hooks(),
          else: {:ok, Catalog.hook_modules(catalog)}

      {:ok, value} ->
        {:error, {:invalid_option, :catalog, value}}

      :error ->
        {:ok, nil}
    end
  end

  defp conflicting_hooks, do: {:error, :conflicting_hook_sources}

  defp fetch_environment(opts) do
    case Keyword.get_lazy(opts, :env, &System.get_env/0) do
      %{} = env -> {:ok, env}
      env -> {:error, {:invalid_option, :env, env}}
    end
  end

  defp fetch_cwd(opts, context) do
    case Keyword.fetch(opts, :cwd) do
      {:ok, cwd} -> normalize_cwd(cwd)
      :error -> context |> context_cwd() |> normalize_cwd()
    end
  end

  defp context_cwd(%{cwd: cwd}), do: cwd
  defp context_cwd(%{"cwd" => cwd}), do: cwd
  defp context_cwd(_context), do: File.cwd()

  defp normalize_cwd({:ok, cwd}), do: normalize_cwd(cwd)
  defp normalize_cwd({:error, reason}), do: {:error, {:cwd_unavailable, reason}}
  defp normalize_cwd(cwd) when is_binary(cwd), do: validate_cwd(Path.expand(cwd))
  defp normalize_cwd(cwd), do: {:error, {:invalid_option, :cwd, cwd}}

  defp validate_cwd(cwd) do
    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, {:invalid_option, :cwd, cwd}}
  end

  # The project file lives in the workspace, so it is read through the session
  # executor like `AGENTS.md`. Outside any Git repository the search can reach
  # `$TACKLE_HOME` itself, whose config.json is the user file, not a project.
  defp read_project_config(cwd, executor, home) do
    files = ProjectFiles.new(executor: executor)

    case ProjectFiles.nearest_project_file(files, cwd, @project_config_file) do
      nil ->
        {:ok, nil}

      path ->
        if ProjectFiles.same_dir?(Path.dirname(path), home),
          do: {:ok, nil},
          else: read_project_file(files, path)
    end
  end

  defp read_project_file(files, path) do
    case ProjectFiles.read(files, path) do
      {:ok, contents} -> {:ok, {path, contents}}
      {:error, reason} -> {:error, {:config_file, path, {:unreadable, reason}}}
    end
  end

  defp fetch_instructions(opts) do
    case Keyword.get(opts, :instructions, true) do
      instructions when is_boolean(instructions) -> {:ok, instructions}
      other -> {:error, {:invalid_option, :instructions, other}}
    end
  end

  defp fetch_builtin_skills(opts) do
    skills = Keyword.get(opts, :builtin_skills, [])

    cond do
      not is_list(skills) or not Enum.all?(skills, &valid_builtin_skill?/1) ->
        {:error, {:invalid_option, :builtin_skills, skills}}

      length(Enum.uniq_by(skills, & &1.name)) != length(skills) ->
        {:error, {:duplicate_builtin_skills, skills |> Enum.map(& &1.name) |> duplicates()}}

      true ->
        {:ok, skills}
    end
  end

  # Built-in skills normally come from `Tackle.Skills.builtin/2`; this guards
  # hand-built structs that would otherwise fail later, inside the session.
  defp valid_builtin_skill?(%Skill{
         source: :builtin,
         name: name,
         description: description,
         content: content,
         requires_tools: requires_tools
       }) do
    Enum.all?([name, description, content], &(is_binary(&1) and &1 != "")) and
      is_list(requires_tools) and Enum.all?(requires_tools, &(is_binary(&1) and &1 != ""))
  end

  defp valid_builtin_skill?(_skill), do: false

  defp duplicates(names) do
    names |> Enum.frequencies() |> Enum.filter(&(elem(&1, 1) > 1)) |> Enum.map(&elem(&1, 0))
  end

  defp discover_skills(cwd, env, executor, builtins) do
    user_home = Map.get(env, "HOME") || Map.get(env, "USERPROFILE")

    discovery =
      Skills.discover(
        cwd: cwd,
        user_home: user_home,
        executor: executor,
        builtins: builtins
      )

    Enum.each(discovery.warnings, fn %{path: path, message: message} ->
      Logger.warning("skipping or adjusting skill #{path}: #{message}")
    end)

    discovery.skills
  end
end
