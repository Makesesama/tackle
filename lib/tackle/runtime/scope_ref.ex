defmodule Tackle.Runtime.ScopeRef do
  @moduledoc """
  Stable reference to one root-agent scope.

  For the initial coding harness a scope is also the fleet boundary, so
  `scope_id` is the fleet identity. References carry no PIDs and are safe to log.
  """

  alias Tackle.Runtime.ID

  @enforce_keys [:scope_id]
  defstruct [:scope_id]

  @type t :: %__MODULE__{scope_id: ID.t()}

  @doc "Builds a validated scope reference."
  @spec new(ID.t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = ref), do: validate(ref)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()
  def new(%{scope_id: scope_id}), do: new(scope_id)

  def new(scope_id) do
    ref = %__MODULE__{scope_id: scope_id}

    if ID.valid?(scope_id), do: {:ok, ref}, else: {:error, {:invalid_scope_id, scope_id}}
  end

  @doc "Builds a validated scope reference or raises."
  @spec new!(ID.t() | keyword() | map()) :: t()
  def new!(value) do
    case new(value) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, "invalid scope reference: #{inspect(reason)}"
    end
  end

  defp validate(%__MODULE__{scope_id: scope_id} = ref) do
    if ID.valid?(scope_id), do: {:ok, ref}, else: {:error, {:invalid_scope_id, scope_id}}
  end
end
