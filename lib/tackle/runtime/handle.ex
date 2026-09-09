defmodule Tackle.Runtime.Handle do
  @moduledoc """
  Opaque, authorized runtime handle supplied to an agent through its context.

  The harness injects one handle into `Tackle.Lib.State.context[:runtime]` for
  every scoped agent. It exposes the agent's own identity, its scope, whether it
  may delegate further, and the inherited limits. It never contains PIDs,
  supervisor names, or executable modules, so model-visible tool arguments
  cannot widen runtime permissions.
  """

  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.ScopeRef

  @enforce_keys [:scope_ref, :agent_ref]
  defstruct [:scope_ref, :agent_ref, allow_recursion: false, limits: nil]

  @type t :: %__MODULE__{
          scope_ref: ScopeRef.t(),
          agent_ref: AgentRef.t(),
          allow_recursion: boolean(),
          limits: Limits.t() | nil
        }

  @doc "Builds a handle from a scope, agent, and the agent's effective grants."
  @spec new(ScopeRef.t(), AgentRef.t(), keyword() | map()) :: t()
  def new(%ScopeRef{} = scope_ref, %AgentRef{} = agent_ref, opts \\ []) do
    %__MODULE__{
      scope_ref: scope_ref,
      agent_ref: agent_ref,
      allow_recursion: fetch(opts, :allow_recursion, false),
      limits: fetch(opts, :limits, nil)
    }
  end

  @doc "Returns the handle stored in an agent context, if any."
  @spec from_context(map() | nil) :: t() | nil
  def from_context(context) when is_map(context) do
    case Map.get(context, :runtime) || Map.get(context, "runtime") do
      %__MODULE__{} = handle -> handle
      _other -> nil
    end
  end

  def from_context(_context), do: nil

  defp fetch(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp fetch(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
end
