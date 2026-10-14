defmodule Tackle.Runtime.AgentRef do
  @moduledoc """
  Stable reference to one agent within a root-agent scope.

  An agent reference never exposes a PID. `scope_id` identifies the owning
  fleet/scope and `agent_id` identifies the dedicated agent process.

  The harness puts each scoped agent's own reference into its
  `Tackle.Lib.State.context` under `:runtime`, so its tools know which agent
  they act for (`from_context/1`). A reference names an agent; it grants
  nothing. The scope coordinator decides what that agent may do whenever it
  requests work (see `Tackle.Runtime.delegation_limits/1`).
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

  @doc "Returns the agent reference stored in an agent context, if any."
  @spec from_context(map() | nil) :: t() | nil
  def from_context(%{runtime: %__MODULE__{} = ref}), do: ref
  def from_context(%{"runtime" => %__MODULE__{} = ref}), do: ref
  def from_context(_context), do: nil

  defp validate(%__MODULE__{scope_id: scope_id, agent_id: agent_id}) do
    new(scope_id, agent_id)
  end
end
