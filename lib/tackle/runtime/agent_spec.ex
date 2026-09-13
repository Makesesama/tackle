defmodule Tackle.Runtime.AgentSpec do
  @moduledoc """
  Trusted, resolved configuration for one agent the runtime may start.

  An `AgentSpec` is produced by trusted harness code (a named profile or a host
  workflow) from modules already present in the distribution. Model-generated
  data may only select a trusted profile name; it can never name arbitrary
  modules, supervisors, or executable code.

  `:config` is a fully resolved `Tackle.Config`; `:allow_delegation` is the
  explicit grant that lets this agent request descendants; `:timeout` bounds a
  single delegated run. `:model_source` defaults to `:configured`; `:parent`
  resolves the requesting agent's current model and thinking level when a run
  is requested. All other child configuration stays explicit. This setting is
  trusted host policy, never a model-visible tool argument.
  """

  alias Tackle.Config
  alias Tackle.Runtime.Limits

  @default_timeout :timer.minutes(5)

  @enforce_keys [:name, :config]
  defstruct [
    :name,
    :config,
    allow_delegation: false,
    timeout: @default_timeout,
    model_source: :configured
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          config: Config.t(),
          allow_delegation: boolean(),
          timeout: pos_integer(),
          model_source: :configured | :parent
        }

  @doc "Builds a validated agent spec."
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = spec), do: validate(spec)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(%{name: name, config: config} = opts) do
    spec = %__MODULE__{
      name: name,
      config: config,
      allow_delegation: Map.get(opts, :allow_delegation, false),
      timeout: Map.get(opts, :timeout, @default_timeout),
      model_source: Map.get(opts, :model_source, :configured)
    }

    validate(spec)
  end

  def new(value), do: {:error, {:invalid_agent_spec, value}}

  @doc "Builds a validated agent spec or raises."
  @spec new!(t() | keyword() | map()) :: t()
  def new!(value) do
    case new(value) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid agent spec: #{inspect(reason)}"
    end
  end

  @doc "Returns the agent's per-run timeout, defaulting to the run limit."
  @spec timeout(t(), Limits.t()) :: pos_integer()
  def timeout(%__MODULE__{timeout: timeout}, %Limits{} = limits),
    do: min(timeout, limits.run_timeout)

  defp validate(%__MODULE__{} = spec) do
    cond do
      not (is_binary(spec.name) and spec.name != "") ->
        {:error, {:invalid_agent_name, spec.name}}

      not is_struct(spec.config, Config) ->
        {:error, {:invalid_agent_config, spec.config}}

      not is_boolean(spec.allow_delegation) ->
        {:error, {:invalid_allow_delegation, spec.allow_delegation}}

      spec.model_source not in [:configured, :parent] ->
        {:error, {:invalid_model_source, spec.model_source}}

      not (is_integer(spec.timeout) and spec.timeout > 0) ->
        {:error, {:invalid_agent_timeout, spec.timeout}}

      true ->
        {:ok, spec}
    end
  end
end
