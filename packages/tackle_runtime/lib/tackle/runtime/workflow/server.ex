defmodule Tackle.Runtime.Workflow.Server do
  @moduledoc """
  Generic process that runs one host-defined workflow.

  The server owns the physical lifecycle: it starts and monitors one awaiter per
  outstanding run, routes correlated outcomes to the workflow module, cancels
  attached runs on cancellation or timeout, and releases its registry entry when
  it stops. It is a temporary child of the scope work supervisor and is never
  restarted.
  """

  use GenServer, restart: :temporary

  alias Tackle.Runtime
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.RunRef
  alias Tackle.Runtime.Workflow
  alias Tackle.Runtime.WorkflowRef

  @default_linger 500

  @type arg :: %{
          required(:workflow_ref) => WorkflowRef.t(),
          required(:module) => module(),
          required(:input) => term(),
          required(:handle) => Handle.t(),
          required(:work_supervisor) => GenServer.server(),
          optional(:timeout) => timeout()
        }

  @doc false
  @spec start_link(arg()) :: GenServer.on_start()
  def start_link(%{workflow_ref: %WorkflowRef{}} = arg) do
    GenServer.start_link(__MODULE__, arg, name: via(arg.workflow_ref))
  end

  @doc false
  def child_spec(arg) do
    %{
      id: {__MODULE__, arg.workflow_ref.workflow_id},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc false
  def via(%WorkflowRef{scope_id: scope_id, workflow_id: workflow_id}) do
    {:via, Elixir.Registry, {Registry, {:workflow, scope_id, workflow_id}}}
  end

  @doc "Waits for the workflow's terminal result."
  @spec await(GenServer.server(), timeout()) :: term()
  def await(server, timeout \\ :infinity) do
    GenServer.call(server, {:await, timeout}, :infinity)
  end

  @doc "Requests cooperative cancellation of the workflow and its attached runs."
  @spec cancel(GenServer.server(), term()) :: :ok
  def cancel(server, reason \\ :cancelled), do: GenServer.cast(server, {:cancel, reason})

  @impl true
  def init(arg) do
    Process.flag(:trap_exit, true)

    state = %{
      workflow_ref: arg.workflow_ref,
      module: arg.module,
      handle: arg.handle,
      work_supervisor: arg.work_supervisor,
      timeout: Map.get(arg, :timeout, :infinity),
      workflow_state: nil,
      requests: %{},
      awaiters: [],
      result: nil,
      cancelled: false,
      deadline_timer: nil,
      await_timer: nil,
      linger_timer: nil
    }

    {:ok, state, {:continue, {:init, arg.input}}}
  end

  @impl true
  def handle_continue({:init, input}, state) do
    case state.module.init(input) do
      {:ok, workflow_state} ->
        {:noreply, start_requests(%{state | workflow_state: workflow_state}, [])}

      {:ok, workflow_state, requests} ->
        {:noreply, start_requests(%{state | workflow_state: workflow_state}, requests)}

      {:stop, reason} ->
        {:noreply, settle(state, {:error, reason})}
    end
  end

  @impl true
  def handle_call({:await, _timeout}, _from, %{result: result} = state)
      when not is_nil(result) do
    {:stop, :normal, result, state}
  end

  def handle_call({:await, timeout}, from, state) do
    {:noreply, arm_await_timeout(%{state | awaiters: [from | state.awaiters]}, timeout)}
  end

  def handle_call({:workflow_run_result, %RunRef{} = run_ref, %Outcome{} = outcome}, _from, state) do
    {:reply, :ok, handle_run_result(state, run_ref, outcome)}
  end

  @impl true
  def handle_cast({:cancel, reason}, state), do: {:noreply, cancel_workflow(state, reason)}

  @impl true
  def handle_info({:workflow_run_result, %RunRef{} = run_ref, %Outcome{} = outcome}, state) do
    {:noreply, handle_run_result(state, run_ref, outcome)}
  end

  def handle_info({:runtime_cancel, reason}, state),
    do: {:noreply, cancel_workflow(state, reason)}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case find_request(state, monitor) do
      nil ->
        {:noreply, state}

      {run_id, _entry} ->
        # A result message and the awaiter's DOWN have no delivery-order
        # guarantee. Defer the failure decision until after any in-flight
        # result in the current mailbox has been processed.
        Process.send_after(self(), {:workflow_awaiter_down, run_id, reason}, 0)
        {:noreply, state}
    end
  end

  def handle_info({:workflow_awaiter_down, run_id, reason}, state) do
    case Map.pop(state.requests, run_id) do
      {nil, _requests} ->
        {:noreply, state}

      {entry, requests} ->
        outcome =
          Outcome.new(:runtime_error,
            reason: {:workflow_awaiter_terminated, reason},
            agent_ref: entry.run_ref.agent_ref
          )

        {:noreply, dispatch(%{state | requests: requests}, entry.run_ref, outcome)}
    end
  end

  def handle_info({:workflow_timeout, :deadline}, state),
    do: {:noreply, settle(state, {:error, :workflow_timeout})}

  def handle_info({:workflow_timeout, :await}, state),
    do: {:noreply, settle(state, {:error, :workflow_timeout})}

  def handle_info({:workflow_timeout, :linger}, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, _pid, reason}, state) do
    if state.result, do: {:noreply, state}, else: {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_requests(state, :workflow_terminated)
    :ok
  end

  defp handle_run_result(state, run_ref, outcome) do
    case Map.pop(state.requests, run_ref.run_id) do
      {nil, _requests} ->
        state

      {entry, requests} ->
        Process.demonitor(entry.monitor, [:flush])
        dispatch(%{state | requests: requests}, run_ref, outcome)
    end
  end

  defp start_requests(state, requests) do
    case launch_all(state, requests) do
      {:ok, state} -> arm_deadline(state)
      {:error, reason} -> settle(state, {:error, {:request_failed, reason}})
    end
  end

  defp launch_all(state, requests) do
    Enum.reduce_while(requests, {:ok, state}, fn request, {:ok, acc} ->
      case launch(acc, request) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp launch(state, request) do
    {profile, prompt, opts} = Workflow.normalize_request(request)

    case Runtime.request_agent(state.handle, profile, prompt, opts) do
      {:ok, run_ref} -> start_awaiter(state, run_ref)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_awaiter(state, %RunRef{} = run_ref) do
    server = self()

    spec =
      {Task,
       fn ->
         # Call (not send) so the server has stored the outcome before the
         # awaiter exits; this removes the DOWN-versus-result race.
         result = normalize_result(run_ref, Runtime.await(run_ref, :infinity))
         :ok = GenServer.call(server, {:workflow_run_result, run_ref, result}, :infinity)
       end}

    case DynamicSupervisor.start_child(state.work_supervisor, spec) do
      {:ok, pid} ->
        entry = %{run_ref: run_ref, awaiter: pid, monitor: Process.monitor(pid)}
        {:ok, %{state | requests: Map.put(state.requests, run_ref.run_id, entry)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_result(_run_ref, %Outcome{} = outcome), do: outcome

  defp normalize_result(run_ref, {:error, reason}) do
    Outcome.new(:runtime_error, reason: {:await_failed, reason}, agent_ref: run_ref.agent_ref)
  end

  defp normalize_result(run_ref, other) do
    Outcome.new(:runtime_error, reason: {:unexpected_result, other}, agent_ref: run_ref.agent_ref)
  end

  defp dispatch(state, run_ref, %Outcome{} = outcome) do
    callback = if outcome.status == :ok, do: :handle_result, else: :handle_failure

    case apply(state.module, callback, [run_ref, outcome, state.workflow_state]) do
      {:ok, workflow_state} ->
        arm_deadline(%{state | workflow_state: workflow_state})

      {:ok, workflow_state, requests} ->
        start_requests(%{state | workflow_state: workflow_state}, requests)

      {:stop, result, workflow_state} ->
        settle(%{state | workflow_state: workflow_state}, result)
    end
  end

  defp cancel_workflow(%{result: result} = state, _reason) when not is_nil(result), do: state

  defp cancel_workflow(state, reason) do
    state = cancel_requests(%{state | cancelled: true}, reason)
    {:stop, result, workflow_state} = state.module.handle_cancelled(reason, state.workflow_state)
    settle(%{state | workflow_state: workflow_state}, result)
  end

  defp settle(%{result: result} = state, _result) when not is_nil(result), do: state

  defp settle(state, result) do
    state = state |> cancel_timers() |> cancel_requests(:settled)
    Enum.each(state.awaiters, &GenServer.reply(&1, result))
    linger = Process.send_after(self(), {:workflow_timeout, :linger}, @default_linger)
    %{state | result: result, awaiters: [], linger_timer: linger}
  end

  defp cancel_requests(state, reason) do
    Enum.each(state.requests, fn {_run_id, entry} ->
      Runtime.cancel(entry.run_ref, reason)

      if is_pid(entry.awaiter) and Process.alive?(entry.awaiter) do
        Process.exit(entry.awaiter, :kill)
      end
    end)

    Enum.each(state.requests, fn {_run_id, entry} ->
      Process.demonitor(entry.monitor, [:flush])
    end)

    %{state | requests: %{}}
  end

  defp find_request(state, monitor) do
    Enum.find(state.requests, fn {_run_id, entry} -> entry.monitor == monitor end)
  end

  defp arm_deadline(%{deadline_timer: timer} = state) when not is_nil(timer), do: state

  defp arm_deadline(state) do
    case state.timeout do
      timeout when is_integer(timeout) and timeout > 0 ->
        timer = Process.send_after(self(), {:workflow_timeout, :deadline}, timeout)
        %{state | deadline_timer: timer}

      _other ->
        state
    end
  end

  defp arm_await_timeout(%{await_timer: timer} = state, _timeout) when not is_nil(timer),
    do: state

  defp arm_await_timeout(state, timeout) when is_integer(timeout) and timeout > 0 do
    timer = Process.send_after(self(), {:workflow_timeout, :await}, timeout)
    %{state | await_timer: timer}
  end

  defp arm_await_timeout(state, _timeout), do: state

  defp cancel_timers(state) do
    Enum.each([state.deadline_timer, state.await_timer], fn
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end)

    %{state | deadline_timer: nil, await_timer: nil}
  end
end
