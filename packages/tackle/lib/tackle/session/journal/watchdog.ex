defmodule Tackle.Session.Journal.Watchdog do
  @moduledoc false

  use GenServer
  require Logger

  alias Tackle.Session.Storage

  @registry Tackle.Session.JournalRegistry
  @default_timeout 15_000
  @report_timeout 2_000

  def start(owner, session_id, opts) do
    # Do not make the owner our OTP parent: its EXIT would terminate this
    # GenServer before we can deliver failure replies or finish the report.
    # The bidirectional monitors below provide the required fail-stop lifetime.
    GenServer.start(__MODULE__, {owner, session_id, opts}, name: via(owner))
  end

  def request(owner, message) do
    GenServer.call(via(owner), {:request, message}, :infinity)
  catch
    :exit, {reason, _call} -> stop_owner(owner, reason)
    :exit, reason -> stop_owner(owner, reason)
  end

  defp stop_owner(owner, reason) do
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)

    receive do
      {:DOWN, ^ref, :process, ^owner, _reason} ->
        {:error, {:journal_unavailable, reason}}
    end
  end

  def stage(owner, stage, seq \\ nil),
    do: GenServer.cast(via(owner), {:stage, stage, seq})

  def ready(owner), do: GenServer.cast(via(owner), :ready)
  def cleanup(owner), do: GenServer.cast(via(owner), :cleanup)
  def lock(owner, lock), do: GenServer.cast(via(owner), {:lock, lock})

  defp via(owner), do: {:via, Registry, {@registry, {:journal_watchdog, owner}}}

  @impl true
  def init({owner, session_id, opts}) do
    Process.flag(:trap_exit, true)
    timeout = Keyword.get(opts, :journal_timeout, @default_timeout)

    if is_integer(timeout) and timeout > 0 do
      owner_ref = Process.monitor(owner)
      watchdog = self()

      # A crashing watchdog must also stop an owner blocked outside its mailbox.
      # Linking alone is insufficient because the journal traps exits.
      {_guard, guard_ref} = spawn_monitor(fn -> guard(owner, watchdog) end)
      token = make_ref()
      timer = Process.send_after(self(), {:expired, token}, timeout)

      {:ok,
       %{
         owner: owner,
         owner_ref: owner_ref,
         guard_ref: guard_ref,
         session_id: session_id,
         opts: opts,
         timeout: timeout,
         stage: :initializing,
         seq: nil,
         lifecycle: {token, timer, System.monotonic_time(:millisecond)},
         pending: %{},
         failure: nil,
         owner_down?: false,
         reporter: nil,
         lock: nil
       }}
    else
      {:stop, {:invalid_journal_timeout, timeout}}
    end
  end

  @impl true
  def handle_call({:request, _message}, from, %{failure: failure} = state)
      when not is_nil(failure) do
    if state.owner_down? do
      {:reply, {:error, failure}, state}
    else
      pending = %{from: from, timer: nil}
      {:noreply, %{state | pending: Map.put(state.pending, make_ref(), pending)}}
    end
  end

  def handle_call({:request, message}, from, state) do
    request = :gen_server.send_request(state.owner, message)
    stage = if map_size(state.pending) == 0, do: :queued, else: state.stage
    token = make_ref()
    timer = Process.send_after(self(), {:expired, token}, state.timeout)

    pending = %{
      from: from,
      token: token,
      timer: timer,
      started_at: System.monotonic_time(:millisecond),
      operation: operation(message)
    }

    {:noreply, %{state | pending: Map.put(state.pending, request, pending), stage: stage}}
  end

  @impl true
  def handle_cast({:stage, stage, seq}, state),
    do: {:noreply, %{state | stage: stage, seq: seq || state.seq}}

  def handle_cast({:lock, lock}, state), do: {:noreply, %{state | lock: lock}}

  def handle_cast(:ready, state) do
    cancel_lifecycle(state.lifecycle)
    {:noreply, %{state | lifecycle: nil, stage: :idle}}
  end

  def handle_cast(:cleanup, state) do
    cancel_lifecycle(state.lifecycle)
    token = make_ref()
    timer = Process.send_after(self(), {:expired, token}, state.timeout)

    {:noreply,
     %{state | stage: :cleanup, lifecycle: {token, timer, System.monotonic_time(:millisecond)}}}
  end

  @impl true
  def handle_info({:expired, token}, %{failure: nil} = state) do
    case expired_operation(state, token) do
      nil -> {:noreply, state}
      {operation, started_at} -> stall(state, operation, started_at)
    end
  end

  def handle_info({:expired, _token}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner_ref: ref} = state) do
    failure = state.failure || {:journal_unavailable, reason}
    cancel_lifecycle(state.lifecycle)

    Enum.each(state.pending, fn {_request, pending} ->
      if pending.timer, do: Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, {:error, failure})
    end)

    state = %{state | pending: %{}, owner_down?: true, failure: failure}
    state = start_reporter(state)
    finish(state)
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{reporter: {pid, ref}} = state),
    do: finish(%{state | reporter: nil})

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{guard_ref: ref} = state) do
    Process.exit(state.owner, :kill)
    {:stop, :watchdog_guard_failed, state}
  end

  def handle_info({:report_timeout, pid}, %{reporter: {pid, _ref}} = state) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:report_timeout, _pid}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Once expiry wins, suppress late successful replies and wait for owner DOWN.
  def handle_info(_message, %{failure: failure} = state) when not is_nil(failure),
    do: {:noreply, state}

  def handle_info(message, state) do
    case overdue_operation(state) do
      nil -> handle_response(message, state)
      {operation, started_at} -> stall(state, operation, started_at)
    end
  end

  defp overdue_operation(state) do
    now = System.monotonic_time(:millisecond)

    Enum.find_value(state.pending, fn {_request, pending} ->
      if now - pending.started_at >= state.timeout,
        do: {pending.operation, pending.started_at}
    end)
  end

  defp handle_response(message, state) do
    pending =
      Enum.reduce(state.pending, state.pending, fn entry, acc ->
        reply_to_request(message, entry, acc)
      end)

    stage = if map_size(pending) == 0 and is_nil(state.lifecycle), do: :idle, else: state.stage
    {:noreply, %{state | pending: pending, stage: stage}}
  end

  defp reply_to_request(message, {request, pending}, requests) do
    case :gen_server.check_response(message, request) do
      {:reply, reply} ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, reply)
        Map.delete(requests, request)

      {:error, {_reason, _server}} ->
        requests

      :no_reply ->
        requests
    end
  end

  defp stall(state, operation, started_at) do
    diagnostic = diagnostic(state, operation, started_at)
    # Killing the owner ends durable execution, not necessarily disk_log's
    # already-dispatched write. Recovery must replay; never retry here.
    Process.exit(state.owner, :kill)
    {:noreply, %{state | failure: {:journal_stalled, diagnostic}}}
  end

  defp finish(%{owner_down?: true, reporter: nil} = state), do: {:stop, :normal, state}
  defp finish(state), do: {:noreply, state}

  defp expired_operation(%{lifecycle: {token, _timer, started_at}, stage: stage}, token),
    do: {stage, started_at}

  defp expired_operation(state, token) do
    Enum.find_value(state.pending, fn {_request, pending} ->
      if pending.token == token, do: {pending.operation, pending.started_at}
    end)
  end

  defp operation(message) when is_tuple(message), do: elem(message, 0)
  defp operation(message) when is_atom(message), do: message

  defp cancel_lifecycle(nil), do: :ok
  defp cancel_lifecycle({_token, timer, _started_at}), do: Process.cancel_timer(timer)

  defp diagnostic(state, operation, started_at) do
    info = Process.info(state.owner, [:current_stacktrace, :status, :message_queue_len]) || []

    %{
      "session_id" => state.session_id,
      "operation" => to_string(operation),
      "stage" => to_string(state.stage),
      "sequence" => state.seq,
      "elapsed_ms" => System.monotonic_time(:millisecond) - started_at,
      "deadline_ms" => state.timeout,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "commit_outcome" => "unknown; replay required",
      "process_status" => to_string(info[:status] || :dead),
      "message_queue_len" => info[:message_queue_len],
      "stacktrace" => Enum.map(Enum.take(info[:current_stacktrace] || [], 32), &stack_frame/1)
    }
  end

  # Do not serialize arguments, dictionaries, mailboxes, or conversation data.
  defp stack_frame({module, function, arity, location}) do
    %{
      "module" => to_string(module),
      "function" => to_string(function),
      "arity" => if(is_integer(arity), do: arity, else: length(arity)),
      "line" => location[:line]
    }
  end

  defp start_reporter(state) do
    fallback? = match?(%Storage.Lock{port: nil}, state.lock)

    if match?({:journal_stalled, _}, state.failure) or fallback? do
      reporter = spawn_monitor(fn -> report_and_release(state) end)

      {reporter_pid, _ref} = reporter
      Process.send_after(self(), {:report_timeout, reporter_pid}, @report_timeout)
      %{state | reporter: reporter}
    else
      state
    end
  end

  defp report_and_release(state) do
    case state.failure do
      {:journal_stalled, diagnostic} -> report(state, diagnostic)
      _other -> :ok
    end

    release_fallback_lock(state)
  end

  defp release_fallback_lock(%{lock: %Storage.Lock{port: nil}} = state) do
    # Close waits for dispatched backend work. Never release ownership
    # while the disk_log could still be writing after journal death.
    case :disk_log.close({:tackle_session, state.session_id}) do
      :ok -> Storage.release_lock(state.lock)
      {:error, :no_such_log} -> Storage.release_lock(state.lock)
      _error -> :ok
    end
  end

  defp release_fallback_lock(_state), do: :ok

  defp report(state, diagnostic) do
    Logger.error("Session journal stalled: #{JSON.encode!(diagnostic)}")

    with {:ok, path} <- Storage.journal_path(state.session_id, state.opts) do
      path = Path.join(Path.dirname(path), "journal-failure.json")

      case Storage.atomic_write(path, JSON.encode!(diagnostic)) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Could not save journal diagnostic: #{inspect(reason)}")
      end
    end
  end

  defp guard(owner, watchdog) do
    owner_ref = Process.monitor(owner)
    watchdog_ref = Process.monitor(watchdog)

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        # Stay alive until the watcher has processed owner DOWN as well.
        receive do
          {:DOWN, ^watchdog_ref, :process, ^watchdog, _reason} -> :ok
        end

      {:DOWN, ^watchdog_ref, :process, ^watchdog, _reason} ->
        Process.exit(owner, :kill)
    end
  end
end
