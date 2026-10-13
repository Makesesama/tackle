defmodule Tackle.Web.Providers do
  @moduledoc """
  The provider adapters, providers, and models this web frontend can run.

  Every assistant surface of the frontend selects from the same configured
  plugins, so this module is the one place that decides which adapter modules
  exist and which `provider/model` references they expose. The plugins are
  wired exactly as any external plugin would be: each implements
  `Tackle.Lib.LLM`, and the model reference the user picks decides which
  provider runs.

  A provider (`Tackle.Lib.LLM.Provider`) is one configured instance of an
  adapter, and its id is the model reference's prefix. Besides each adapter's
  default providers (`openai-codex`, `deepseek`, ...), the harness offers
  accounts recorded by `tackle auth login ADAPTER --as NAME` and the
  `config.json` `"providers"` object; see `Tackle.Plugins.available_providers/1`.

    * `Tackle.Plugins.Codex` (`openai-codex/*`) authenticates with the ChatGPT
      session stored by `mix tackle auth`, and resends a request when the
      provider rejects an expired token.
    * `Tackle.Plugins.DeepSeek` (`deepseek/*`) authenticates with an API key.
    * `Tackle.Plugins.Anthropic` (`anthropic/*`) authenticates with a Claude
      Pro/Max OAuth session or an Anthropic API key, and refreshes expiring
      tokens before a request.
    * `Tackle.Plugins.OpenRouter` (`openrouter/<vendor>/<model>`)
      authenticates with an OpenRouter API key.

  ## Configuration

  `config :tackle, :adapters` names the adapters bundled with the distribution;
  it is the harness's own key, so the CLI and this frontend agree on one list.
  `config :tackle_web, :agent_adapters` overrides it. That override is how a
  deployment adds a provider plugin of its own, and how tests run against a
  deterministic adapter instead of a real provider.

  `config :tackle_web, :agent_model` names the default model. The two keys are
  deliberately independent: the adapter list decides what *can* run, the model
  reference decides what runs when a user does not pick one.
  """

  alias Tackle.Lib.LLM
  alias Tackle.Plugins.Catalog

  @doc "Validates this host's selected adapters and built-in chat tools."
  @spec catalog() :: {:ok, Catalog.t()} | {:error, term()}
  def catalog do
    contributions =
      Application.get_env(:tackle_web, :plugin_contributions, %{
        adapters: [],
        tools: [],
        hooks: []
      })

    plugin_adapters = Enum.map(contributions.adapters, & &1.module)

    Catalog.new(
      adapters:
        Enum.map(base_adapters() -- plugin_adapters, &%{module: &1, source: :web}) ++
          contributions.adapters,
      tools:
        Enum.map(Tackle.Tools.default(), &%{module: &1, source: :tackle}) ++ contributions.tools,
      hooks: contributions.hooks
    )
  end

  @doc """
  The adapter modules available to this host.

  Returns `[]` rather than raising when nothing is configured: a frontend with
  no providers is a state to render, not a reason to fail booting.
  """
  @spec adapters() :: [module()]
  def adapters do
    (base_adapters() ++
       Enum.map(
         Application.get_env(:tackle_web, :plugin_contributions, %{adapters: []}).adapters,
         & &1.module
       ))
    |> Enum.uniq()
  end

  defp base_adapters do
    case Application.get_env(:tackle_web, :agent_adapters) do
      adapters when is_list(adapters) and adapters != [] ->
        adapters

      _unset ->
        case Tackle.Plugins.available_adapters() do
          {:ok, adapters} -> adapters
          {:error, _reason} -> []
        end
    end
  end

  @doc """
  The providers of the available adapters, accounts, and `config.json`.

  Returns `[]` rather than raising when nothing is configured or the
  configuration is invalid; `select/1` reports the reason.
  """
  @spec providers() :: [LLM.Provider.t()]
  def providers do
    case fetch_providers() do
      {:ok, providers} -> providers
      {:error, _reason} -> []
    end
  end

  defp fetch_providers, do: Tackle.Plugins.available_providers(adapters: adapters())

  @doc "Every `provider/model` reference the available providers expose."
  @spec models() :: [String.t()]
  def models do
    case Tackle.Plugins.available_model_refs(adapters: adapters()) do
      {:ok, models} -> models
      {:error, _reason} -> []
    end
  end

  @doc """
  The model used when a caller does not pick one.

  Configured with `config :tackle_web, :agent_model`, falling back to the first
  model the providers list.
  """
  @spec default_model() :: String.t() | nil
  def default_model do
    case Application.get_env(:tackle_web, :agent_model) do
      model when is_binary(model) and model != "" -> model
      _unset -> List.first(models())
    end
  end

  @doc """
  Resolves a canonical `provider/model` reference against the available providers.

  `nil` selects `default_model/0`. With no adapters or no default model there is
  nothing to resolve, which is reported instead of retried.
  """
  @spec select(String.t() | nil) :: {:ok, LLM.Selection.t()} | {:error, term()}
  def select(nil) do
    case default_model() do
      nil -> {:error, :no_model_available}
      model -> select(model)
    end
  end

  def select(model_ref) when is_binary(model_ref) do
    with {:ok, providers} <- fetch_providers() do
      LLM.select(providers, model_ref)
    end
  end
end
