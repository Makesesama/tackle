defmodule Tackle.Script.Ref do
  @moduledoc """
  Stable reference to one scripted workflow.

  The reference identifies the owning scope and script; it is used to await one
  terminal result or request cancellation without exposing the runner PID.
  """

  alias Tackle.Runtime.ID

  @enforce_keys [:scope_id, :script_id]
  defstruct [:scope_id, :script_id]

  @type t :: %__MODULE__{
          scope_id: ID.t(),
          script_id: ID.t()
        }

  @doc "Builds a validated script reference."
  @spec new(ID.t(), ID.t()) :: {:ok, t()} | {:error, term()}
  def new(scope_id, script_id) do
    cond do
      not ID.valid?(scope_id) -> {:error, {:invalid_scope_id, scope_id}}
      not ID.valid?(script_id) -> {:error, {:invalid_script_id, script_id}}
      true -> {:ok, %__MODULE__{scope_id: scope_id, script_id: script_id}}
    end
  end

  @doc "Builds a validated script reference or raises."
  @spec new!(ID.t(), ID.t()) :: t()
  def new!(scope_id, script_id) do
    case new(scope_id, script_id) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, "invalid script reference: #{inspect(reason)}"
    end
  end
end
