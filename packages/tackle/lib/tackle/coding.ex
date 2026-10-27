defmodule Tackle.Coding do
  @moduledoc """
  Composition of a coding scope with declarative subagent profiles.

  The built-in scout, reviewer, and worker profiles, and the code review
  stages `review-detector` and `review-verifier` (used by `Tackle.Review`,
  not advertised to the root), are joined by profiles discovered from
  `$TACKLE_HOME/agents` and the nearest project `.tackle/agents` directory.
  Project profiles override user profiles, which override built-ins. The
  `agents` object of `config.json` or the project's `.tackle/config.json`
  (`Tackle.Config`) then replaces a profile's `model` and `thinking` by name;
  names without a discovered profile are ignored. Profile
  files may select only tools already available to the trusted root harness,
  plus the review output tools of `Tackle.Tools.review/0`.
  """

  alias Tackle.Agents
  alias Tackle.Agents.Default
  alias Tackle.Agents.Definition
  alias Tackle.Config
  alias Tackle.Config.Sources
  alias Tackle.Executor
  alias Tackle.Lib.Tool
  alias Tackle.Plugins.Catalog
  alias Tackle.Runtime.{AgentSpec, ScopeSpec}
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Tools.{Subagent, SubagentCancel, SubagentStatus, SubagentWait}

  @delegation """
  ## Delegation

  Use the subagent tool for bounded work that benefits from a fresh, focused
  context. Prefer foreground mode when the result is needed for the current
  task; it waits for the child automatically. Set `background` only to
  parallelize genuinely independent work. After delegating an assignment, do
  not perform that same assignment yourself. Continue only with clearly
  non-overlapping work, or call `subagent_wait` when there is nothing independent
  to do or the result is needed. Use `subagent_status` only to check or collect a
  run without waiting, and `subagent_cancel` to stop a run that is no longer
  needed. Any terminal background outcome automatically queues a
  notice; it joins the active turn at its next safe boundary, or starts a
  continuation when the parent is idle. Choose only from the configured profiles
  below and give the child a self-contained assignment with the relevant context
  and expected deliverable. Child sessions are one-shot and share this workspace;
  keep a single writer, so the parent must not edit while a background child may
  be editing. Tool restrictions are capability limits, not an operating-system
  sandbox. Evaluate returned work before relying on it. At most four children can
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

  Skills, including `:builtin_skills` (see `Tackle.Config.load/1`), apply to
  the root and every profile. Each agent is offered only the skills whose
  required tools it has, so a skill for a root-only tool stays out of child
  prompts; an agent offered any skill also gets the `load_skill` tool.
  Profiles with `instructions: false` (`Tackle.Agents.Definition`), such as
  the built-in review stages, get neither skills nor the instruction files:
  their system prompt is their own prompt and the working directory.

  Agent files are validated at startup. Invalid files, unknown tools, and model
  selections unavailable through the configured providers are explicit errors.
  Children have unlimited loop iterations by default and a five-minute inactivity timeout.
  Explicit root or profile iteration limits are still enforced. Scope limits
  allow the root plus four children.
  """
  @spec scope_spec(keyword(), SessionSpec.t() | nil) :: {:ok, ScopeSpec.t()} | {:error, term()}
  def scope_spec(loader_opts \\ [], session \\ nil) do
    with {:ok, catalog_tools} <- catalog_root_tools(loader_opts),
         {:ok, sources} <-
           Sources.read(Keyword.drop(loader_opts, [:root_tools, :catalog_root_tools])),
         {:ok, config} <- Config.from_sources(sources),
         :ok <- validate_root_tools(Keyword.get(loader_opts, :root_tools, [])),
         :ok <- validate_catalog_tool_conflicts(loader_opts, config),
         discovery <- discover(config, sources),
         :ok <- validate_discovery(discovery),
         root_tools =
           Enum.uniq(
             config.tools ++
               Keyword.get(loader_opts, :root_tools, []) ++
               catalog_tools ++ [Subagent, SubagentStatus, SubagentWait, SubagentCancel]
           ),
         {:ok, profiles} <-
           discovery.definitions
           |> Enum.map(&apply_agent_settings(&1, config.agents))
           |> build_profiles(config.tools, root_tools, sources),
         {:ok, root_config} <- root_config(discovery.definitions, root_tools, sources),
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
        Keyword.get(opts, :root_tools, []) ++
        [Subagent, SubagentStatus, SubagentWait, SubagentCancel]

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
    if Enum.all?(tools, &Tool.tool?/1), do: :ok, else: {:error, :invalid_root_tools}
  end

  defp validate_root_tools(_), do: {:error, :invalid_root_tools}

  defp discover(config, sources) do
    Agents.discover(
      cwd: sources.cwd,
      executor: Executor.from_context(config.context),
      env: sources.env,
      builtins: Default.definitions()
    )
  end

  defp validate_discovery(%{warnings: []}), do: :ok

  defp validate_discovery(%{warnings: warnings}) do
    {:error, {:invalid_agent_definitions, warnings}}
  end

  # `config.json` `agents` settings replace a profile's own model and thinking,
  # so a user or project can retarget a profile without copying its file.
  defp apply_agent_settings(%Definition{name: name} = definition, agents) do
    settings = Map.get(agents, name, %{})

    %{
      definition
      | model: Map.get(settings, :model, definition.model),
        thinking: Map.get(settings, :thinking, definition.thinking)
    }
  end

  defp build_profiles(definitions, default_tools, trusted_tools, sources) do
    Enum.reduce_while(definitions, {:ok, %{}}, fn definition, {:ok, profiles} ->
      case build_profile(definition, default_tools, trusted_tools, sources) do
        {:ok, spec} -> {:cont, {:ok, Map.put(profiles, definition.name, spec)}}
        {:error, reason} -> {:halt, {:error, {:invalid_agent_profile, definition.path, reason}}}
      end
    end)
  end

  defp build_profile(definition, default_tools, trusted_tools, sources) do
    with {:ok, tools} <- profile_tools(definition, default_tools, trusted_tools),
         {:ok, config} <- profile_config(definition, tools, sources) do
      config = %{
        config
        | max_iterations: min_iterations(config.max_iterations, definition.max_iterations),
          llm_stream: false
      }

      AgentSpec.new(
        name: definition.name,
        config: config,
        allow_delegation: definition.allow_delegation,
        timeout: definition.timeout,
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
    resolution_tools =
      Enum.uniq(trusted_tools ++ Tackle.Tools.default() ++ Tackle.Tools.review())

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

  # A profile without instructions gets none; one with instructions gets them
  # unless the whole scope was loaded without.
  defp profile_config(definition, tools, sources) do
    prompt =
      [definition.prompt, parent_system_prompt(definition, sources)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    profile_overrides =
      [tools: tools, system_prompt: prompt]
      |> maybe_put(:model, definition.model)
      |> maybe_put(:thinking, definition.thinking)

    Config.from_sources(sources,
      overrides: profile_overrides,
      instructions: definition.instructions and sources.instructions
    )
  end

  # A built-in profile also gets a host's explicit system prompt, unless it
  # opted out of instructions.
  defp parent_system_prompt(%Definition{source: :builtin, instructions: true}, sources),
    do: Keyword.get(sources.overrides, :system_prompt)

  defp parent_system_prompt(_definition, _sources), do: nil

  defp root_config(definitions, root_tools, sources) do
    with {:ok, root_config} <- Config.from_sources(sources, overrides: [tools: root_tools]) do
      prompt =
        [root_config.system_prompt, @delegation, Agents.format_for_prompt(definitions)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")

      {:ok, %{root_config | system_prompt: prompt}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp min_iterations(:infinity, configured), do: configured
  defp min_iterations(value, :infinity), do: value
  defp min_iterations(value, configured), do: min(value, configured)

  defp limits(definitions) do
    max_spawn_depth = if Enum.any?(definitions, & &1.allow_delegation), do: 2, else: 1

    [
      max_agents_per_fleet: 5,
      max_concurrent_turns: 5,
      max_children_per_agent: 4,
      max_spawn_depth: max_spawn_depth,
      run_timeout: :timer.minutes(5)
    ]
  end
end
