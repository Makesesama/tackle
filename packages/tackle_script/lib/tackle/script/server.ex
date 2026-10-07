defmodule Tackle.Script.Server do
  @moduledoc """
  Generic process that runs one Lua workflow script.

  The server owns the physical lifecycle: it starts one linked worker process
  that evaluates the script, arms the deadline, routes progress logs, cancels
  the worker on cancellation or timeout, and releases its registry entry when
  it stops. It is a temporary child of the scope work supervisor and is never
  restarted.

  The worker evaluates the script with the sandboxed `Lua` VM. `tackle.await/1`
  blocks the worker — not this server — so `Tackle.Script.await/2` and
  cancellation stay responsive while the script is mid-flight. Delegated runs
  are requested by the worker, so the runtime cancels them automatically when
  the worker dies; a script therefore owns every run it spawns.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Tackle.Runtime.Handle
  alias Tackle.Script
  alias Tackle.Script.Ref

  @default_linger 500
  @default_max_instructions 1_000_000

  @type arg :: %{
          required(:script_ref) => Ref.t(),
          required(:handle) => Handle.t(),
          required(:script) => String.t(),
          optional(:timeout) => timeout(),
          optional(:max_instructions) => pos_integer() | :infinity,
          optional(:log) => (String.t() -> any()) | nil
        }

  @doc false
  @spec start_link(arg()) :: GenServer.on_start()
  def start_link(%{script_ref: %Ref{}} = arg) do
    GenServer.start_link(__MODULE__, arg, name: via(arg.script_ref))
  end

  @doc false
  def child_spec(arg) do
    %{
      id: {__MODULE__, arg.script_ref.script_id},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc false
  def via(%Ref{scope_id: scope_id, script_id: script_id}) do
    {:via, Registry, {Tackle.Script.Registry, {scope_id, script_id}}}
  end

  @doc "Waits for the script's terminal result."
  @spec await(GenServer.server(), timeout()) :: term()
  def await(server, timeout \\ :infinity),
    do: GenServer.call(server, {:await, timeout}, :infinity)

  @doc "Requests cooperative cancellation of the script and its runs."
  @spec cancel(GenServer.server(), term()) :: :ok
  def cancel(server, reason \\ :cancelled), do: GenServer.cast(server, {:cancel, reason})

  @impl true
  def init(arg) do
    Process.flag(:trap_exit, true)

    state = %{
      script_ref: arg.script_ref,
      handle: arg.handle,
      script: arg.script,
      timeout: Map.get(arg, :timeout, :infinity),
      max_instructions: Map.get(arg, :max_instructions) || @default_max_instructions,
      log: Map.get(arg, :log),
      worker: nil,
      worker_monitor: nil,
      result: nil,
      awaiters: %{},
      deadline_timer: nil,
      await_timer: nil,
      linger_timer: nil
    }

    {:ok, state, {:continue, :start_worker}}
  end

  @impl true
  def handle_continue(:start_worker, state) do
    server = self()
    arg = Map.take(state, [:handle, :script, :max_instructions]) |> Map.put(:server, server)

    worker =
      spawn_link(fn ->
        send(server, {:script_finished, eval_script(arg)})
      end)

    state = %{state | worker: worker, worker_monitor: Process.monitor(worker)}
    {:noreply, arm_deadline(state)}
  end

  @impl true
  def handle_call({:await, _timeout}, _from, %{result: result} = state) when not is_nil(result) do
    {:stop, :normal, result, state}
  end

  def handle_call({:await, timeout}, from, state) do
    {:noreply, arm_await_timeout(register_awaiter(state, from, timeout), timeout)}
  end

  @impl true
  def handle_cast({:cancel, reason}, state), do: {:noreply, cancel_script(state, reason)}

  @impl true
  def handle_info({:script_finished, result}, state), do: {:noreply, settle(state, result)}

  def handle_info({:script_log, message}, state) do
    log(state, message)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{worker_monitor: monitor} = state) do
    # A result message and the worker's DOWN have no delivery-order guarantee.
    # Defer the termination decision until any in-flight result in the current
    # mailbox has been processed.
    Process.send_after(self(), {:script_worker_down, reason}, 0)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.awaiters, monitor) do
      {nil, _awaiters} ->
        {:noreply, state}

      {_from, awaiters} ->
        state = %{state | awaiters: awaiters}
        {:noreply, disarm_await_timer_if_idle(state)}
    end
  end

  def handle_info({:script_worker_down, _reason}, %{result: result} = state)
      when not is_nil(result),
      do: {:noreply, state}

  def handle_info({:script_worker_down, reason}, state),
    do: {:noreply, settle(state, {:error, {:script_worker_terminated, reason}})}

  def handle_info({:script_timeout, :deadline}, state),
    do: {:noreply, cancel_script(state, :script_timeout)}

  def handle_info({:script_timeout, :await}, state),
    do: {:noreply, settle(state, {:error, :script_timeout})}

  def handle_info({:script_timeout, :linger}, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_worker(state)
    :ok
  end

  # Worker ------------------------------------------------------------------------

  defp eval_script(arg) do
    lua_opts = [max_instructions: arg.max_instructions]

    lua =
      Lua.new(lua_opts)
      |> Lua.put_private(:tackle_script, %{handle: arg.handle, server: arg.server})
      |> Lua.load_api(Script.API)

    {results, _lua} = Lua.eval!(lua, arg.script, source: "script")
    {:ok, results}
  rescue
    e in [Lua.CompilerException] ->
      {:error, {:script_compile_error, Exception.message(e)}}

    e in [Lua.RuntimeException] ->
      {:error, %{message: Exception.message(e), line: e.line}}

    error ->
      {:error, {:script_crashed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:script_exit, reason}}
  end

  # Lifecycle ----------------------------------------------------------------------

  defp cancel_script(%{result: result} = state, _reason) when not is_nil(result), do: state

  defp cancel_script(state, reason) do
    kill_worker(state)
    settle(state, {:error, {:cancelled, reason}})
  end

  defp settle(%{result: result} = state, _result) when not is_nil(result), do: state

  defp settle(state, result) do
    state = state |> cancel_timers() |> kill_worker()

    Enum.each(state.awaiters, fn {monitor, from} ->
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, result)
    end)

    linger = Process.send_after(self(), {:script_timeout, :linger}, @default_linger)
    %{state | result: result, awaiters: %{}, linger_timer: linger}
  end

  defp kill_worker(%{worker: nil} = state), do: state

  defp kill_worker(%{worker: worker, worker_monitor: monitor} = state) do
    if is_pid(worker) and Process.alive?(worker) do
      Process.exit(worker, :kill)
    end

    if monitor, do: Process.demonitor(monitor, [:flush])
    %{state | worker: nil, worker_monitor: nil}
  end

  defp register_awaiter(state, {pid, _tag} = from, _timeout) do
    monitor = Process.monitor(pid)
    %{state | awaiters: Map.put(state.awaiters, monitor, from)}
  end

  defp disarm_await_timer_if_idle(%{awaiters: awaiters, await_timer: timer} = state)
       when map_size(awaiters) == 0 and not is_nil(timer) do
    Process.cancel_timer(timer)
    %{state | await_timer: nil}
  end

  defp disarm_await_timer_if_idle(state), do: state

  defp arm_deadline(%{deadline_timer: timer} = state) when not is_nil(timer), do: state

  defp arm_deadline(state) do
    case state.timeout do
      timeout when is_integer(timeout) and timeout > 0 ->
        timer = Process.send_after(self(), {:script_timeout, :deadline}, timeout)
        %{state | deadline_timer: timer}

      _other ->
        state
    end
  end

  defp arm_await_timeout(%{await_timer: timer} = state, _timeout) when not is_nil(timer),
    do: state

  defp arm_await_timeout(state, timeout) when is_integer(timeout) and timeout > 0 do
    timer = Process.send_after(self(), {:script_timeout, :await}, timeout)
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

  defp log(%{log: callback}, message) when is_function(callback, 1), do: callback.(message)
  defp log(_state, message), do: Logger.info("[tackle_script] #{message}")
end
