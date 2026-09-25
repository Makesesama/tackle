defmodule Tackle.CLI.Distribution do
  @moduledoc false

  @default_adapters [Tackle.Plugins.Codex, Tackle.Plugins.DeepSeek]

  @doc "Validates bundled adapters, default tools, and host-owned tool modules."
  @spec catalog([module()]) :: {:ok, Tackle.Plugins.Catalog.t()} | {:error, term()}
  def catalog(extra_tools \\ [])

  def catalog(extra_tools) when is_list(extra_tools) do
    contributions = Application.get_env(:tackle_cli, :plugin_contributions, empty_contributions())

    plugin_adapters = Enum.map(contributions.adapters, & &1.module)

    Tackle.Plugins.Catalog.new(
      adapters:
        Enum.map(
          Application.get_env(:tackle, :adapters, default_adapters()) -- plugin_adapters,
          &%{module: &1, source: :cli}
        ) ++
          contributions.adapters,
      tools:
        Enum.map(Tackle.Tools.default(), &%{module: &1, source: :tackle}) ++
          Enum.map(extra_tools, &%{module: &1, source: :cli_mcp}) ++
          Enum.map(
            [Tackle.Tools.Subagent, Tackle.Tools.SubagentStatus, Tackle.Tools.SubagentWait],
            &%{module: &1, source: :tackle}
          ) ++ contributions.tools,
      hooks: contributions.hooks
    )
  end

  def catalog(extra_tools), do: {:error, {:invalid_catalog_tools, extra_tools}}

  defp empty_contributions, do: %{adapters: [], tools: [], hooks: []}

  @doc "Model references from the validated distribution catalog."
  @spec available_models() :: {:ok, [String.t()]} | {:error, term()}
  def available_models do
    with {:ok, catalog} <- catalog() do
      Tackle.Plugins.available_model_refs(
        adapters: Tackle.Plugins.Catalog.adapter_modules(catalog)
      )
    end
  end

  @doc "Installs default CLI distribution contributions before the harness starts."
  @spec configure() :: :ok
  def configure do
    if is_nil(Application.get_env(:tackle, :adapters)) do
      additions =
        Application.get_env(:tackle_cli, :plugin_contributions, empty_contributions()).adapters

      Application.put_env(
        :tackle,
        :adapters,
        default_adapters() ++ Enum.map(additions, & &1.module)
      )
    end

    :ok
  end

  @doc "Returns the adapters bundled with the default CLI distribution."
  @spec default_adapters() :: [module()]
  def default_adapters do
    Application.get_env(:tackle_cli, :default_adapters, @default_adapters)
  end
end
