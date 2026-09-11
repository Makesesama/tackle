defmodule Tackle.Runtime.Request do
  @moduledoc """
  Request helper owning one correlated delegated run.

  The helper exists before the child session starts, so terminal routing is
  established before the child can finish. It:

  1. starts one fresh ephemeral session subtree under the scope work supervisor;
  2. installs the correlated terminal destination on that session;
  3. submits the delegated prompt;
  4. stores exactly one terminal outcome;
  5. answers `await/2` callers and cancels/cleans up on timeout.

  The helper is a temporary child of the scope work supervisor. It never
  becomes an event bus: it only carries the one correlated terminal outcome.
  """

  use GenServer, restart: :temporary

  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.RunRef
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Session
  alias Tackle.Session.Supervisor, as: SessionSupervisor

  @default_linger 5_000

  @type arg :: %{
          required(:scope_ref) => ScopeRef.t(),
          required(:agent_ref) => AgentRef.t(),
          required(:run_ref) => RunRef.t(),
          required(:config) => Tackle.Config.t(),
          required(:prompt) => String.t(),
          required(:work_supervisor) => GenServer.server(),
          optional(:coordinator) => GenServer.server() | nil,
          optional(:allow_delegation) => boolean(),
          optional(:limits) => Tackle.Runtime.Limits.t() | nil,
          optional(:parent) => map() | nil,
          optional(:timeout) => timeout(),
          optional(:linger) => timeout()
        }

  @doc false
  @spec start_link(arg()) :: GenServer.on_start()
  def start_link(%{} = arg), do: GenServer.start_link(__MODULE__, arg)

  @doc false
  def child_spec(arg) do
    %{
      id: {__MODULE__, arg.run_ref.run_id},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc "Waits for one correlated terminal outcome."
  @spec await(RunRef.t(), timeout()) :: Outcome.t() | {:error, term()}
  def await(%RunRef{} = run_ref, timeout \\ :infinity) do
    case Registry.whereis(run_ref) do
      {:ok, request} ->
        try do
          GenServer.call(request, {:await, timeout}, :infinity)
        catch
          :exit, reason -> {:error, {:request_terminated, reason}}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "Requests cancellation of the run's attached child."
  @spec cancel(GenServer.server(), term()) :: :ok
  def cancel(request, reason \\ :cancelled), do: GenServer.cast(request, {:cancel, reason})

  @impl true
  def init(%{run_ref: %RunRef{} = run_ref} = arg) do
    Process.flag(:trap_exit, true)
    {:ok, _pid} = Registry.register(run_ref, :request)

    state = %{
      run_ref: run_ref,
      agent_ref: arg.agent_ref,
      scope_ref: arg.scope_ref,
      coordinator: Map.get(arg, :coordinator),
      work_supervisor: arg.work_supervisor,
      config: arg.config,
      prompt: arg.prompt,
      requester: Map.get(arg, :requester),
      requester_monitor: nil,
      allow_delegation: Map.get(arg, :allow_delegation, false),
      limits: Map.get(arg, :limits),
      parent: Map.get(arg, :parent),
      timeout: Map.get(arg, :timeout, :infinity),
      session_pid: nil,
      session_monitor: nil,
      outcome: nil,
      awaiters: [],
      await_timer: nil,
      deadline_timer: nil,
      linger_timer: nil,
      cancelled: false
    }

    # The child session must not be started from `init/1`: the helper is itself a
    # child of the same work supervisor, so a nested start_child would deadlock
    # the supervisor. `handle_continue/2` runs after init returns.
    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    with {:ok, state} <- monitor_requester(state),
         {:ok, state} <- start_child_session(state),
         {:ok, state} <- submit_prompt(state) do
      {:noreply, arm_deadline(state, state.timeout)}
    else
      {:error, reason} ->
        outcome =
          Outcome.new(:runtime_error,
            reason: {:setup_failed, reason},
            agent_ref: state.agent_ref
          )

        {:noreply, settle(state, outcome)}
    end
  end

  @impl true
  def handle_call({:await, _timeout}, _from, %{outcome: %Outcome{} = outcome} = state) do
    {:stop, :normal, outcome, cancel_timers(state)}
  end

  def handle_call({:await, timeout}, from, state) do
    state = %{state | awaiters: [from | state.awaiters]}
    {:noreply, arm_await_timeout(state, timeout)}
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    {:noreply, cancel_child(state, reason)}
  end

  @impl true
  def handle_info({:tackle_runtime_terminal, run_id, %Outcome{} = outcome}, state) do
    if run_id == state.run_ref.run_id do
      {:noreply, settle(state, outcome)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{session_monitor: monitor} = state) do
    outcome =
      Outcome.new(:runtime_error,
        reason: {:session_terminated, reason},
        agent_ref: state.agent_ref
      )

    {:noreply, settle(state, outcome)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{requester_monitor: monitor} = state
      ) do
    {:stop, :normal, cancel_child(state, :requester_terminated)}
  end

  def handle_info({:runtime_cancel, reason}, state) do
    {:noreply, cancel_child(state, reason)}
  end

  def handle_info({:request_timeout, :deadline}, state) do
    {:noreply, settle(state, timeout_outcome(state))}
  end

  def handle_info({:request_timeout, :await}, state) do
    {:noreply, settle(state, timeout_outcome(state))}
  end

  def handle_info({:request_timeout, :linger}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    if state.outcome, do: {:noreply, state}, else: {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_child(state)
    :ok
  end

  defp monitor_requester(%{requester: nil} = state), do: {:ok, state}

  defp monitor_requester(%{requester: pid} = state) when is_pid(pid) do
    {:ok, %{state | requester_monitor: Process.monitor(pid)}}
  end

  defp start_child_session(state) do
    opts = [
      scope_ref: state.scope_ref,
      agent_ref: state.agent_ref,
      lifetime: :ephemeral,
      allow_delegation: state.allow_delegation,
      limits: state.limits,
      coordinator: state.coordinator,
      work_supervisor: state.work_supervisor,
      parent: state.parent,
      terminal: %{destination: self(), run_id: state.run_ref.run_id},
      id: {:session, state.agent_ref.agent_id}
    ]

    case DynamicSupervisor.start_child(
           state.work_supervisor,
           SessionSupervisor.child_spec({state.config, opts})
         ) do
      {:ok, supervisor} ->
        case SessionSupervisor.session_pid(supervisor) do
          pid when is_pid(pid) ->
            {:ok, %{state | session_pid: pid, session_monitor: Process.monitor(pid)}}

          nil ->
            {:error, :session_not_started}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp submit_prompt(%{session_pid: pid, prompt: prompt} = state) do
    case Session.submit(pid, prompt) do
      {:ok, _turn_id} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  defp arm_deadline(state, :infinity), do: state

  defp arm_deadline(state, timeout) when is_integer(timeout) and timeout > 0 do
    timer = Process.send_after(self(), {:request_timeout, :deadline}, timeout)
    %{state | deadline_timer: timer}
  end

  defp arm_await_timeout(state, :infinity), do: state

  defp arm_await_timeout(%{await_timer: nil} = state, timeout)
       when is_integer(timeout) and timeout > 0 do
    timer = Process.send_after(self(), {:request_timeout, :await}, timeout)
    %{state | await_timer: timer}
  end

  defp arm_await_timeout(state, _timeout), do: state

  defp settle(%{outcome: %Outcome{}} = state, _outcome), do: state

  defp settle(state, %Outcome{} = outcome) do
    state = cancel_timers(state)
    state = cancel_child(%{state | outcome: outcome}, :settled)
    Enum.each(state.awaiters, &GenServer.reply(&1, outcome))
    linger = Process.send_after(self(), {:request_timeout, :linger}, @default_linger)
    %{state | awaiters: [], linger_timer: linger}
  end

  defp timeout_outcome(state) do
    Outcome.new(:timeout, reason: :run_timeout, agent_ref: state.agent_ref)
  end

  defp cancel_child(%{session_pid: nil} = state, _reason), do: state

  defp cancel_child(%{cancelled: true} = state, _reason), do: state

  defp cancel_child(state, reason) do
    safe_session_cancel(state.session_pid, reason)
    %{state | cancelled: true}
  end

  defp stop_child(%{session_pid: nil}), do: :ok

  defp stop_child(%{session_pid: pid}) do
    safe_session_cancel(pid, :request_terminated)
    :ok
  end

  # The ephemeral child stops itself once it settles, so it can exit between the
  # aliveness check and the cancel call. Cancellation is best-effort by design.
  defp safe_session_cancel(pid, reason) do
    if is_pid(pid) and Process.alive?(pid) do
      Session.cancel(pid)
      send(pid, {:runtime_cancel, reason})
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp cancel_timers(state) do
    Enum.each([state.await_timer, state.deadline_timer], fn
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end)

    %{state | await_timer: nil, deadline_timer: nil}
  end
end
