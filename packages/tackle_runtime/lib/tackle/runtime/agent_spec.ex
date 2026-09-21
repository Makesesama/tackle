defmodule Tackle.Runtime.AgentSpec do
  @moduledoc """
  Trusted configuration for one agent the runtime may start.

  `:config` is opaque backend-owned data. Model-generated data may select only
  an allowlisted profile name; it can never provide backend modules, executable
  code, or configuration. Backend-specific validation occurs when a `ScopeSpec`
  is built or a profile is resolved.

  `:model_source` is opaque trusted policy interpreted by the backend. It is
  retained for root-harness compatibility; generic backends may ignore it.
  """

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
          config: map(),
          allow_delegation: boolean(),
          timeout: pos_integer(),
          model_source: term()
        }

  @doc "Builds a validated backend-neutral agent spec."
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = spec), do: validate(spec)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(%{name: name, config: config} = opts) do
    validate(%__MODULE__{
      name: name,
      config: config,
      allow_delegation: Map.get(opts, :allow_delegation, false),
      timeout: Map.get(opts, :timeout, @default_timeout),
      model_source: Map.get(opts, :model_source, :configured)
    })
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

  @doc "Returns the agent's per-run timeout, bounded by the scope limit."
  @spec timeout(t(), Limits.t()) :: pos_integer()
  def timeout(%__MODULE__{timeout: timeout}, %Limits{} = limits),
    do: min(timeout, limits.run_timeout)

  defp validate(%__MODULE__{} = spec) do
    cond do
      not (is_binary(spec.name) and spec.name != "") ->
        {:error, {:invalid_agent_name, spec.name}}

      not is_map(spec.config) ->
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
