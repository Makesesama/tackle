defmodule Tackle.Runtime do
  @moduledoc """
  Public runtime API for root-agent scopes, delegated agents, and cancellation.

  The runtime is the root-harness orchestration layer above `Tackle.Lib`. It
  addresses everything by stable references (`Tackle.Runtime.ScopeRef`,
  `AgentRef`, `WorkflowRef`, `RunRef`) and never requires callers to hold PIDs.

  A scope is one root agent plus every descendant it creates and is also the
  fleet boundary for the initial coding harness. See `docs/RUNTIME_ARCHITECTURE.md`.
  """

  alias Tackle.AgentScope.Coordinator
  alias Tackle.AgentSupervisor
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Ref
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.Request
  alias Tackle.Runtime.RunRef
  alias Tackle.Runtime.Scope
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Runtime.Workflow
  alias Tackle.Runtime.Workflow.Server, as: WorkflowServer
  alias Tackle.Runtime.WorkflowRef
  alias Tackle.Session

  @doc """
  Starts one root-agent scope from a trusted `ScopeSpec`.

  Returns a PID-free `Tackle.Runtime.Scope` holding the scope reference for
  lifecycle operations and the root agent reference for agent operations. The
  scope supervisor PID is never part of the public result.
  """
  @spec start_scope(ScopeSpec.t(), keyword()) :: {:ok, Scope.t()} | {:error, term()}
  def start_scope(%ScopeSpec{} = spec, opts \\ []) do
    case AgentSupervisor.start_scope(spec, opts) do
      {:ok, %{scope_ref: scope_ref, root_agent_ref: root_agent_ref}} ->
        {:ok, %Scope{scope_ref: scope_ref, root_agent_ref: root_agent_ref}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Stops one root scope and every process beneath it."
  @spec stop_scope(ScopeRef.t()) :: :ok | {:error, term()}
  def stop_scope(%ScopeRef{} = scope_ref), do: AgentSupervisor.stop_scope(scope_ref)

  @doc "Returns the root agent reference for a scope."
  @spec root_agent_ref(ScopeRef.t()) :: {:ok, AgentRef.t()} | {:error, term()}
  def root_agent_ref(%ScopeRef{} = scope_ref), do: Registry.root_agent_ref(scope_ref)

  @doc "Returns the coordinator snapshot for a scope."
  @spec scope_snapshot(ScopeRef.t()) :: {:ok, map()} | {:error, term()}
  def scope_snapshot(%ScopeRef{} = scope_ref) do
    with {:ok, coordinator} <- coordinator(scope_ref) do
      snapshot =
        coordinator
        |> Coordinator.snapshot()
        |> Map.put(:workflow_count, Registry.workflow_count(scope_ref))

      {:ok, snapshot}
    end
  end

  @doc "Returns one agent's PID-free snapshot."
  @spec agent_snapshot(AgentRef.t()) :: {:ok, map()} | {:error, term()}
  def agent_snapshot(%AgentRef{} = agent_ref) do
    with {:ok, coordinator} <- coordinator(agent_ref) do
      Coordinator.agent_snapshot(coordinator, agent_ref)
    end
  end

  @doc "Returns the live session process for an agent reference."
  @spec session_pid(AgentRef.t()) :: {:ok, pid()} | {:error, term()}
  def session_pid(%AgentRef{} = agent_ref), do: Registry.whereis(agent_ref)

  @doc """
  Monitors the process behind an agent reference without exposing its PID.

  Returns a monitor reference for `{:DOWN, ref, :process, pid, reason}`
  deliveries. Stale references return an explicit error instead of raising, so
  frontends can centralize crash detection without retaining PIDs.
  """
  @spec monitor_agent(AgentRef.t()) :: {:ok, reference()} | {:error, term()}
  def monitor_agent(%AgentRef{} = agent_ref) do
    with {:ok, pid} <- session_pid(agent_ref), do: {:ok, Process.monitor(pid)}
  end

  @doc "Submits one turn to an agent and appends a user message."
  @spec submit(AgentRef.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def submit(%AgentRef{} = agent_ref, input) do
    with_session(agent_ref, &Session.submit(&1, input))
  end

  @doc "Continues an agent conversation without appending a user message."
  @spec continue(AgentRef.t()) :: {:ok, String.t()} | {:error, term()}
  def continue(%AgentRef{} = agent_ref) do
    with_session(agent_ref, &Session.continue/1)
  end

  @doc "Requests cooperative cancellation of an agent's active turn."
  @spec cancel_turn(AgentRef.t()) :: :ok | {:error, term()}
  def cancel_turn(%AgentRef{} = agent_ref) do
    with_session(agent_ref, &Session.cancel/1)
  end

  @doc """
  Explicitly abandons an interrupted durable turn for an agent.

  Resuming a session whose journal ends without a terminal turn event requires
  an explicit recovery decision; this records `turn.abandoned` and clears the
  recovery gate.
  """
  @spec abandon_turn(AgentRef.t()) :: :ok | {:error, term()}
  def abandon_turn(%AgentRef{} = agent_ref) do
    with_session(agent_ref, &Session.abandon_turn/1)
  end

  @doc "Subscribes the caller to an agent's correlated events and terminal outcomes."
  @spec subscribe(AgentRef.t()) :: {:ok, Tackle.Session.Snapshot.t()} | {:error, term()}
  def subscribe(%AgentRef{} = agent_ref) do
    with_session(agent_ref, &Session.subscribe/1)
  end

  @doc "Unsubscribes the caller from an agent's deliveries."
  @spec unsubscribe(AgentRef.t()) :: :ok | {:error, term()}
  def unsubscribe(%AgentRef{} = agent_ref) do
    with_session(agent_ref, &Session.unsubscribe/1)
  end

  @doc "Updates an idle agent's model and thinking settings."
  @spec reconfigure(AgentRef.t(), keyword()) ::
          {:ok, Tackle.Session.Snapshot.t()} | {:error, term()}
  def reconfigure(%AgentRef{} = agent_ref, opts) when is_list(opts) do
    with_session(agent_ref, &Session.reconfigure(&1, opts))
  end

  def reconfigure(%AgentRef{}, opts), do: {:error, {:invalid_config, opts}}

  @doc "Returns an agent's atomic conversation snapshot."
  @spec session_snapshot(AgentRef.t()) :: {:ok, Tackle.Session.Snapshot.t()} | {:error, term()}
  def session_snapshot(%AgentRef{} = agent_ref) do
    with_session(agent_ref, fn pid -> {:ok, Session.snapshot(pid)} end)
  end

  @doc """
  Requests one delegated run from an agent or workflow requester.

  `spec_or_profile` is either an allowlisted profile name (the model-visible
  form) or a trusted `AgentSpec`. The coordinator admits the child, a request
  helper installs correlated terminal routing, and a fresh ephemeral agent runs
  the delegated prompt. Returns a stable `RunRef` for `await/2`.
  """
  @spec request_agent(
          Handle.t() | AgentRef.t(),
          String.t() | AgentSpec.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, RunRef.t()} | {:error, term()}
  def request_agent(requester, spec_or_profile, prompt, opts \\ [])

  def request_agent(requester, spec_or_profile, prompt, opts) when is_binary(prompt) do
    with {:ok, scope_ref, parent_ref} <- resolve_requester(requester),
         {:ok, coordinator} <- coordinator(scope_ref),
         {:ok, spec} <- resolve_spec(coordinator, spec_or_profile),
         {:ok, work_supervisor} <- Registry.work_supervisor(scope_ref),
         {:ok, admission} <-
           Coordinator.admit_agent(coordinator, parent_ref, spec, lifetime: :ephemeral) do
      run_ref = RunRef.new!(scope_ref.scope_id, ID.generate(), admission.agent_ref)

      arg = %{
        scope_ref: scope_ref,
        agent_ref: admission.agent_ref,
        run_ref: run_ref,
        requester: self(),
        config: spec.config,
        prompt: prompt,
        work_supervisor: work_supervisor,
        coordinator: coordinator,
        allow_delegation: admission.allow_delegation,
        limits: admission.limits,
        parent: %{agent_ref: parent_ref},
        timeout: Keyword.get(opts, :timeout, AgentSpec.timeout(spec, admission.limits))
      }

      case DynamicSupervisor.start_child(work_supervisor, Request.child_spec(arg)) do
        {:ok, _pid} ->
          {:ok, run_ref}

        {:error, reason} ->
          Coordinator.release_agent(coordinator, admission.agent_ref)
          {:error, {:request_start_failed, reason}}
      end
    end
  end

  def request_agent(_requester, _spec_or_profile, prompt, _opts),
    do: {:error, {:invalid_prompt, prompt}}

  @doc "Waits for one correlated run outcome."
  @spec await(RunRef.t(), timeout()) :: Outcome.t() | {:error, term()}
  def await(%RunRef{} = run_ref, timeout \\ :infinity), do: Request.await(run_ref, timeout)

  @doc """
  Starts one host-defined workflow under the scope work supervisor.

  The workflow's delegated runs are admitted as children of `parent`, so scope
  limits, spawn depth, and cancellation apply unchanged. Returns a stable
  `WorkflowRef` for `await_workflow/2`.
  """
  @spec start_workflow(Handle.t() | AgentRef.t(), module(), term(), keyword()) ::
          {:ok, WorkflowRef.t()} | {:error, term()}
  def start_workflow(parent, module, input, opts \\ []) when is_atom(module) do
    with {:ok, scope_ref, parent_ref} <- resolve_requester(parent),
         {:ok, coordinator} <- coordinator(scope_ref),
         {:ok, work_supervisor} <- Registry.work_supervisor(scope_ref),
         {:ok, parent_snapshot} <- Coordinator.agent_snapshot(coordinator, parent_ref) do
      limits = Coordinator.snapshot(coordinator).limits
      workflow_ref = WorkflowRef.new!(scope_ref.scope_id, ID.generate())

      handle =
        Handle.new(scope_ref, parent_ref,
          allow_delegation: parent_snapshot.allow_delegation,
          limits: limits
        )

      arg = %{
        workflow_ref: workflow_ref,
        module: module,
        input: input,
        handle: handle,
        work_supervisor: work_supervisor,
        timeout: Keyword.get(opts, :timeout, limits.workflow_timeout)
      }

      case DynamicSupervisor.start_child(work_supervisor, WorkflowServer.child_spec(arg)) do
        {:ok, _pid} -> {:ok, workflow_ref}
        {:error, reason} -> {:error, {:workflow_start_failed, reason}}
      end
    end
  end

  @doc "Waits for a workflow's terminal result."
  @spec await_workflow(WorkflowRef.t(), timeout()) :: term()
  def await_workflow(%WorkflowRef{} = workflow_ref, timeout \\ :infinity) do
    case Registry.workflow(workflow_ref) do
      {:ok, server} ->
        try do
          WorkflowServer.await(server, timeout)
        catch
          :exit, reason -> {:error, {:workflow_terminated, reason}}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Launches several delegated runs and returns their correlated run references.

  Requests are admitted one at a time so scope limits apply, but the runs start
  as they are admitted and therefore overlap. Partial admission returns
  `{:error, {:partial, admitted, reason}}` without cancelling the admitted runs;
  callers decide the failure policy.
  """
  @spec request_many(Handle.t() | AgentRef.t(), [Workflow.request()], keyword()) ::
          {:ok, [RunRef.t()]} | {:error, term()}
  def request_many(requester, requests, opts \\ []) when is_list(requests) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, acc} ->
      {profile, prompt, request_opts} = Workflow.normalize_request(request)

      case request_agent(requester, profile, prompt, Keyword.merge(opts, request_opts)) do
        {:ok, run_ref} -> {:cont, {:ok, [run_ref | acc]}}
        {:error, reason} -> {:halt, {:error, {:partial, Enum.reverse(acc), reason}}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      other -> other
    end
  end

  @doc "Awaits several runs, preserving input order and correlation."
  @spec await_many([RunRef.t()], timeout()) :: [{RunRef.t(), Outcome.t() | {:error, term()}}]
  def await_many(run_refs, timeout \\ :infinity) when is_list(run_refs) do
    Enum.map(run_refs, fn %RunRef{} = run_ref -> {run_ref, await(run_ref, timeout)} end)
  end

  @doc """
  Cancels a runtime entity.

  A scope is stopped physically; an agent branch is cancelled cooperatively
  through the coordinator, which propagates to attached descendants.
  """
  @spec cancel(Ref.t(), term()) :: :ok | {:error, term()}
  def cancel(ref, reason \\ :cancelled)
  def cancel(%ScopeRef{} = scope_ref, _reason), do: stop_scope(scope_ref)

  def cancel(%AgentRef{} = agent_ref, reason) do
    with {:ok, coordinator} <- coordinator(agent_ref),
         do: Coordinator.cancel_branch(coordinator, agent_ref, reason)
  end

  def cancel(%RunRef{} = run_ref, reason) do
    with {:ok, request} <- Registry.whereis(run_ref), do: Request.cancel(request, reason)
  end

  def cancel(%WorkflowRef{} = workflow_ref, reason) do
    with {:ok, server} <- Registry.workflow(workflow_ref),
         do: WorkflowServer.cancel(server, reason)
  end

  @doc "Projects an outcome into a `Tackle.Lib`-style result."
  defdelegate to_lib_result(outcome), to: Outcome

  defp with_session(%AgentRef{} = agent_ref, fun) do
    case Registry.whereis(agent_ref) do
      {:ok, pid} ->
        try do
          fun.(pid)
        catch
          :exit, reason -> {:error, {:agent_unavailable, reason}}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp coordinator(ref) do
    case Registry.coordinator(ref) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> {:error, :scope_not_found}
    end
  end

  defp resolve_requester(%Handle{scope_ref: scope_ref, agent_ref: agent_ref}) do
    {:ok, scope_ref, agent_ref}
  end

  defp resolve_requester(%AgentRef{} = agent_ref) do
    {:ok, Ref.scope_ref(agent_ref), agent_ref}
  end

  defp resolve_requester(other), do: {:error, {:invalid_requester, other}}

  defp resolve_spec(_coordinator, %AgentSpec{} = spec), do: AgentSpec.new(spec)

  defp resolve_spec(coordinator, name) when is_binary(name) do
    Coordinator.resolve_profile(coordinator, name)
  end

  defp resolve_spec(_coordinator, other), do: {:error, {:invalid_agent_spec, other}}
end
