defmodule Tackle.AgentScope.Coordinator do
  @moduledoc """
  Fleet control plane for one root-agent scope.

  The coordinator records the logical ownership tree, serializes admission, and
  enforces resource limits. It is not an event relay: streaming deltas never
  pass through it. Admission and accounting are the only hot-path operations.

  ## Logical vs physical ownership

  Every descendant is a physical sibling under the scope's `WorkSupervisor`.
  The coordinator separately records parent/child edges so branch cancellation,
  depth accounting, per-agent child limits, and cycle prevention work without
  changing the physical tree.
  """

  use GenServer, restart: :temporary

  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Ref
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec

  @type entry :: %{
          ref: AgentRef.t(),
          pid: pid() | nil,
          monitor: reference() | nil,
          parent: AgentRef.t() | nil,
          depth: non_neg_integer(),
          lifetime: :explicit | :ephemeral,
          allow_delegation: boolean(),
          status: :pending | :live,
          children: MapSet.t(),
          cancelled: boolean()
        }

  @type state :: %{
          spec: ScopeSpec.t(),
          scope_ref: ScopeRef.t(),
          limits: Limits.t(),
          root_ref: AgentRef.t(),
          agents: %{optional(String.t()) => entry()},
          monitors: %{optional(reference()) => String.t()},
          turns: MapSet.t(),
          cancelled: term() | nil
        }

  @doc false
  @spec start_link(%{spec: ScopeSpec.t(), root_agent_ref: AgentRef.t()}) ::
          GenServer.on_start()
  def start_link(%{spec: %ScopeSpec{}, root_agent_ref: %AgentRef{}} = arg) do
    GenServer.start_link(__MODULE__, arg, name: via(arg.spec.scope_ref))
  end

  @doc false
  def via(scope_ref) do
    {:via, Registry, {Tackle.Runtime.Registry, {:coordinator, Ref.scope_id(scope_ref)}}}
  end

  @doc """
  Reserves a descendant agent slot for `parent_ref`.

  Returns the new `AgentRef` and the child's effective grants. The reservation
  is serialized, so concurrent spawns cannot oversubscribe a limit. The caller
  must `register_agent/3` after starting the process or `release_agent/2` on
  failure.
  """
  @spec admit_agent(GenServer.server(), Ref.t(), AgentSpec.t(), keyword()) ::
          {:ok,
           %{
             agent_ref: AgentRef.t(),
             limits: Limits.t(),
             depth: non_neg_integer(),
             allow_delegation: boolean()
           }}
          | {:error, term()}
  def admit_agent(coordinator, parent_ref, %AgentSpec{} = spec, opts \\ []) do
    GenServer.call(coordinator, {:admit_agent, parent_ref, spec, opts})
  end

  @doc "Binds a live process to an admitted agent reservation."
  @spec register_agent(GenServer.server(), AgentRef.t(), pid()) :: :ok | {:error, term()}
  def register_agent(coordinator, %AgentRef{} = agent_ref, pid) when is_pid(pid) do
    GenServer.call(coordinator, {:register_agent, agent_ref, pid})
  end

  @doc "Releases an admitted or live agent and its accounting exactly once."
  @spec release_agent(GenServer.server(), AgentRef.t()) :: :ok
  def release_agent(coordinator, %AgentRef{} = agent_ref) do
    GenServer.call(coordinator, {:release_agent, agent_ref})
  end

  @doc "Reserves one active turn for an agent, enforcing concurrency limits."
  @spec acquire_turn(GenServer.server(), AgentRef.t()) :: :ok | {:error, term()}
  def acquire_turn(coordinator, %AgentRef{} = agent_ref) do
    GenServer.call(coordinator, {:acquire_turn, agent_ref})
  end

  @doc "Releases a reserved turn. Idempotent for repeated calls."
  @spec release_turn(GenServer.server(), AgentRef.t()) :: :ok
  def release_turn(coordinator, %AgentRef{} = agent_ref) do
    GenServer.call(coordinator, {:release_turn, agent_ref})
  end

  @doc "Returns the coordinator's PID-free snapshot."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(coordinator), do: GenServer.call(coordinator, :snapshot)

  @doc "Returns one agent's snapshot, or an explicit error for a stale reference."
  @spec agent_snapshot(GenServer.server(), AgentRef.t()) :: {:ok, map()} | {:error, term()}
  def agent_snapshot(coordinator, %AgentRef{} = agent_ref) do
    GenServer.call(coordinator, {:agent_snapshot, agent_ref})
  end

  @doc "Resolves an allowlisted profile through this scope's trusted profiles."
  @spec resolve_profile(GenServer.server(), String.t()) ::
          {:ok, AgentSpec.t()} | {:error, term()}
  def resolve_profile(coordinator, name) do
    GenServer.call(coordinator, {:resolve_profile, name})
  end

  @doc "Cancels one logical branch, propagating to attached descendants."
  @spec cancel_branch(GenServer.server(), Ref.t(), term()) :: :ok
  def cancel_branch(coordinator, ref, reason \\ :cancelled) do
    GenServer.call(coordinator, {:cancel_branch, ref, reason})
  end

  @impl true
  def init(%{spec: %ScopeSpec{} = spec, root_agent_ref: %AgentRef{} = root_ref}) do
    state = %{
      spec: spec,
      scope_ref: spec.scope_ref,
      limits: spec.limits,
      root_ref: root_ref,
      agents: %{},
      monitors: %{},
      turns: MapSet.new(),
      cancelled: nil
    }

    root_entry = %{
      ref: root_ref,
      pid: nil,
      monitor: nil,
      parent: nil,
      depth: 0,
      lifetime: :explicit,
      allow_delegation: spec.root_spec.allow_delegation,
      status: :pending,
      children: MapSet.new(),
      cancelled: false
    }

    {:ok, put_agent(state, root_entry)}
  end

  @impl true
  def handle_call({:admit_agent, parent_ref, %AgentSpec{} = spec, opts}, _from, state) do
    {reply, state} = admit(state, parent_ref, spec, opts)
    {:reply, reply, state}
  end

  def handle_call({:register_agent, %AgentRef{} = agent_ref, pid}, _from, state) do
    case Map.fetch(state.agents, agent_ref.agent_id) do
      {:ok, %{ref: ^agent_ref} = entry} ->
        monitor = Process.monitor(pid)
        entry = %{entry | pid: pid, monitor: monitor, status: :live}

        state = %{
          state
          | agents: Map.put(state.agents, agent_ref.agent_id, entry),
            monitors: Map.put(state.monitors, monitor, agent_ref.agent_id)
        }

        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :not_admitted}, state}
    end
  end

  def handle_call({:release_agent, %AgentRef{} = agent_ref}, _from, state) do
    {:reply, :ok, remove_agent(state, agent_ref.agent_id)}
  end

  def handle_call({:acquire_turn, %AgentRef{} = agent_ref}, _from, state) do
    cond do
      state.cancelled ->
        {:reply, {:error, :cancelled}, state}

      not live_agent?(state, agent_ref) ->
        {:reply, {:error, :not_found}, state}

      MapSet.member?(state.turns, agent_ref.agent_id) ->
        {:reply, :ok, state}

      MapSet.size(state.turns) >= state.limits.max_concurrent_turns ->
        {:reply, {:error, :max_concurrent_turns}, state}

      true ->
        {:reply, :ok, %{state | turns: MapSet.put(state.turns, agent_ref.agent_id)}}
    end
  end

  def handle_call({:release_turn, %AgentRef{} = agent_ref}, _from, state) do
    {:reply, :ok, %{state | turns: MapSet.delete(state.turns, agent_ref.agent_id)}}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:agent_snapshot, %AgentRef{} = agent_ref}, _from, state) do
    case Map.fetch(state.agents, agent_ref.agent_id) do
      {:ok, entry} -> {:reply, {:ok, entry_snapshot(state, entry)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:resolve_profile, name}, _from, state) do
    {:reply, ScopeSpec.resolve_profile(state.spec, name), state}
  end

  def handle_call({:cancel_branch, ref, reason}, _from, state) do
    state =
      case ref do
        %AgentRef{agent_id: agent_id} -> cancel_agent(state, agent_id, reason)
        %ScopeRef{} -> %{state | cancelled: reason}
        _other -> state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} -> {:noreply, state}
      {agent_id, monitors} -> {:noreply, remove_agent(%{state | monitors: monitors}, agent_id)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp admit(state, parent_ref, spec, opts) do
    with :ok <- ensure_active(state),
         {:ok, parent} <- fetch_parent(state, parent_ref),
         :ok <- ensure_spawn_allowed(parent),
         :ok <- ensure_depth(state, parent),
         :ok <- ensure_child_capacity(state, parent),
         :ok <- ensure_agent_capacity(state) do
      agent_ref = AgentRef.new!(state.scope_ref.scope_id, ID.generate())
      allow_delegation = spec.allow_delegation and parent.allow_delegation

      entry = %{
        ref: agent_ref,
        pid: nil,
        monitor: nil,
        parent: parent.ref,
        depth: parent.depth + 1,
        lifetime: Keyword.get(opts, :lifetime, :ephemeral),
        allow_delegation: allow_delegation,
        status: :pending,
        children: MapSet.new(),
        cancelled: false
      }

      state = state |> put_agent(entry) |> add_child(parent.ref, agent_ref)

      reply =
        {:ok,
         %{
           agent_ref: agent_ref,
           limits: state.limits,
           depth: entry.depth,
           allow_delegation: allow_delegation
         }}

      {reply, state}
    else
      {:error, reason} -> {{:error, {:rejected, reason}}, state}
    end
  end

  defp ensure_active(%{cancelled: nil}), do: :ok
  defp ensure_active(%{cancelled: reason}), do: {:error, {:scope_cancelled, reason}}

  defp fetch_parent(state, %AgentRef{} = parent_ref) do
    case Map.fetch(state.agents, parent_ref.agent_id) do
      {:ok, %{ref: ^parent_ref} = parent} -> {:ok, parent}
      _other -> {:error, :parent_not_found}
    end
  end

  defp fetch_parent(_state, _ref), do: {:error, :invalid_parent}

  defp ensure_spawn_allowed(%{allow_delegation: true}), do: :ok
  defp ensure_spawn_allowed(%{allow_delegation: false}), do: {:error, :delegation_not_allowed}

  defp ensure_depth(%{limits: %Limits{max_spawn_depth: max_depth}}, %{depth: parent_depth}) do
    if parent_depth + 1 <= max_depth, do: :ok, else: {:error, :max_spawn_depth}
  end

  defp ensure_child_capacity(state, parent) do
    if MapSet.size(parent.children) < state.limits.max_children_per_agent do
      :ok
    else
      {:error, :max_children_per_agent}
    end
  end

  defp ensure_agent_capacity(state) do
    if map_size(state.agents) < state.limits.max_agents_per_fleet do
      :ok
    else
      {:error, :max_agents_per_fleet}
    end
  end

  defp live_agent?(state, %AgentRef{agent_id: agent_id}) do
    match?({:ok, %{status: :live}}, Map.fetch(state.agents, agent_id))
  end

  defp put_agent(state, entry) do
    %{state | agents: Map.put(state.agents, entry.ref.agent_id, entry)}
  end

  defp update_agent(state, %AgentRef{agent_id: agent_id}, fun) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, entry} -> %{state | agents: Map.put(state.agents, agent_id, fun.(entry))}
      :error -> state
    end
  end

  defp add_child(state, %AgentRef{} = parent_ref, %AgentRef{agent_id: child_id}) do
    update_agent(state, parent_ref, fn entry ->
      %{entry | children: MapSet.put(entry.children, child_id)}
    end)
  end

  defp remove_agent(state, agent_id) do
    case Map.pop(state.agents, agent_id) do
      {nil, _agents} ->
        state

      {entry, agents} ->
        state = %{state | agents: agents, turns: MapSet.delete(state.turns, agent_id)}
        state = detach_from_parent(state, entry)
        state = demonitor(state, entry)
        cancel_children(state, entry.children, :parent_terminated)
    end
  end

  defp detach_from_parent(state, %{parent: nil}), do: state

  defp detach_from_parent(state, %{parent: %AgentRef{} = parent_ref, ref: ref}) do
    update_agent(state, parent_ref, fn entry ->
      %{entry | children: MapSet.delete(entry.children, ref.agent_id)}
    end)
  end

  defp demonitor(state, %{monitor: nil}), do: state

  defp demonitor(state, %{monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    %{state | monitors: Map.delete(state.monitors, monitor)}
  end

  defp cancel_children(state, children, reason) do
    Enum.reduce(children, state, fn child_id, acc -> cancel_agent(acc, child_id, reason) end)
  end

  defp cancel_agent(state, agent_id, reason) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, entry} ->
        if entry.pid, do: send(entry.pid, {:runtime_cancel, reason})

        state = update_agent(state, entry.ref, &%{&1 | cancelled: true})
        cancel_children(state, entry.children, reason)

      :error ->
        state
    end
  end

  defp build_snapshot(state) do
    %{
      scope_ref: state.scope_ref,
      cancelled: state.cancelled,
      limits: state.limits,
      agent_count: map_size(state.agents),
      active_turns: MapSet.size(state.turns),
      agents: Map.new(state.agents, fn {id, entry} -> {id, entry_snapshot(state, entry)} end)
    }
  end

  defp entry_snapshot(state, entry) do
    %{
      ref: entry.ref,
      pid: entry.pid,
      status: entry.status,
      parent: entry.parent,
      depth: entry.depth,
      lifetime: entry.lifetime,
      allow_delegation: entry.allow_delegation,
      cancelled: entry.cancelled,
      child_count: MapSet.size(entry.children),
      active_turn?: MapSet.member?(state.turns, entry.ref.agent_id)
    }
  end
end
