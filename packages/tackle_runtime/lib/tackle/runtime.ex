defmodule Tackle.Runtime do
  @moduledoc """
  Public runtime API for root-agent scopes, delegated agents, and cancellation.

  The runtime is a reusable orchestration layer above `Tackle.Lib`. It
  addresses everything by stable references (`Tackle.Runtime.ScopeRef`,
  `AgentRef`, `RunRef`) and never requires callers to hold PIDs. Concrete agent
  lifecycle and host policy are supplied through `Tackle.Runtime.AgentBackend`.

  A scope is one root agent plus every descendant it creates and forms the
  runtime's physical cleanup and logical ownership boundary.
  """

  alias Tackle.AgentScope.Coordinator
  alias Tackle.AgentSupervisor
  alias Tackle.Runtime.AgentBackend
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Messaging
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Ref
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.Request
  alias Tackle.Runtime.RunRef
  alias Tackle.Runtime.Scope
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec

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
      {:ok, Coordinator.snapshot(coordinator)}
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

  @doc "Withdraws the newest matching queued user message, if it has not been consumed."
  @spec withdraw_queued(AgentRef.t(), String.t()) :: :ok | {:error, term()}
  def withdraw_queued(%AgentRef{} = agent_ref, content),
    do: with_agent(agent_ref, :withdraw_queued, [content])

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
  Requests cancellation of one tool call in an agent's active turn.

  Only that call is stopped: its tool observes `reason` through its per-call
  cancellation signal (see `Tackle.Lib.Cancellation.for_call/2`) and reports a
  tool error, while the turn continues. Backends without per-call cancellation
  return `{:error, {:unsupported_agent_operation, :cancel_tool_call}}`.
  """
  @spec cancel_tool_call(AgentRef.t(), String.t(), term()) :: :ok | {:error, term()}
  def cancel_tool_call(%AgentRef{} = agent_ref, tool_call_id, reason)
      when is_binary(tool_call_id) and tool_call_id != "" do
    with_agent(agent_ref, :cancel_tool_call, [tool_call_id, reason])
  end

  def cancel_tool_call(%AgentRef{}, tool_call_id, _reason),
    do: {:error, {:invalid_tool_call_id, tool_call_id}}

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

  @doc "Delivers text to an in-scope agent's bounded inbox (at the next provider boundary when busy)."
  @spec tell(AgentRef.t(), AgentRef.t(), String.t()) :: :ok | {:error, term()}
  def tell(%AgentRef{} = from, %AgentRef{} = to, message) when is_binary(message) do
    cond do
      from.scope_id != to.scope_id ->
        {:error, :scope_mismatch}

      message == "" ->
        {:error, :empty_message}

      true ->
        with {:ok, envelope} <- Envelope.new(:message, from, message) do
          Messaging.deliver(to, envelope)
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
  Requests one delegated run from an agent request source.

  `spec_or_profile` is either an allowlisted profile name (the model-visible
  form) or a trusted `AgentSpec`. The coordinator admits the child, a request
  helper installs correlated terminal routing, and a fresh ephemeral agent runs
  the delegated prompt. Returns a stable `RunRef` for `await/2`.

  `:timeout` overrides the inactivity window, renewed on each child event
  except auxiliary ones (`data.auxiliary == true`); it does not cap total run
  duration. Without an override, the window comes from
  the agent spec, bounded by the scope's `run_timeout`. Explicit `await/2`
  timeouts still bound the caller's total wait.

  A trusted spec with `model_source: :parent` copies only the requesting agent's
  model reference and thinking level at request time, resolving against the
  child's configured adapters before admission. Resolution runs outside the
  coordinator to avoid calling an agent from inside its admission owner.
  The model is captured after parent-inheritance resolution and included in the
  returned run reference, so callers can display the actual child selection
  without racing its ephemeral session. Existing runs and profiles with
  `model_source: :configured` are unchanged.

  `:model` optionally overrides the child's model for this one run with a
  non-empty model reference such as `"provider/model"`. It is applied after
  parent inheritance through the backend's `select_model/2` callback, which
  resolves it against the child's trusted configuration; the profile's other
  settings, including its thinking level, are kept. An unavailable model, or a
  backend without `select_model/2`, fails the request before admission.
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
    with {:ok, model} <- requested_model(opts),
         {:ok, scope_ref, parent_ref} <- resolve_requester(requester),
         {:ok, coordinator} <- coordinator(scope_ref),
         {:ok, backend} <- Registry.backend(scope_ref),
         {:ok, spec} <- resolve_spec(coordinator, spec_or_profile),
         {:ok, parent_pid} <- Registry.whereis(parent_ref),
         {:ok, spec} <- AgentBackend.prepare_child(backend, spec, parent_pid),
         {:ok, spec} <- AgentBackend.select_model(backend, spec, model),
         {:ok, work_supervisor} <- Registry.work_supervisor(scope_ref) do
      requester = request_owner(opts, parent_ref)

      run_ref =
        RunRef.new!(scope_ref.scope_id, ID.generate(), nil, AgentBackend.model_ref(backend, spec))

      request_opts = %{
        timeout: Keyword.fetch(opts, :timeout),
        event_callback: Keyword.get(opts, :event_callback),
        completion_message: Keyword.get(opts, :completion_message),
        launch_message: Keyword.get(opts, :launch_message),
        origin: Keyword.get(opts, :origin),
        retention: Keyword.get(opts, :retention, :linger)
      }

      with {:ok, admission} <-
             Coordinator.admit_agent(coordinator, parent_ref, spec, lifetime: :ephemeral) do
        run_ref = %{run_ref | agent_ref: admission.agent_ref}

        timeout =
          case request_opts.timeout do
            {:ok, value} -> value
            :error -> AgentSpec.timeout(spec, admission.limits)
          end

        arg = %{
          scope_ref: scope_ref,
          agent_ref: admission.agent_ref,
          run_ref: run_ref,
          requester: requester,
          backend: backend,
          agent_spec: spec,
          prompt: prompt,
          work_supervisor: work_supervisor,
          coordinator: coordinator,
          allow_delegation: admission.allow_delegation,
          limits: admission.limits,
          parent: %{agent_ref: parent_ref},
          timeout: timeout,
          event_callback: request_opts.event_callback,
          completion_message: request_opts.completion_message,
          launch_message: request_opts.launch_message,
          origin: request_opts.origin,
          profile: spec.name,
          retention: request_opts.retention
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

  @doc """
  Cancels a delegated run only when it belongs to `owner`.

  Returns `{:ok, :cancelling}` once cooperative cancellation of a running run
  was requested; use `await/3` to observe its terminal outcome. A run that had
  already completed is consumed and returned as `{:ok, {:completed, outcome}}`.
  Owner-requested cancellation does not deliver a completion message to the
  owner. See `Tackle.Runtime.Request.cancel_owned/3`.
  """
  @spec cancel_run(AgentRef.t(), RunRef.t(), term()) ::
          {:ok, :cancelling | {:completed, Outcome.t()}} | {:error, term()}
  def cancel_run(%AgentRef{} = owner, %RunRef{} = run_ref, reason \\ :cancelled) do
    Request.cancel_owned(run_ref, owner, reason)
  end

  @doc "Returns the child agent reference associated with a live delegated run."
  @spec run_agent_ref(RunRef.t()) :: {:ok, AgentRef.t()} | {:error, term()}
  def run_agent_ref(%RunRef{} = run_ref), do: Request.agent_ref(run_ref)

  @doc """
  Starts one trusted work child under the scope work supervisor.

  The child is placed under the scope's work supervisor so scope teardown
  stops it with the rest of the scope's work, but it is not admitted as an
  agent and receives no runtime accounting. Hosts build their own stable
  references, await, and cancellation policy on top of it; script runners are
  one example. Returns the supervisor's child start result including the PID.
  """
  @spec start_work(Handle.t() | AgentRef.t(), Supervisor.child_spec() | {module(), term()}) ::
          DynamicSupervisor.on_start_child()
  def start_work(parent, child) do
    with {:ok, scope_ref, _parent_ref} <- resolve_requester(parent),
         {:ok, work_supervisor} <- Registry.work_supervisor(scope_ref) do
      DynamicSupervisor.start_child(work_supervisor, child)
    end
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

  @doc "Projects an outcome into a `Tackle.Lib`-style result."
  defdelegate to_lib_result(outcome), to: Outcome

  defp with_agent(%AgentRef{} = agent_ref, operation, args) do
    with {:ok, pid} <- Registry.whereis(agent_ref),
         {:ok, backend} <- backend(agent_ref) do
      AgentBackend.call(backend, pid, operation, args)
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

  # A model override may come from model-generated input, so it is checked here
  # and then resolved only by the backend against trusted configuration.
  defp requested_model(opts) do
    case Keyword.get(opts, :model) do
      nil -> {:ok, nil}
      model when is_binary(model) and model != "" -> {:ok, model}
      other -> {:error, {:invalid_model, other}}
    end
  end
end
