defmodule Tackle.Runtime.RunRef do
  @moduledoc """
  Stable reference to one delegated run.

  A run is a correlated request/reply unit owned by an agent. The reference
  identifies the owning scope and run; it is used to await one terminal outcome
  without exposing the requester or agent PIDs.
  """

  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.ID

  @enforce_keys [:scope_id, :run_id]
  defstruct [:scope_id, :run_id, :agent_ref]

  @type t :: %__MODULE__{
          scope_id: ID.t(),
          run_id: ID.t(),
          agent_ref: AgentRef.t() | nil
        }

  @doc "Builds a validated run reference."
  @spec new(ID.t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = ref), do: validate(ref)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(%{scope_id: scope_id, run_id: run_id} = opts),
    do: new(scope_id, run_id, Map.get(opts, :agent_ref))

  def new(scope_id, run_id), do: new(scope_id, run_id, nil)

  @doc "Builds a validated run reference bound to its child agent."
  @spec new(ID.t(), ID.t(), AgentRef.t() | nil) :: {:ok, t()} | {:error, term()}
  def new(scope_id, run_id, agent_ref) do
    ref = %__MODULE__{scope_id: scope_id, run_id: run_id, agent_ref: agent_ref}

    cond do
      not ID.valid?(scope_id) ->
        {:error, {:invalid_scope_id, scope_id}}

      not ID.valid?(run_id) ->
        {:error, {:invalid_run_id, run_id}}

      not is_nil(agent_ref) and not match?(%AgentRef{}, agent_ref) ->
        {:error, {:invalid_run_agent, agent_ref}}

      true ->
        {:ok, ref}
    end
  end

  @doc "Builds a validated run reference or raises."
  @spec new!(ID.t(), ID.t()) :: t()
  def new!(scope_id, run_id), do: new!(scope_id, run_id, nil)

  @spec new!(ID.t(), ID.t(), AgentRef.t() | nil) :: t()
  def new!(scope_id, run_id, agent_ref) do
    case new(scope_id, run_id, agent_ref) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, "invalid run reference: #{inspect(reason)}"
    end
  end

  defp validate(%__MODULE__{scope_id: scope_id, run_id: run_id, agent_ref: agent_ref}) do
    new(scope_id, run_id, agent_ref)
  end
end
