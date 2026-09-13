defmodule Tackle.Coding do
  @moduledoc """
  Composition of a coding scope with declarative subagent profiles.

  The built-in explorer is joined by profiles discovered from
  `$TACKLE_HOME/agents` and the nearest project `.tackle/agents` directory.
  Project profiles override user profiles, which override built-ins. Profile
  files may select only tools already available to the trusted root harness.
  """

  alias Tackle.Agents
  alias Tackle.Agents.Definition
  alias Tackle.Config
  alias Tackle.Runtime.{AgentSpec, ScopeSpec}
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Tools.Subagent

  @delegation """
  ## Delegation

  Use the subagent tool for bounded work that benefits from a fresh, focused
  context. Choose only from the configured profiles below and give the child a
  self-contained assignment with the relevant context and expected deliverable.
  Child sessions are ephemeral and share this workspace; tool restrictions are
  capability limits, not an operating-system sandbox. Evaluate returned work
  before relying on it. At most two children can run at once; excess requests
  are rejected rather than queued.
  """

  @exploration """
  ## Explorer assignment

  You are the explorer subagent. Investigate only the self-contained task in the
  user prompt and return concise findings with file paths, line references, and
  uncertainties. You have a fresh conversation, not the parent's history.
  Use read to inspect files and bash to list and search the codebase. Do not edit,
  create, or delete files, install dependencies, or run commands with workspace
  side effects. You share the parent's workspace; this is not an isolated copy.
  You cannot delegate. Return your findings rather than implementing changes.
  """

  @doc """
  Loads coding configuration and builds a scope with discovered subagents.

  Agent files are validated at startup. Invalid files, unknown tools, and model
  selections unavailable through the configured adapters are explicit errors.
  Every child is capped at 20 loop iterations and five minutes. Scope limits
  allow the root plus two children.
  """
  @spec scope_spec(keyword(), SessionSpec.t() | nil) :: {:ok, ScopeSpec.t()} | {:error, term()}
  def scope_spec(loader_opts \\ [], session \\ nil) do
    with {:ok, config} <- Config.load(loader_opts),
         discovery <- discover(config, loader_opts),
         :ok <- validate_discovery(discovery),
         {:ok, profiles} <- build_profiles(discovery.definitions, config, loader_opts),
         {:ok, root_config} <- root_config(config, discovery.definitions, loader_opts),
         {:ok, root_spec} <-
           AgentSpec.new(
             name: "root",
             config: root_config,
             allow_delegation: map_size(profiles) > 0
           ) do
      ScopeSpec.new(
        root_spec: root_spec,
        session: session,
        limits: limits(discovery.definitions),
        profiles: profiles
      )
    end
  end

  defp discover(config, loader_opts) do
    Agents.discover(
      cwd: config.context.cwd,
      env: Keyword.get_lazy(loader_opts, :env, &System.get_env/0),
      builtins: [explorer_definition()]
    )
  end

  defp validate_discovery(%{warnings: []}), do: :ok

  defp validate_discovery(%{warnings: warnings}) do
    {:error, {:invalid_agent_definitions, warnings}}
  end

  defp build_profiles(definitions, root_config, loader_opts) do
    Enum.reduce_while(definitions, {:ok, %{}}, fn definition, {:ok, profiles} ->
      case build_profile(definition, root_config, loader_opts) do
        {:ok, spec} -> {:cont, {:ok, Map.put(profiles, definition.name, spec)}}
        {:error, reason} -> {:halt, {:error, {:invalid_agent_profile, definition.path, reason}}}
      end
    end)
  end

  defp build_profile(definition, root_config, loader_opts) do
    with {:ok, tools} <- profile_tools(definition, root_config.tools),
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

  defp profile_tools(%Definition{tools: nil} = definition, trusted_tools) do
    tools = if definition.allow_delegation, do: trusted_tools ++ [Subagent], else: trusted_tools
    {:ok, Enum.uniq(tools)}
  end

  defp profile_tools(%Definition{tools: names} = definition, trusted_tools) do
    with {:ok, tools} <- Tackle.Tools.resolve_names(names, trusted_tools) do
      tools = if definition.allow_delegation, do: tools ++ [Subagent], else: tools
      {:ok, Enum.uniq(tools)}
    end
  end

  defp load_profile_config(definition, tools, loader_opts) do
    profile_overrides =
      [tools: tools, system_prompt: definition.prompt]
      |> maybe_put(:model, definition.model)
      |> maybe_put(:thinking, definition.thinking)

    load_with_overrides(loader_opts, profile_overrides)
  end

  defp root_config(config, definitions, loader_opts) do
    with {:ok, root_config} <-
           load_with_overrides(loader_opts, tools: Enum.uniq(config.tools ++ [Subagent])) do
      prompt =
        [root_config.system_prompt, @delegation, Agents.format_for_prompt(definitions)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")

      {:ok, %{root_config | system_prompt: prompt}}
    end
  end

  defp load_with_overrides(opts, overrides) do
    merged = opts |> Keyword.get(:overrides, []) |> Keyword.merge(overrides)
    Config.load(Keyword.put(opts, :overrides, merged))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp explorer_definition do
    %Definition{
      name: "explorer",
      description: "Read-only codebase investigation with concise, cited findings",
      prompt: @exploration,
      source: :builtin,
      tools: ["read", "bash"],
      advertise: true,
      allow_delegation: false
    }
  end

  defp min_iterations(:infinity, configured), do: min(20, configured)
  defp min_iterations(value, configured), do: min(value, min(20, configured))

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
