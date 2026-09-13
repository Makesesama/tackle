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
  defstruct [:scope_id, :run_id, :agent_ref, :model_ref]

  # `model_ref` is the already-resolved child selection captured when the run is
  # admitted. Frontends can therefore identify the actual model without racing
  # the short-lived child session.
  @type t :: %__MODULE__{
          scope_id: ID.t(),
          run_id: ID.t(),
          agent_ref: AgentRef.t() | nil,
          model_ref: String.t() | nil
        }

  @doc "Builds a validated run reference."
  @spec new(ID.t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = ref), do: validate(ref)
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(%{scope_id: scope_id, run_id: run_id} = opts),
    do: new(scope_id, run_id, Map.get(opts, :agent_ref), Map.get(opts, :model_ref))

  def new(scope_id, run_id), do: new(scope_id, run_id, nil, nil)

  @doc "Builds a validated run reference bound to its child agent."
  @spec new(ID.t(), ID.t(), AgentRef.t() | nil) :: {:ok, t()} | {:error, term()}
  def new(scope_id, run_id, agent_ref), do: new(scope_id, run_id, agent_ref, nil)

  @doc "Builds a validated run reference bound to its child agent and resolved model."
  @spec new(ID.t(), ID.t(), AgentRef.t() | nil, String.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def new(scope_id, run_id, agent_ref, model_ref) do
    ref = %__MODULE__{
      scope_id: scope_id,
      run_id: run_id,
      agent_ref: agent_ref,
      model_ref: model_ref
    }

    cond do
      not ID.valid?(scope_id) ->
        {:error, {:invalid_scope_id, scope_id}}

      not ID.valid?(run_id) ->
        {:error, {:invalid_run_id, run_id}}

      not is_nil(agent_ref) and not match?(%AgentRef{}, agent_ref) ->
        {:error, {:invalid_run_agent, agent_ref}}

      not is_nil(model_ref) and not (is_binary(model_ref) and model_ref != "") ->
        {:error, {:invalid_run_model, model_ref}}

      true ->
        {:ok, ref}
    end
  end

  @doc "Builds a validated run reference or raises."
  @spec new!(ID.t(), ID.t()) :: t()
  def new!(scope_id, run_id), do: new!(scope_id, run_id, nil, nil)

  @spec new!(ID.t(), ID.t(), AgentRef.t() | nil) :: t()
  def new!(scope_id, run_id, agent_ref), do: new!(scope_id, run_id, agent_ref, nil)

  @spec new!(ID.t(), ID.t(), AgentRef.t() | nil, String.t() | nil) :: t()
  def new!(scope_id, run_id, agent_ref, model_ref) do
    case new(scope_id, run_id, agent_ref, model_ref) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, "invalid run reference: #{inspect(reason)}"
    end
  end

  defp validate(%__MODULE__{
         scope_id: scope_id,
         run_id: run_id,
         agent_ref: agent_ref,
         model_ref: model_ref
       }) do
    new(scope_id, run_id, agent_ref, model_ref)
  end
end
