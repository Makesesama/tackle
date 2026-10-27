defmodule Tackle.CLI.Distribution do
  @moduledoc false

  alias Tackle.Plugins.Catalog

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

  @doc """
  Loads the enabled plugin projects (`Tackle.Plugins.Loader.load/0`), checks
  that the distribution's catalog accepts their contributions, and installs
  them for `catalog/1`. The CLI application calls it once, when it starts;
  until then the catalog has no plugin contributions.
  """
  @spec load_plugins() :: :ok | {:error, term()}
  def load_plugins do
    with {:ok, plugins} <- Tackle.Plugins.Loader.load(),
         {:ok, _catalog} <- build_catalog(plugins, []) do
      Application.put_env(:tackle_cli, :plugins, plugins)
    end
  end

  @doc """
  The distribution's validated catalog: the bundled adapters, the default
  coding tools, `extra_tools` (connected MCP tools), the bundled delegation
  tools, and the contributions of enabled plugin projects.

  Every CLI command takes its adapters and plugin tools from it.
  """
  @spec catalog([module()]) :: {:ok, Catalog.t()} | {:error, term()}
  def catalog(extra_tools \\ [])

  def catalog(extra_tools) when is_list(extra_tools), do: build_catalog(plugins(), extra_tools)
  def catalog(extra_tools), do: {:error, {:invalid_catalog_tools, extra_tools}}

  defp build_catalog(%Catalog{} = plugins, extra_tools) do
    Catalog.new(
      adapters: Enum.map(default_adapters(), &%{module: &1, source: :cli}) ++ plugins.adapters,
      tools:
        Enum.map(Tackle.Tools.default(), &%{module: &1, source: :tackle}) ++
          Enum.map(extra_tools, &%{module: &1, source: :cli_mcp}) ++
          Enum.map(@bundled_tools, &%{module: &1, source: :tackle}) ++ plugins.tools,
      hooks: plugins.hooks
    )
  end

  # The contributions `load_plugins/0` installed.
  defp plugins do
    Application.get_env(:tackle_cli, :plugins, %Catalog{adapters: [], tools: [], hooks: []})
  end

  @doc "The tool modules of enabled plugin projects."
  @spec plugin_tools() :: [module()]
  def plugin_tools, do: Enum.map(plugins().tools, & &1.module)

  @doc """
  Names of catalog tools the CLI grants to the root agent: the workflow and
  code review tools and the tools of enabled plugin projects.

  The subagent tools are granted by `Tackle.Coding` itself; these need an
  explicit grant.
  """
  @spec root_tool_names() :: [String.t()]
  def root_tool_names do
    [Tackle.Workflow.Tool.name(), Tackle.Tools.Review.name()] ++
      Enum.map(plugin_tools(), & &1.name())
  end

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
      {:ok, Catalog.adapter_modules(catalog)}
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
