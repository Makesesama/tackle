defmodule Tackle.Runtime.AgentRef do
  @moduledoc """
  Stable reference to one agent within a root-agent scope.

  An agent reference never exposes a PID. `scope_id` identifies the owning
  fleet/scope and `agent_id` identifies the dedicated agent process.
  """

  alias Tackle.Runtime.ID

  @enforce_keys [:scope_id, :agent_id]
  defstruct [:scope_id, :agent_id]

  @type t :: %__MODULE__{scope_id: ID.t(), agent_id: ID.t()}

  @doc "Builds a validated agent reference."
  @spec new(ID.t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = ref), do: validate(ref)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()
  def new(%{scope_id: scope_id, agent_id: agent_id}), do: new(scope_id, agent_id)

  def new(scope_id, agent_id) do
    ref = %__MODULE__{scope_id: scope_id, agent_id: agent_id}

    cond do
      not ID.valid?(scope_id) -> {:error, {:invalid_scope_id, scope_id}}
      not ID.valid?(agent_id) -> {:error, {:invalid_agent_id, agent_id}}
      true -> {:ok, ref}
    end
  end

  @doc "Builds a validated agent reference or raises."
  @spec new!(ID.t(), ID.t()) :: t()
  def new!(scope_id, agent_id) do
    case new(scope_id, agent_id) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, "invalid agent reference: #{inspect(reason)}"
    end
  end

  defp validate(%__MODULE__{scope_id: scope_id, agent_id: agent_id}) do
    new(scope_id, agent_id)
  end
end
