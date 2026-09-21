defmodule Tackle.Runtime do
  @moduledoc """
  Public runtime API for root-agent scopes, delegated agents, and cancellation.

  The runtime is a reusable orchestration layer above `Tackle.Lib`. It
  addresses everything by stable references (`Tackle.Runtime.ScopeRef`,
  `AgentRef`, `WorkflowRef`, `RunRef`) and never requires callers to hold PIDs.
  Concrete agent lifecycle and host policy are supplied through
  `Tackle.Runtime.AgentBackend`.

  A scope is one root agent plus every descendant it creates and forms the
  runtime's physical cleanup and logical ownership boundary.
  """

  alias Tackle.AgentScope.Coordinator
  alias Tackle.AgentSupervisor
  alias Tackle.Runtime.AgentBackend
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
  @spec submit(AgentRef.t(), String.t()) ::
          {:ok, String.t() | :queued} | {:error, term()}
  def submit(%AgentRef{} = agent_ref, input) do
    with_agent(agent_ref, :submit, [input])
  end

  @doc "Continues an agent conversation without appending a user message."
  @spec continue(AgentRef.t()) :: {:ok, String.t()} | {:error, term()}
  def continue(%AgentRef{} = agent_ref) do
    with_agent(agent_ref, :continue, [])
  end

  @doc "Requests cooperative cancellation of an agent's active turn."
  @spec cancel_turn(AgentRef.t()) :: :ok | {:error, term()}
  def cancel_turn(%AgentRef{} = agent_ref) do
    with_agent(agent_ref, :cancel, [:user_cancelled])
  end

  @doc """
  Explicitly abandons an interrupted durable turn for an agent.

  Resuming a session whose journal ends without a terminal turn event requires
  an explicit recovery decision; this records `turn.abandoned` and clears the
  recovery gate.
  """
  @spec abandon_turn(AgentRef.t()) :: :ok | {:error, term()}
  def abandon_turn(%AgentRef{} = agent_ref) do
    with_agent(agent_ref, :abandon_turn, [])
  end

  @doc "Subscribes the caller to an agent's correlated events and terminal outcomes."
  @spec subscribe(AgentRef.t()) :: {:ok, term()} | :ok | {:error, term()}
  def subscribe(%AgentRef{} = agent_ref) do
    with_agent(agent_ref, :subscribe, [])
  end

  @doc "Unsubscribes the caller from an agent's deliveries."
  @spec unsubscribe(AgentRef.t()) :: :ok | {:error, term()}
  def unsubscribe(%AgentRef{} = agent_ref) do
    with_agent(agent_ref, :unsubscribe, [])
  end

  @doc "Updates an idle agent's model and thinking settings."
  @spec reconfigure(AgentRef.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def reconfigure(%AgentRef{} = agent_ref, opts) when is_list(opts) do
    with_agent(agent_ref, :reconfigure, [opts])
  end

  def reconfigure(%AgentRef{}, opts), do: {:error, {:invalid_config, opts}}

  @doc "Returns an agent's atomic conversation snapshot."
  @spec session_snapshot(AgentRef.t()) :: {:ok, term()} | {:error, term()}
  def session_snapshot(%AgentRef{} = agent_ref) do
    case with_agent(agent_ref, :snapshot, []) do
      {:error, _reason} = error -> error
      snapshot -> {:ok, snapshot}
    end
  end

  @doc "Delivers text to an in-scope agent's bounded next-turn inbox."
  @spec tell(AgentRef.t(), AgentRef.t(), String.t()) :: :ok | {:error, term()}
  def tell(%AgentRef{} = from, %AgentRef{} = to, message) when is_binary(message) do
    cond do
      from.scope_id != to.scope_id ->
        {:error, :scope_mismatch}

      message == "" ->
        {:error, :empty_message}

      true ->
        with {:ok, coordinator} <- coordinator(from),
             {:ok, _sender} <- Coordinator.agent_snapshot(coordinator, from),
             {:ok, _recipient} <- Coordinator.agent_snapshot(coordinator, to) do
          with_agent(to, :deliver, [from, message])
        end
    end
  end

  def tell(%AgentRef{}, %AgentRef{}, message), do: {:error, {:invalid_message, message}}

  @doc """
  Runs one manual compaction of an idle agent's model surface.

  Returns the post-compaction snapshot and the durable compaction record.
  Rejected during an active turn or while an interrupted turn awaits recovery.
  """
  @spec compact(AgentRef.t(), keyword()) :: {:ok, term(), term()} | {:error, term()}
  def compact(agent_ref, opts \\ [])

  def compact(%AgentRef{} = agent_ref, opts) when is_list(opts) do
    with_agent(agent_ref, :compact, [opts])
  end

  def compact(%AgentRef{}, opts), do: {:error, {:invalid_compact_options, opts}}

  @doc """
  Reads an agent's conversation tree.

  Returns `{:ok, nil}` when the agent has branching disabled and the
  `Tackle.Lib.Tree` otherwise. The tree is a pure value, so the caller never
  receives a journal PID or a runtime handle.
  """
  @spec tree(AgentRef.t()) :: {:ok, Tackle.Lib.Tree.t() | nil} | {:error, term()}
  def tree(%AgentRef{} = agent_ref) do
    with_agent(agent_ref, :tree, [])
  end

  @doc """
  Navigates an idle agent's conversation tree.

  The destination is validated and committed to the journal before the new
  active position is installed and published to subscribers. Rejected during an
  active turn or while an interrupted turn awaits recovery.
  """
  @spec navigate(AgentRef.t(), term(), keyword()) ::
          {:ok, term(), term()} | {:error, term()}
  def navigate(agent_ref, target, opts \\ [])

  def navigate(%AgentRef{} = agent_ref, target, opts) when is_list(opts) do
    with_agent(agent_ref, :navigate, [target, opts])
  end

  def navigate(%AgentRef{}, _target, opts), do: {:error, {:invalid_navigation_options, opts}}

  @doc """
  Requests one delegated run from an agent or workflow requester.

  `spec_or_profile` is either an allowlisted profile name (the model-visible
  form) or a trusted `AgentSpec`. The coordinator admits the child, a request
  helper installs correlated terminal routing, and a fresh ephemeral agent runs
  the delegated prompt. Returns a stable `RunRef` for `await/2`.

  A trusted spec with `model_source: :parent` copies only the requesting agent's
  model reference and thinking level at request time, resolving against the
  child's configured adapters before admission. Resolution runs outside the
  coordinator to avoid calling an agent from inside its admission owner.
  The model is captured after parent-inheritance resolution and included in the
  returned run reference, so callers can display the actual child selection
  without racing its ephemeral session. Existing runs and profiles with
  `model_source: :configured` are unchanged.
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
         {:ok, backend} <- Registry.backend(scope_ref),
         {:ok, spec} <- resolve_spec(coordinator, spec_or_profile),
         {:ok, parent_pid} <- Registry.whereis(parent_ref),
         {:ok, spec} <- AgentBackend.prepare_child(backend, spec, parent_pid),
         {:ok, work_supervisor} <- Registry.work_supervisor(scope_ref),
         {:ok, admission} <-
           Coordinator.admit_agent(coordinator, parent_ref, spec, lifetime: :ephemeral) do
      run_ref =
        RunRef.new!(
          scope_ref.scope_id,
          ID.generate(),
          admission.agent_ref,
          AgentBackend.model_ref(backend, spec)
        )

      arg = %{
        scope_ref: scope_ref,
        agent_ref: admission.agent_ref,
        run_ref: run_ref,
        requester: request_owner(opts, parent_ref),
        backend: backend,
        agent_spec: spec,
        prompt: prompt,
        work_supervisor: work_supervisor,
        coordinator: coordinator,
        allow_delegation: admission.allow_delegation,
        limits: admission.limits,
        parent: %{agent_ref: parent_ref},
        timeout: Keyword.get(opts, :timeout, AgentSpec.timeout(spec, admission.limits)),
        event_callback: Keyword.get(opts, :event_callback),
        completion_callback: Keyword.get(opts, :completion_callback),
        completion_message: Keyword.get(opts, :completion_message),
        launch_message: Keyword.get(opts, :launch_message),
        origin: Keyword.get(opts, :origin),
        profile: spec.name,
        retention: Keyword.get(opts, :retention, :linger)
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

  @doc "Waits for one correlated terminal outcome and consumes the run."
  @spec await(RunRef.t(), timeout()) :: Outcome.t() | {:error, term()}
  def await(%RunRef{} = run_ref, timeout \\ :infinity), do: Request.await(run_ref, timeout)

  @doc "Waits for and consumes a run only when it belongs to `owner`."
  @spec await(AgentRef.t(), RunRef.t(), timeout()) :: Outcome.t() | {:error, term()}
  def await(%AgentRef{} = owner, %RunRef{} = run_ref, timeout) do
    Request.await(run_ref, owner, timeout)
  end

  @doc "Returns whether a delegated run is still running or has completed."
  @spec run_status(RunRef.t()) ::
          {:ok, :running | {:completed, Outcome.t()}} | {:error, term()}
  def run_status(%RunRef{} = run_ref), do: Request.status(run_ref)

  @doc "Returns run status only when the run belongs to `owner`."
  @spec run_status(AgentRef.t(), RunRef.t()) ::
          {:ok, :running | {:completed, Outcome.t()}} | {:error, term()}
  def run_status(%AgentRef{} = owner, %RunRef{} = run_ref), do: Request.status(run_ref, owner)

  @doc "Collects a completed delegated run and releases its retained outcome."
  @spec collect(RunRef.t()) :: Outcome.t() | {:error, term()}
  def collect(%RunRef{} = run_ref), do: Request.collect(run_ref)

  @doc "Collects a completed delegated run only when it belongs to `owner`."
  @spec collect(AgentRef.t(), RunRef.t()) :: Outcome.t() | {:error, term()}
  def collect(%AgentRef{} = owner, %RunRef{} = run_ref), do: Request.collect(run_ref, owner)

  @doc "Returns the child agent reference associated with a live delegated run."
  @spec run_agent_ref(RunRef.t()) :: {:ok, AgentRef.t()} | {:error, term()}
  def run_agent_ref(%RunRef{} = run_ref), do: Request.agent_ref(run_ref)

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
    with {:ok, request} <- Registry.whereis(run_ref) do
      try do
        Request.cancel(request, reason)
      catch
        :exit, exit_reason -> {:error, {:request_terminated, exit_reason}}
      end
    end
  end

  def cancel(%WorkflowRef{} = workflow_ref, reason) do
    with {:ok, server} <- Registry.workflow(workflow_ref),
         do: WorkflowServer.cancel(server, reason)
  end

  @doc "Projects an outcome into a `Tackle.Lib`-style result."
  defdelegate to_lib_result(outcome), to: Outcome

  defp with_agent(%AgentRef{} = agent_ref, operation, args) do
    with {:ok, pid} <- Registry.whereis(agent_ref),
         {:ok, backend} <- backend(agent_ref) do
      try do
        backend.call(pid, operation, args)
      rescue
        exception -> {:error, {:agent_backend_failed, Exception.message(exception)}}
      catch
        :exit, reason -> {:error, {:agent_unavailable, reason}}
      end
    else
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp coordinator(ref) do
    case Registry.coordinator(ref) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> {:error, :scope_not_found}
    end
  end

  defp backend(ref) do
    case Registry.backend(ref) do
      {:ok, backend} ->
        {:ok, backend}

      {:error, :not_found} ->
        case Application.get_env(:tackle_runtime, :default_backend) do
          backend when is_atom(backend) and not is_nil(backend) -> {:ok, backend}
          _other -> {:error, :not_found}
        end
    end
  end

  defp resolve_requester(%Handle{scope_ref: scope_ref, agent_ref: agent_ref}) do
    {:ok, scope_ref, agent_ref}
  end

  defp resolve_requester(%AgentRef{} = agent_ref) do
    {:ok, Ref.scope_ref(agent_ref), agent_ref}
  end

  defp resolve_requester(other), do: {:error, {:invalid_requester, other}}

  defp request_owner(opts, parent_ref) do
    case Keyword.get(opts, :owner, :requester) do
      :parent ->
        case Registry.whereis(parent_ref) do
          {:ok, parent} -> parent
          {:error, :not_found} -> nil
        end

      :requester ->
        self()

      other ->
        raise ArgumentError, "invalid request owner: #{inspect(other)}"
    end
  end

  defp resolve_spec(_coordinator, %AgentSpec{} = spec), do: AgentSpec.new(spec)

  defp resolve_spec(coordinator, name) when is_binary(name) do
    Coordinator.resolve_profile(coordinator, name)
  end

  defp resolve_spec(_coordinator, other), do: {:error, {:invalid_agent_spec, other}}
end
