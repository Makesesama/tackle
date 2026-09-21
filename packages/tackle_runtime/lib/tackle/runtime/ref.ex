defmodule Tackle.Runtime.Ref do
  @moduledoc """
  Shared helpers for the runtime reference types.

  References are the public, PID-free addressing model. This module centralizes
  the registry key shape and scope extraction used by routing and supervision.
  """

  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.RunRef
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.WorkflowRef

  @type t :: ScopeRef.t() | AgentRef.t() | WorkflowRef.t() | RunRef.t()

  @doc "Returns the owning scope reference for any runtime reference."
  @spec scope_ref(t()) :: ScopeRef.t()
  def scope_ref(%ScopeRef{} = ref), do: ref
  def scope_ref(%{scope_id: scope_id}), do: %ScopeRef{scope_id: scope_id}

  @doc "Returns the owning scope id for any runtime reference."
  @spec scope_id(t()) :: String.t()
  def scope_id(ref), do: scope_ref(ref).scope_id

  @doc """
  Returns the unique Registry key for a runtime reference.

  Keys are stable tuples so scope, agent, workflow, and run registrations can
  share one Registry without collisions.
  """
  @spec registry_key(t()) :: tuple()
  def registry_key(%ScopeRef{scope_id: scope_id}), do: {:scope, scope_id}

  def registry_key(%AgentRef{scope_id: scope_id, agent_id: agent_id}),
    do: {:agent, scope_id, agent_id}

  def registry_key(%WorkflowRef{scope_id: scope_id, workflow_id: workflow_id}),
    do: {:workflow, scope_id, workflow_id}

  def registry_key(%RunRef{scope_id: scope_id, run_id: run_id}),
    do: {:run, scope_id, run_id}

  @doc "Returns true when `value` is one of the runtime reference structs."
  @spec valid?(term()) :: boolean()
  def valid?(%ScopeRef{} = ref), do: match?({:ok, _}, ScopeRef.new(ref))
  def valid?(%AgentRef{} = ref), do: match?({:ok, _}, AgentRef.new(ref))
  def valid?(%WorkflowRef{} = ref), do: match?({:ok, _}, WorkflowRef.new(ref))
  def valid?(%RunRef{} = ref), do: match?({:ok, _}, RunRef.new(ref))
  def valid?(_value), do: false

  @doc """
  Looks up the live process for a reference.

  Returns `{:error, :not_found}` for a stale or unknown reference rather than
  raising, so callers can treat terminated entities as explicit outcomes.
  """
  @spec whereis(t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(ref) do
    case Registry.lookup(Tackle.Runtime.Registry, registry_key(ref)) do
      [{pid, _value}] when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end
end
