defmodule Tackle.Runtime.Limits do
  @moduledoc """
  Resource and recursion limits for one root-agent scope (fleet).

  `Tackle.Lib.State.max_iterations` bounds one agent's internal loop only. These
  limits bound recursive agent creation, concurrent work, and request waits at
  the runtime level. The initial runtime rejects excess concurrency instead of
  queuing it.
  """

  @default_run_timeout :timer.minutes(5)
  @default_workflow_timeout :timer.minutes(10)

  @enforce_keys [:max_agents_per_fleet]
  defstruct max_agents_per_fleet: 16,
            max_concurrent_turns: 8,
            max_spawn_depth: 3,
            max_children_per_agent: 4,
            max_pending_requests: 0,
            run_timeout: @default_run_timeout,
            workflow_timeout: @default_workflow_timeout

  @type timeout_ms :: pos_integer()

  @type t :: %__MODULE__{
          max_agents_per_fleet: pos_integer(),
          max_concurrent_turns: pos_integer(),
          max_spawn_depth: non_neg_integer(),
          max_children_per_agent: non_neg_integer(),
          max_pending_requests: non_neg_integer(),
          run_timeout: timeout_ms(),
          workflow_timeout: timeout_ms()
        }

  @positive_keys [
    :max_agents_per_fleet,
    :max_concurrent_turns,
    :run_timeout,
    :workflow_timeout
  ]
  @non_negative_keys [
    :max_spawn_depth,
    :max_children_per_agent,
    :max_pending_requests
  ]
  @all_keys @positive_keys ++ @non_negative_keys

  @doc "Returns the accepted default limits."
  @spec default() :: t()
  def default, do: %__MODULE__{max_agents_per_fleet: 16}

  @doc "Builds validated limits from a struct, keyword list, or map."
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = limits), do: validate(limits)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(%{} = opts) do
    unknown = Map.keys(opts) -- @all_keys

    if unknown == [] do
      struct(__MODULE__, opts) |> validate()
    else
      {:error, {:unknown_limits, Enum.sort(unknown)}}
    end
  end

  def new(value), do: {:error, {:invalid_limits, value}}

  @doc "Builds validated limits or raises."
  @spec new!(t() | keyword() | map()) :: t()
  def new!(value) do
    case new(value) do
      {:ok, limits} -> limits
      {:error, reason} -> raise ArgumentError, "invalid runtime limits: #{inspect(reason)}"
    end
  end

  @doc """
  Narrows `child` so it can never exceed the inherited `parent` limits.

  Descendant agents receive inherited, non-increasing limits. A child may be
  more restrictive but never wider than its parent.
  """
  @spec inherit(t(), t()) :: t()
  def inherit(%__MODULE__{} = parent, %__MODULE__{} = child) do
    %__MODULE__{
      max_agents_per_fleet: min(parent.max_agents_per_fleet, child.max_agents_per_fleet),
      max_concurrent_turns: min(parent.max_concurrent_turns, child.max_concurrent_turns),
      max_spawn_depth: min(parent.max_spawn_depth, child.max_spawn_depth),
      max_children_per_agent: min(parent.max_children_per_agent, child.max_children_per_agent),
      max_pending_requests: min(parent.max_pending_requests, child.max_pending_requests),
      run_timeout: min(parent.run_timeout, child.run_timeout),
      workflow_timeout: min(parent.workflow_timeout, child.workflow_timeout)
    }
  end

  defp validate(%__MODULE__{} = limits) do
    with :ok <- validate_positive(:max_agents_per_fleet, limits.max_agents_per_fleet),
         :ok <- validate_positive(:max_concurrent_turns, limits.max_concurrent_turns),
         :ok <- validate_non_negative(:max_spawn_depth, limits.max_spawn_depth),
         :ok <- validate_non_negative(:max_children_per_agent, limits.max_children_per_agent),
         :ok <- validate_non_negative(:max_pending_requests, limits.max_pending_requests),
         :ok <- validate_positive(:run_timeout, limits.run_timeout),
         :ok <- validate_positive(:workflow_timeout, limits.workflow_timeout) do
      {:ok, limits}
    end
  end

  defp validate_positive(_key, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(key, value), do: {:error, {:invalid_limit, key, value}}

  defp validate_non_negative(_key, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(key, value), do: {:error, {:invalid_limit, key, value}}
end
