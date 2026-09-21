defmodule Tackle.Runtime.WorkflowRef do
  @moduledoc """
  Stable reference to one host-defined workflow within a root-agent scope.
  """

  alias Tackle.Runtime.ID

  @enforce_keys [:scope_id, :workflow_id]
  defstruct [:scope_id, :workflow_id]

  @type t :: %__MODULE__{scope_id: ID.t(), workflow_id: ID.t()}

  @doc "Builds a validated workflow reference."
  @spec new(ID.t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = ref), do: validate(ref)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()
  def new(%{scope_id: scope_id, workflow_id: workflow_id}), do: new(scope_id, workflow_id)

  def new(scope_id, workflow_id) do
    ref = %__MODULE__{scope_id: scope_id, workflow_id: workflow_id}

    cond do
      not ID.valid?(scope_id) -> {:error, {:invalid_scope_id, scope_id}}
      not ID.valid?(workflow_id) -> {:error, {:invalid_workflow_id, workflow_id}}
      true -> {:ok, ref}
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

  defp validate(%__MODULE__{scope_id: scope_id, workflow_id: workflow_id}) do
    new(scope_id, workflow_id)
  end
end
