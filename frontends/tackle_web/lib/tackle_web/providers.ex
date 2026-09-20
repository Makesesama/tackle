defmodule Tackle.Web.Providers do
  @moduledoc """
  The provider adapters and models this web frontend can run.

  Every assistant surface of the frontend selects from the same configured
  plugins, so this module is the one place that decides which adapter modules
  exist and which `adapter/model` references they expose. The plugins are wired
  exactly as any external plugin would be: each implements `Tackle.Lib.LLM`, and
  the model reference the user picks decides which one runs.

    * `Tackle.Plugins.Codex` (`openai-codex/*`) authenticates with the ChatGPT
      session stored by `mix tackle auth`, and resends a request when the
      provider rejects an expired token.
    * `Tackle.Plugins.DeepSeek` (`deepseek/*`) authenticates with an API key.

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

  @doc """
  The adapter modules available to this host.

  Returns `[]` rather than raising when nothing is configured: a frontend with
  no providers is a state to render, not a reason to fail booting.
  """
  @spec adapters() :: [module()]
  def adapters do
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

  @doc "Every `adapter/model` reference the available adapters expose."
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
  model the adapters list.
  """
  @spec default_model() :: String.t() | nil
  def default_model do
    case Application.get_env(:tackle_web, :agent_model) do
      model when is_binary(model) and model != "" -> model
      _unset -> List.first(models())
    end
  end

  @doc """
  Resolves a canonical `adapter/model` reference against the available adapters.

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

  def select(model_ref) when is_binary(model_ref), do: LLM.select(adapters(), model_ref)
end
