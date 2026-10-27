defmodule Tackle.CLI.Distribution do
  @moduledoc false

  @default_adapters [
    Tackle.Plugins.Codex,
    Tackle.Plugins.DeepSeek,
    Tackle.Plugins.Anthropic,
    Tackle.Plugins.OpenRouter,
    Tackle.Plugins.Ollama
  ]

  # Delegation tools bundled with the CLI distribution. `run_workflow` is the
  # optional `tackle_workflow` plugin's model-facing tool and `review_changes`
  # the harness's code review tool; the CLI grants both to the root agent next
  # to the subagent tools.
  @bundled_tools [
    Tackle.Tools.Subagent,
    Tackle.Tools.SubagentStatus,
    Tackle.Tools.SubagentWait,
    Tackle.Tools.SubagentCancel,
    Tackle.Workflow.Tool,
    Tackle.Tools.Review
  ]

  @doc "Validates bundled adapters, default tools, and host-owned tool modules."
  @spec catalog([module()]) :: {:ok, Tackle.Plugins.Catalog.t()} | {:error, term()}
  def catalog(extra_tools \\ [])

  def catalog(extra_tools) when is_list(extra_tools) do
    contributions = Application.get_env(:tackle_cli, :plugin_contributions, empty_contributions())

    plugin_adapters = Enum.map(contributions.adapters, & &1.module)

    Tackle.Plugins.Catalog.new(
      adapters:
        Enum.map(
          default_adapters() -- plugin_adapters,
          &%{module: &1, source: :cli}
        ) ++
          contributions.adapters,
      tools:
        Enum.map(Tackle.Tools.default(), &%{module: &1, source: :tackle}) ++
          Enum.map(extra_tools, &%{module: &1, source: :cli_mcp}) ++
          Enum.map(bundled_tools(), &%{module: &1, source: :tackle}) ++ contributions.tools,
      hooks: contributions.hooks
    )
  end

  def catalog(extra_tools), do: {:error, {:invalid_catalog_tools, extra_tools}}

  defp empty_contributions, do: %{adapters: [], tools: [], hooks: []}

  @doc "Returns the delegation tools bundled with the CLI distribution."
  @spec bundled_tools() :: [module()]
  def bundled_tools, do: @bundled_tools

  @doc """
  Names of bundled catalog tools the CLI grants to the root agent.

  The subagent tools are granted by `Tackle.Coding` itself; the workflow and
  code review tools need an explicit grant.
  """
  @spec root_tool_names() :: [String.t()]
  def root_tool_names, do: [Tackle.Workflow.Tool.name(), Tackle.Tools.Review.name()]

  @doc """
  Built-in skills bundled with the CLI distribution.

  The `run_workflow` guide is offered only to agents that have that tool.
  """
  @spec builtin_skills() :: {:ok, [Tackle.Skills.Skill.t()]} | {:error, term()}
  def builtin_skills do
    with {:ok, workflows} <-
           Tackle.Skills.builtin(Tackle.Workflow.Tool.skill_markdown(),
             requires_tools: [Tackle.Workflow.Tool.name()]
           ) do
      {:ok, [workflows]}
    end
  end

  @doc """
  The adapter modules of the validated distribution catalog, which every
  CLI command passes to the harness: sessions through the catalog itself, and
  `tackle auth` and the model lists through these modules.
  """
  @spec adapters() :: {:ok, [module()]} | {:error, term()}
  def adapters do
    with {:ok, catalog} <- catalog() do
      {:ok, Tackle.Plugins.Catalog.adapter_modules(catalog)}
    end
  end

  @doc """
  Providers of the validated distribution catalog's adapters.

  They include the adapters' default providers, accounts recorded by
  `tackle auth login ADAPTER --as NAME`, and the `config.json` `"providers"`
  object (see `Tackle.Plugins.available_providers/2`).
  """
  @spec available_providers() :: {:ok, [Tackle.Lib.LLM.Provider.t()]} | {:error, term()}
  def available_providers do
    with {:ok, adapters} <- adapters(), do: Tackle.Plugins.available_providers(adapters)
  end

  @doc "Model references offered by `available_providers/0`."
  @spec available_models() :: {:ok, [String.t()]} | {:error, term()}
  def available_models do
    with {:ok, adapters} <- adapters(), do: Tackle.Plugins.available_model_refs(adapters)
  end

  @doc """
  Maps each provider id to its adapter type id, so frontends can label a
  provider such as `codex-work` with the adapter (`openai-codex`) behind it.
  """
  @spec provider_adapters([Tackle.Lib.LLM.Provider.t()]) :: %{String.t() => String.t()}
  def provider_adapters(providers) when is_list(providers) do
    Map.new(providers, fn %Tackle.Lib.LLM.Provider{id: id, adapter: adapter} ->
      {id, adapter.adapter_id()}
    end)
  end

  @doc "Returns the adapters bundled with the default CLI distribution."
  @spec default_adapters() :: [module()]
  def default_adapters do
    Application.get_env(:tackle_cli, :default_adapters, @default_adapters)
  end
end
