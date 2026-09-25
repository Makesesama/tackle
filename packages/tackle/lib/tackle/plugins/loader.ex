defmodule Tackle.Plugins.Loader do
  @moduledoc """
  Startup-only loader for explicitly enabled, precompiled Mix projects.

  Reads `$TACKLE_HOME/plugins.json` (or an explicit `:path`) and never invokes
  Mix or evaluates project files. Each project names its OTP application and
  must have a production build under `_build/prod/lib`. Preflight completes
  for every project before any code path is changed. Loading is startup-only
  and intentionally has no rollback if activation fails.

  A missing configuration file means no user plugins are enabled.
  """

  alias Tackle.Plugins.Catalog

  @kinds ["adapters", "tools", "hooks"]
  @module_name ~r/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/
  @app_name ~r/\A[a-z][a-z0-9_]*\z/

  @doc "Loads explicitly enabled project contributions into a validated catalog-shaped map."
  @spec load(keyword()) ::
          {:ok,
           %{adapters: [Catalog.entry()], tools: [Catalog.entry()], hooks: [Catalog.entry()]}}
          | {:error, term()}
  def load(opts \\ [])

  def load(opts) when is_list(opts) do
    with {:ok, path} <- config_path(opts),
         {:ok, config} <- read_config(path),
         {:ok, projects} <- validate_config(config),
         {:ok, plans} <- preflight(projects),
         :ok <- check_all_plans(plans),
         :ok <- add_code_paths(plans),
         :ok <- start_apps(plans),
         {:ok, contributions} <- load_modules(plans),
         {:ok, catalog} <- Catalog.new(Map.to_list(contributions)) do
      {:ok,
       %{
         adapters: Catalog.adapters(catalog),
         tools: Catalog.tools(catalog),
         hooks: Catalog.hooks(catalog)
       }}
    end
  end

  def load(opts), do: {:error, {:invalid_loader_options, opts}}

  defp config_path(opts) when is_list(opts) do
    if not Keyword.keyword?(opts) or Keyword.keys(opts) -- [:path, :env] != [] do
      {:error, {:invalid_loader_options, opts}}
    else
      resolve_config_path(opts)
    end
  end

  defp resolve_config_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" ->
        {:ok, path}

      {:ok, value} ->
        {:error, {:invalid_config_path, value}}

      :error ->
        opts
        |> Keyword.get_lazy(:env, &System.get_env/0)
        |> config_path_from_env()
    end
  end

  defp config_path_from_env(env) when is_map(env) do
    with {:ok, home} <- Tackle.Paths.home(env: env),
         do: {:ok, Path.join(home, "plugins.json")}
  end

  defp config_path_from_env(env), do: {:error, {:invalid_loader_environment, env}}

  defp read_config(path) do
    case File.read(path) do
      {:ok, contents} ->
        case JSON.decode(contents) do
          {:ok, config} -> {:ok, config}
          {:error, reason} -> {:error, {:invalid_plugin_config_json, path, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{"version" => 1, "projects" => []}}

      {:error, reason} ->
        {:error, {:plugin_config_read_failed, path, reason}}
    end
  end

  defp validate_config(%{"version" => 1, "projects" => projects} = config)
       when map_size(config) == 2 and is_list(projects) do
    Enum.reduce_while(projects, {:ok, []}, fn project, {:ok, acc} ->
      case validate_project(project) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projects} -> {:ok, Enum.reverse(projects)}
      error -> error
    end
  end

  defp validate_config(value), do: {:error, {:invalid_plugin_config, value}}

  defp validate_project(%{"path" => path, "app" => app} = project)
       when is_binary(path) and is_binary(app) do
    if map_size(project) == 5 and Path.type(path) == :absolute and
         Regex.match?(@app_name, app) and
         Enum.sort(Map.keys(project)) == Enum.sort(["path", "app" | @kinds]) and
         Enum.all?(
           @kinds,
           &(is_list(Map.get(project, &1)) and
               Enum.all?(Map.get(project, &1), fn m ->
                 is_binary(m) and Regex.match?(@module_name, m)
               end))
         ) do
      {:ok,
       %{
         path: Path.expand(path),
         app: app,
         modules: Map.new(@kinds, &{kind_atom(&1), Map.get(project, &1)})
       }}
    else
      {:error, {:invalid_plugin_project, project}}
    end
  end

  defp validate_project(value), do: {:error, {:invalid_plugin_project, value}}
  defp kind_atom("adapters"), do: :adapters
  defp kind_atom("tools"), do: :tools
  defp kind_atom("hooks"), do: :hooks

  defp preflight(projects) do
    if duplicate(Enum.map(projects, & &1.path)) do
      {:error, {:duplicate_plugin_project, duplicate(Enum.map(projects, & &1.path))}}
    else
      collect_plans(projects)
    end
  end

  defp collect_plans(projects) do
    result =
      Enum.reduce_while(projects, {:ok, []}, fn project, {:ok, acc} ->
        case project_plan(project) do
          {:ok, plan} -> {:cont, {:ok, [plan | acc]}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      error -> error
    end
  end

  defp check_beams(beams, root) do
    case Enum.find_value(beams, &invalid_beam/1) do
      nil -> :ok
      failure -> {:error, {:invalid_plugin_beam, root, failure}}
    end
  end

  defp invalid_beam(beam) do
    case :beam_lib.info(String.to_charlist(beam)) do
      info when is_list(info) -> nil
      error -> {beam, error}
    end
  end

  defp project_plan(%{path: root, app: app_name, modules: requested}) do
    apps = Path.wildcard(Path.join(root, "_build/prod/lib/*/ebin/*.app"))
    beams = Path.wildcard(Path.join(root, "_build/prod/lib/*/ebin/*.beam"))

    names = requested |> Map.values() |> List.flatten() |> Enum.uniq()

    with :ok <- require_project(root),
         :ok <- check_beams(beams, root),
         ownership = beam_ownership(beams),
         {:ok, app, ebin} <- project_app(apps, app_name),
         {:ok, app_specs} <- app_specs(apps, root),
         {:ok, private_apps} <- private_apps(app_specs, app, root),
         :ok <- owned_modules(names, ownership),
         :ok <- selected_owned_by_app(names, ownership, ebin, root),
         :ok <- selected_listed_in_app(names, app_specs, app, root),
         :ok <- preflight_apps(private_apps, root),
         :ok <- validate_app_beams(private_apps, root) do
      {:ok,
       %{
         root: root,
         app: app,
         ebin: ebin,
         paths: Enum.map(private_apps, & &1.ebin),
         apps: private_apps,
         modules: requested,
         ownership: ownership
       }}
    end
  end

  defp beam_ownership(beams) do
    Enum.reduce(beams, %{}, fn beam, acc ->
      module = :beam_lib.info(String.to_charlist(beam)) |> Keyword.fetch!(:module)
      Map.update(acc, Atom.to_string(module), beam, fn _ -> :duplicate end)
    end)
  end

  defp owned_modules(names, ownership) do
    case Enum.find(names, fn name ->
           not Map.has_key?(ownership, "Elixir." <> name) or
             ownership["Elixir." <> name] == :duplicate
         end) do
      nil -> :ok
      name -> {:error, {:plugin_module_not_owned_by_build, name}}
    end
  end

  defp require_project(root) do
    cond do
      not File.regular?(Path.join(root, "mix.exs")) -> {:error, {:not_a_mix_project, root}}
      not File.dir?(Path.join(root, "_build/prod/lib")) -> {:error, {:plugin_build_missing, root}}
      true -> :ok
    end
  end

  defp project_app(app_files, source_app) do
    candidates =
      Enum.flat_map(app_files, fn file ->
        with {:ok, [{:application, app, _props}]} <- :file.consult(String.to_charlist(file)),
             true <- is_atom(app) and Atom.to_string(app) == source_app,
             ebin <- Path.dirname(file) do
          [{app, ebin}]
        else
          _ -> []
        end
      end)

    case candidates do
      [candidate] -> {:ok, elem(candidate, 0), elem(candidate, 1)}
      [] -> {:error, {:plugin_project_app_not_found_or_ambiguous, app_files}}
      _ -> {:error, {:ambiguous_plugin_project_app, Enum.map(candidates, &elem(&1, 0))}}
    end
  end

  defp selected_owned_by_app(names, ownership, ebin, root) do
    case Enum.find(names, &(Path.dirname(ownership["Elixir." <> &1]) != ebin)) do
      nil -> :ok
      name -> {:error, {:plugin_module_not_owned_by_app, root, name}}
    end
  end

  defp selected_listed_in_app(names, specs, app, root) do
    listed = Enum.find(specs, &(&1.app == app)).modules |> Enum.map(&Atom.to_string/1)

    case Enum.find(names, &(("Elixir." <> &1) not in listed)) do
      nil -> :ok
      name -> {:error, {:plugin_module_not_listed_in_app, root, name}}
    end
  end

  defp app_specs(files, root) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, specs} ->
      case app_spec(file, root) do
        {:ok, spec} -> {:cont, {:ok, [spec | specs]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      error -> error
    end
  end

  defp app_spec(file, root) do
    case :file.consult(String.to_charlist(file)) do
      {:ok, [{:application, app, props}]} when is_atom(app) and is_list(props) ->
        build_app_spec(file, root, app, props)

      _ ->
        {:error, {:invalid_plugin_app, root, file}}
    end
  end

  defp build_app_spec(file, root, app, props) do
    modules = Keyword.get(props, :modules, [])
    deps = Keyword.get(props, :applications, [])
    vsn = Keyword.get(props, :vsn)

    if Path.basename(file) == Atom.to_string(app) <> ".app" and
         is_list(modules) and Enum.all?(modules, &is_atom/1) and
         is_list(deps) and Enum.all?(deps, &is_atom/1) and is_list(vsn) do
      {:ok, %{app: app, ebin: Path.dirname(file), modules: modules, deps: deps, vsn: vsn}}
    else
      {:error, {:invalid_plugin_app, root, file}}
    end
  end

  defp private_apps(specs, root_app, root) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, acc} ->
      case private_app(spec, root_app, root) do
        :private -> {:cont, {:ok, [spec | acc]}}
        :shared -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp private_app(spec, root_app, root) do
    case :code.lib_dir(spec.app) do
      {:error, :bad_name} -> :private
      _path when spec.app == root_app -> {:error, {:plugin_app_conflict, root, spec.app}}
      _path -> shared_app(spec, root)
    end
  end

  defp shared_app(spec, root) do
    case Application.spec(spec.app, :vsn) do
      vsn when vsn == spec.vsn ->
        check_shared_modules(spec, root)

      other ->
        {:error, {:plugin_dependency_version_conflict, root, spec.app, spec.vsn, other}}
    end
  end

  defp check_shared_modules(spec, root) do
    case Enum.find(spec.modules, &shared_module_conflict?(&1, spec.ebin)) do
      nil -> :shared
      module -> {:error, {:plugin_dependency_module_conflict, root, spec.app, module}}
    end
  end

  defp shared_module_conflict?(module, ebin) do
    built = Path.join(ebin, Atom.to_string(module) <> ".beam")

    case :code.which(module) do
      path when is_list(path) -> beam_files_differ?(built, List.to_string(path))
      _ -> true
    end
  end

  defp beam_files_differ?(built, runtime) do
    case {File.read(built), File.read(runtime)} do
      {{:ok, build_bytes}, {:ok, runtime_bytes}} -> build_bytes != runtime_bytes
      _ -> true
    end
  end

  defp validate_app_beams(specs, root) do
    case Enum.find_value(specs, &missing_app_beam/1) do
      nil -> :ok
      module -> {:error, {:plugin_app_beam_missing, root, module}}
    end
  end

  defp missing_app_beam(spec) do
    Enum.find(spec.modules, fn module ->
      not File.regular?(Path.join(spec.ebin, Atom.to_string(module) <> ".beam"))
    end)
  end

  defp check_all_plans(plans) do
    apps = Enum.flat_map(plans, & &1.apps)
    names = Enum.map(apps, & &1.app)
    modules = Enum.flat_map(apps, & &1.modules)

    cond do
      duplicate(names) -> {:error, {:duplicate_plugin_app, duplicate(names)}}
      duplicate(modules) -> {:error, {:duplicate_plugin_module, duplicate(modules)}}
      true -> check_dependencies(apps)
    end
  end

  defp check_dependencies(apps) do
    names = Enum.map(apps, & &1.app)

    case Enum.find_value(apps, &missing_dependency(&1, names)) do
      nil -> :ok
      missing -> {:error, {:plugin_dependency_missing, missing}}
    end
  end

  defp missing_dependency(spec, names) do
    case Enum.find(spec.deps, &(&1 not in names and :code.lib_dir(&1) == {:error, :bad_name})) do
      nil -> nil
      dep -> {spec.app, dep}
    end
  end

  defp preflight_apps(apps, root) do
    names = Enum.map(apps, & &1.app)
    modules = Enum.flat_map(apps, & &1.modules)
    loaded = Application.loaded_applications() |> Enum.map(&elem(&1, 0))

    cond do
      duplicate(names) ->
        {:error, {:duplicate_plugin_app, root, duplicate(names)}}

      duplicate(modules) ->
        {:error, {:duplicate_plugin_module, root, duplicate(modules)}}

      conflict =
          Enum.find(apps, &(&1.app in loaded or :code.lib_dir(&1.app) != {:error, :bad_name})) ->
        {:error, {:plugin_app_conflict, root, conflict.app}}

      conflict = Enum.find(modules, &(:code.which(&1) != :non_existing)) ->
        {:error, {:plugin_module_conflict, root, conflict}}

      true ->
        :ok
    end
  end

  defp duplicate(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value), do: {:halt, value}, else: {:cont, MapSet.put(seen, value)}
    end)
    |> case do
      %MapSet{} -> nil
      value -> value
    end
  end

  defp add_code_paths(plans) do
    plans
    |> Enum.flat_map(& &1.paths)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case :code.add_pathz(String.to_charlist(path)) do
        true -> {:cont, :ok}
        _ -> {:halt, {:error, {:plugin_code_path_failed, path}}}
      end
    end)
  end

  defp start_apps(plans) do
    apps = Enum.flat_map(plans, fn plan -> Enum.map(plan.apps, & &1.app) end)

    case load_private_apps(apps) do
      :ok -> start_root_apps(plans)
      error -> error
    end
  end

  defp load_private_apps(apps) do
    Enum.reduce_while(apps, :ok, fn app, :ok ->
      case Application.load(app) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:plugin_app_load_failed, app, reason}}}
      end
    end)
  end

  defp start_root_apps(plans) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      case Application.ensure_all_started(plan.app) do
        {:ok, _apps} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:plugin_app_start_failed, plan.root, plan.app, reason}}}
      end
    end)
  end

  defp load_modules(plans) do
    initial = %{adapters: [], tools: [], hooks: []}

    case Enum.reduce_while(plans, {:ok, initial}, &load_project_modules/2) do
      {:ok, entries} ->
        {:ok, Map.new(entries, fn {kind, reversed} -> {kind, Enum.reverse(reversed)} end)}

      error ->
        error
    end
  end

  defp load_project_modules(plan, {:ok, acc}) do
    plan.modules
    |> Enum.reduce_while({:ok, acc}, fn {kind, names}, {:ok, acc} ->
      case load_kind_modules(names, kind, plan.root, acc) do
        {:ok, value} -> {:cont, {:ok, value}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, value} -> {:cont, {:ok, value}}
      error -> {:halt, error}
    end
  end

  defp load_kind_modules(names, kind, root, acc) do
    Enum.reduce_while(names, {:ok, acc}, fn name, {:ok, acc} ->
      case load_selected_module(name, root) do
        {:ok, entry} -> {:cont, {:ok, Map.update!(acc, kind, &[entry | &1])}}
        error -> {:halt, error}
      end
    end)
  end

  defp load_selected_module(name, root) do
    module = String.to_existing_atom("Elixir." <> name)

    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, %{module: module, source: {:project, root}}}
      other -> {:error, {:plugin_module_load_failed, name, other}}
    end
  end
end
