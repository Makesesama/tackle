defmodule Tackle.Runtime.Scope do
  @moduledoc """
  PID-free handle for one started root-agent scope.

  Starting a scope returns this value: a `Tackle.Runtime.ScopeRef` for lifecycle
  operations and the root `Tackle.Runtime.AgentRef` for agent operations. The
  scope supervisor PID stays below the runtime boundary and is never part of the
  public handle.

      {:ok, scope} = Tackle.start_scope(scope_spec)

      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, prompt)

      :ok = Tackle.stop_scope(scope.scope_ref)
  """

  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.ScopeRef

  @enforce_keys [:scope_ref, :root_agent_ref]
  defstruct [:scope_ref, :root_agent_ref]

  @type t :: %__MODULE__{
          scope_ref: ScopeRef.t(),
          root_agent_ref: AgentRef.t()
        }
end
