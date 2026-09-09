defmodule Tackle do
  @moduledoc """
  Public facade for the frontend-independent Tackle developer harness.

  The harness is started as a *scope*: one root agent plus every descendant it
  creates. Starting a scope returns a PID-free `Tackle.Runtime.Scope` containing
  a `Tackle.Runtime.ScopeRef` for lifecycle operations and the root
  `Tackle.Runtime.AgentRef` for agent operations. Every agent operation addresses
  a stable reference, never a session PID.

      {:ok, scope} = Tackle.start_scope(scope_spec)

      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, prompt)

      :ok = Tackle.stop_scope(scope.scope_ref)

  `Tackle.Config.load/1` loads exactly one agent's execution configuration.
  Trusted host or distribution code composes that value into a
  `Tackle.Runtime.AgentSpec` and `Tackle.Runtime.ScopeSpec` before starting the
  runtime.
  """

  alias Tackle.Config
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Scope
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec

  @doc """
  Starts a root-agent scope from a trusted `Tackle.Runtime.ScopeSpec`.

  Returns a PID-free `Tackle.Runtime.Scope`. Invalid delegation grants and
  limits fail validation before any process starts.
  """
  @spec start_scope(ScopeSpec.t()) :: {:ok, Scope.t()} | {:error, term()}
  def start_scope(%ScopeSpec{} = spec), do: Runtime.start_scope(spec)

  @doc "Stops one root scope and every process beneath it."
  @spec stop_scope(ScopeRef.t()) :: :ok | {:error, term()}
  def stop_scope(%ScopeRef{} = scope_ref), do: Runtime.stop_scope(scope_ref)

  @doc "Returns the fleet/scope control-plane snapshot."
  @spec scope_snapshot(ScopeRef.t()) :: {:ok, map()} | {:error, term()}
  def scope_snapshot(%ScopeRef{} = scope_ref), do: Runtime.scope_snapshot(scope_ref)

  @doc "Loads validated frontend-independent configuration through the harness plugin registry."
  @spec load_config(keyword()) :: {:ok, Config.t()} | {:error, term()}
  def load_config(opts \\ []) when is_list(opts), do: Config.load(opts)

  @doc "Returns canonical model references available through configured adapters."
  @spec available_models() :: {:ok, [String.t()]} | {:error, term()}
  def available_models, do: Tackle.Plugins.available_model_refs()

  @doc """
  Monitors the process behind an agent reference without exposing its PID.

  Returns a monitor reference for `{:DOWN, ref, :process, pid, reason}`
  deliveries; stale references return an explicit error.
  """
  @spec monitor_agent(AgentRef.t()) :: {:ok, reference()} | {:error, term()}
  def monitor_agent(%AgentRef{} = agent_ref), do: Runtime.monitor_agent(agent_ref)

  @doc "Starts a turn and appends one user message."
  @spec submit(AgentRef.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def submit(%AgentRef{} = agent_ref, input), do: Runtime.submit(agent_ref, input)

  @doc "Continues the conversation without appending another user message."
  @spec continue(AgentRef.t()) :: {:ok, String.t()} | {:error, term()}
  def continue(%AgentRef{} = agent_ref), do: Runtime.continue(agent_ref)

  @doc "Requests cooperative cancellation of the active turn."
  @spec cancel(AgentRef.t()) :: :ok | {:error, term()}
  def cancel(%AgentRef{} = agent_ref), do: Runtime.cancel_turn(agent_ref)

  @doc "Updates model and thinking settings while the agent is idle."
  @spec reconfigure(AgentRef.t(), keyword()) ::
          {:ok, Tackle.Session.Snapshot.t()} | {:error, term()}
  def reconfigure(%AgentRef{} = agent_ref, opts), do: Runtime.reconfigure(agent_ref, opts)

  @doc "Returns the agent's atomic conversation snapshot."
  @spec snapshot(AgentRef.t()) :: {:ok, Tackle.Session.Snapshot.t()} | {:error, term()}
  def snapshot(%AgentRef{} = agent_ref), do: Runtime.session_snapshot(agent_ref)

  @doc "Subscribes the caller to correlated session events and terminal outcomes."
  @spec subscribe(AgentRef.t()) :: {:ok, Tackle.Session.Snapshot.t()} | {:error, term()}
  def subscribe(%AgentRef{} = agent_ref), do: Runtime.subscribe(agent_ref)

  @doc "Unsubscribes the caller from session deliveries."
  @spec unsubscribe(AgentRef.t()) :: :ok | {:error, term()}
  def unsubscribe(%AgentRef{} = agent_ref), do: Runtime.unsubscribe(agent_ref)
end
