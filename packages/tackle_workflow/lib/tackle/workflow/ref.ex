defmodule Tackle.Workflow.Ref do
  @moduledoc """
  Stable reference to one scripted workflow.

  The reference identifies the owning scope and workflow; it is used to await one
  terminal result or request cancellation without exposing the runner PID.
  """

  alias Tackle.Runtime.ID

  @enforce_keys [:scope_id, :workflow_id]
  defstruct [:scope_id, :workflow_id]

  @type t :: %__MODULE__{
          scope_id: ID.t(),
          workflow_id: ID.t()
        }

  @doc "Builds a validated workflow reference."
  @spec new(ID.t(), ID.t()) :: {:ok, t()} | {:error, term()}
  def new(scope_id, workflow_id) do
    cond do
      not ID.valid?(scope_id) -> {:error, {:invalid_scope_id, scope_id}}
      not ID.valid?(workflow_id) -> {:error, {:invalid_workflow_id, workflow_id}}
      true -> {:ok, %__MODULE__{scope_id: scope_id, workflow_id: workflow_id}}
    end
  end

  @doc "Builds a validated workflow reference or raises."
  @spec new!(ID.t(), ID.t()) :: t()
  def new!(scope_id, workflow_id) do
    case new(scope_id, workflow_id) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, "invalid workflow reference: #{inspect(reason)}"
    end
  end
end
