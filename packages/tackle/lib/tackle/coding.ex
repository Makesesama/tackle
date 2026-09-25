defmodule Tackle.Coding do
  @moduledoc """
  Composition of a coding scope with declarative subagent profiles.

  The built-in scout, reviewer, and worker profiles are joined by profiles
  discovered from `$TACKLE_HOME/agents` and the nearest project
  `.tackle/agents` directory.
  Project profiles override user profiles, which override built-ins. Profile
  files may select only tools already available to the trusted root harness.
  """

  alias Tackle.Agents
  alias Tackle.Agents.Default
  alias Tackle.Agents.Definition
  alias Tackle.Config
  alias Tackle.Plugins.Catalog
  alias Tackle.Runtime.{AgentSpec, ScopeSpec}
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Tools.{Subagent, SubagentStatus, SubagentWait}

  @delegation """
  ## Delegation

  Use the subagent tool for bounded work that benefits from a fresh, focused
  context. Prefer foreground mode when the result is needed for the current
  task; it waits for the child automatically. Set `background` only to
  parallelize genuinely independent work. After delegating an assignment, do
  not perform that same assignment yourself. Continue only with clearly
  non-overlapping work, or call `subagent_wait` when there is nothing independent
  to do or the result is needed. Use `subagent_status` only to check or collect a
  run without waiting. Any terminal background outcome automatically queues a
  notice; it joins the active turn at its next safe boundary, or starts a
  continuation when the parent is idle. Choose only from the configured profiles
  below and give the child a self-contained assignment with the relevant context
  and expected deliverable. Child sessions are one-shot and share this workspace;
  keep a single writer, so the parent must not edit while a background child may
  be editing. Tool restrictions are capability limits, not an operating-system
  sandbox. Evaluate returned work before relying on it. At most two children can
  run at once; excess requests are rejected rather than queued.
  """

  @doc """
  Loads coding configuration and builds a scope with discovered subagents.

  `:root_tools` adds trusted tools to the root only; named profiles may opt in
  by explicitly listing those tools in their definition. A trusted `:catalog`
  selects adapters and hooks through `Tackle.Config`; only names listed in
  `:catalog_root_tools` grant catalog tools to the root. Catalog names cannot
  replace built-in coding tools. The host owns the lifecycle of any contributed
  tools and their connections.

  Agent files are validated at startup. Invalid files, unknown tools, and model
  selections unavailable through the configured adapters are explicit errors.
  Children have unlimited loop iterations by default and a five-minute timeout.
  Explicit root or profile iteration limits are still enforced. Scope limits
  allow the root plus two children.
  """
  @spec scope_spec(keyword(), SessionSpec.t() | nil) :: {:ok, ScopeSpec.t()} | {:error, term()}
  def scope_spec(loader_opts \\ [], session \\ nil) do
    with {:ok, catalog_tools} <- catalog_root_tools(loader_opts),
         {:ok, config} <-
           Config.load(Keyword.drop(loader_opts, [:root_tools, :catalog_root_tools])),
         :ok <- validate_root_tools(Keyword.get(loader_opts, :root_tools, [])),
         :ok <- validate_catalog_tool_conflicts(loader_opts, config),
         discovery <- discover(config, loader_opts),
         :ok <- validate_discovery(discovery),
         root_tools =
           Enum.uniq(
             config.tools ++
               Keyword.get(loader_opts, :root_tools, []) ++
               catalog_tools ++ [Subagent, SubagentStatus, SubagentWait]
           ),
         {:ok, profiles} <-
           build_profiles(discovery.definitions, config.tools, root_tools, loader_opts),
         {:ok, root_config} <- root_config(discovery.definitions, root_tools, loader_opts),
         {:ok, root_spec} <-
           AgentSpec.new(
             name: "root",
             config: root_config,
             allow_delegation: map_size(profiles) > 0
           ) do
      ScopeSpec.new(
        backend: Tackle.Runtime.RootBackend,
        root_spec: root_spec,
        session: session,
        limits: limits(discovery.definitions),
        profiles: profiles
      )
    end
  end

  defp validate_catalog_tool_conflicts(opts, config) do
    case Keyword.fetch(opts, :catalog) do
      {:ok, %Catalog{} = catalog} -> catalog_tool_conflicts(catalog, opts, config)
      :error -> :ok
    end
  end

  defp catalog_tool_conflicts(catalog, opts, config) do
    selected =
      config.tools ++
        Keyword.get(opts, :root_tools, []) ++ [Subagent, SubagentStatus, SubagentWait]

    catalog_modules = MapSet.new(Enum.map(Catalog.tools(catalog), & &1.module))
    selected_names = Map.new(selected, &{&1.name(), &1})

    Catalog.tools(catalog)
    |> Enum.find(&conflicting_catalog_tool?(&1, selected_names, catalog_modules))
    |> catalog_tool_conflict_result()
  end

  defp conflicting_catalog_tool?(%{module: module}, selected_names, catalog_modules) do
    other = Map.get(selected_names, module.name())
    other != nil and other != module and not MapSet.member?(catalog_modules, other)
  end

  defp catalog_tool_conflict_result(nil), do: :ok

  defp catalog_tool_conflict_result(%{module: module, source: source}) do
    {:error, {:catalog_tool_conflict, source, module.name()}}
  end

  defp catalog_root_tools(opts) do
    case {Keyword.fetch(opts, :catalog), Keyword.get(opts, :catalog_root_tools, [])} do
      {:error, []} ->
        {:ok, []}

      {:error, names} ->
        {:error, {:catalog_required_for_root_tools, names}}

      {{:ok, %Catalog{} = catalog}, names} ->
        with {:ok, entries} <- Catalog.resolve_tools(catalog, names) do
          {:ok, Enum.map(entries, & &1.module)}
        end

      {{:ok, value}, _names} ->
        {:error, {:invalid_option, :catalog, value}}
    end
  end

  defp validate_root_tools(tools) when is_list(tools) do
    if Enum.all?(tools, fn tool ->
         is_atom(tool) and Code.ensure_loaded?(tool) and
           function_exported?(tool, :name, 0) and function_exported?(tool, :execute, 2)
       end),
       do: :ok,
       else: {:error, :invalid_root_tools}
  end

  defp validate_root_tools(_), do: {:error, :invalid_root_tools}

  defp discover(config, loader_opts) do
    Agents.discover(
      cwd: config.context.cwd,
      env: Keyword.get_lazy(loader_opts, :env, &System.get_env/0),
      builtins: Default.definitions()
    )
  end

  defp validate_discovery(%{warnings: []}), do: :ok

  defp validate_discovery(%{warnings: warnings}) do
    {:error, {:invalid_agent_definitions, warnings}}
  end

  defp build_profiles(definitions, default_tools, trusted_tools, loader_opts) do
    Enum.reduce_while(definitions, {:ok, %{}}, fn definition, {:ok, profiles} ->
      case build_profile(definition, default_tools, trusted_tools, loader_opts) do
        {:ok, spec} -> {:cont, {:ok, Map.put(profiles, definition.name, spec)}}
        {:error, reason} -> {:halt, {:error, {:invalid_agent_profile, definition.path, reason}}}
      end
    end)
  end

  defp build_profile(definition, default_tools, trusted_tools, loader_opts) do
    with {:ok, tools} <- profile_tools(definition, default_tools, trusted_tools),
         {:ok, config} <- load_profile_config(definition, tools, loader_opts) do
      config = %{
        config
        | max_iterations: min_iterations(config.max_iterations, definition.max_iterations),
          llm_stream: false
      }

      AgentSpec.new(
        name: definition.name,
        config: config,
        allow_delegation: definition.allow_delegation,
        timeout: min(definition.timeout, :timer.minutes(5)),
        model_source: if(definition.model, do: :configured, else: :parent)
      )
    end
  end

  defp profile_tools(%Definition{tools: nil} = definition, default_tools, _trusted_tools) do
    tools =
      if definition.allow_delegation,
        do: append_tool(default_tools, Subagent),
        else: default_tools

    {:ok, Enum.uniq(tools)}
  end

  defp profile_tools(%Definition{tools: names} = definition, _default_tools, trusted_tools) do
    resolution_tools = Enum.uniq(trusted_tools ++ Tackle.Tools.default())

    with {:ok, tools} <- Tackle.Tools.resolve_names(names, resolution_tools) do
      tools =
        if definition.allow_delegation,
          do: append_tool(tools, Subagent),
          else: tools

      {:ok, Enum.uniq(tools)}
    end
  end

  defp append_tool(tools, tool) do
    Enum.reverse([tool | Enum.reverse(tools)])
  end

  defp load_profile_config(definition, tools, loader_opts) do
    prompt =
      [definition.prompt, parent_system_prompt(definition, loader_opts)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    profile_overrides =
      [tools: tools, system_prompt: prompt]
      |> maybe_put(:model, definition.model)
      |> maybe_put(:thinking, definition.thinking)

    load_with_overrides(loader_opts, profile_overrides)
  end

  defp parent_system_prompt(%Definition{source: :builtin}, loader_opts) do
    loader_opts |> Keyword.get(:overrides, []) |> Keyword.get(:system_prompt)
  end

  defp parent_system_prompt(_definition, _loader_opts), do: nil

  defp root_config(definitions, root_tools, loader_opts) do
    with {:ok, root_config} <- load_with_overrides(loader_opts, tools: root_tools) do
      prompt =
        [root_config.system_prompt, @delegation, Agents.format_for_prompt(definitions)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")

      {:ok, %{root_config | system_prompt: prompt}}
    end
  end

  defp load_with_overrides(opts, overrides) do
    merged = opts |> Keyword.get(:overrides, []) |> Keyword.merge(overrides)
    opts = Keyword.take(opts, [:available_adapters, :catalog, :cwd, :env])
    Config.load(Keyword.put(opts, :overrides, merged))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp min_iterations(:infinity, configured), do: configured
  defp min_iterations(value, :infinity), do: value
  defp min_iterations(value, configured), do: min(value, configured)

  defp limits(definitions) do
    max_spawn_depth = if Enum.any?(definitions, & &1.allow_delegation), do: 2, else: 1

    [
      max_agents_per_fleet: 3,
      max_concurrent_turns: 3,
      max_children_per_agent: 2,
      max_spawn_depth: max_spawn_depth,
      run_timeout: :timer.minutes(5)
    ]
  end
end
