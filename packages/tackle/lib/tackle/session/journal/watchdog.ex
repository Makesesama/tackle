defmodule Tackle.Session.Journal.Watchdog do
  @moduledoc false

  use GenServer
  require Logger

  alias Tackle.Session.Reader
  alias Tackle.Session.Storage
  alias Tackle.StatusRedaction

  @registry Tackle.Session.JournalRegistry
  @default_timeout 15_000
  @report_timeout 2_000
  @max_queued_requests 64
  @max_queued_bytes 24 * 1024 * 1024

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

  def subscribe(owner, subscriber),
    do: GenServer.call(via(owner), {:subscribe, subscriber})

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

  @doc "The deadline of each durable request and of the owner's cleanup, in milliseconds."
  def timeout(opts), do: Keyword.get(opts, :journal_timeout, @default_timeout)

  defp via(owner), do: {:via, Registry, {@registry, {:journal_watchdog, owner}}}

  @impl true
  def init({owner, session_id, opts}) do
    Process.flag(:trap_exit, true)
    timeout = timeout(opts)

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
         cleanup_context: nil,
         pending: %{},
         queued: :queue.new(),
         queued_bytes: 0,
         subscribers: %{},
         delayed?: false,
         failure: nil,
         owner_down?: false,
         reporters: %{},
         lock: nil,
         lock_ref: nil
       }}
    else
      {:stop, {:invalid_journal_timeout, timeout}}
    end
  end

  # Queued requests carry their payloads (messages, tool calls) and the options
  # may carry the environment; crash reports and `:sys.get_status/1` show only
  # the operations and option keys.
  @impl true
  def format_status(status), do: StatusRedaction.format_status(status, &redact_state/1)

  defp redact_state(%{queued: queued, opts: opts} = state) do
    queued =
      Enum.map(:queue.to_list(queued), fn {message, _from, _bytes} -> operation(message) end)

    %{state | queued: queued, opts: StatusRedaction.keys(opts)}
  end

  defp redact_state(state), do: state

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    subscribers =
      if Map.has_key?(state.subscribers, subscriber),
        do: state.subscribers,
        else: Map.put(state.subscribers, subscriber, Process.monitor(subscriber))

    {:reply, storage_status(state), %{state | subscribers: subscribers}}
  end

  def handle_call({:request, _message}, _from, %{failure: failure} = state)
      when not is_nil(failure),
      do: {:reply, {:error, failure}, state}

  def handle_call({:request, message}, from, state) do
    cond do
      map_size(state.pending) == 0 ->
        {:noreply, dispatch(state, message, from)}

      :queue.len(state.queued) < @max_queued_requests ->
        # Only the dispatched request has a deadline. Queued requests may not
        # append or begin effects until its durability is acknowledged.
        bytes = :erlang.external_size(message)

        if state.queued_bytes + bytes <= @max_queued_bytes do
          {:noreply,
           %{
             state
             | queued: :queue.in({message, from, bytes}, state.queued),
               queued_bytes: state.queued_bytes + bytes
           }}
        else
          {:reply, {:error, :journal_busy}, state}
        end

      true ->
        {:reply, {:error, :journal_busy}, state}
    end
  end

  defp dispatch(state, message, from) do
    request = :gen_server.send_request(state.owner, message)
    token = make_ref()
    timer = Process.send_after(self(), {:expired, token}, state.timeout)

    pending = %{
      from: from,
      token: token,
      timer: timer,
      started_at: System.monotonic_time(:millisecond),
      operation: operation(message)
    }

    %{state | pending: %{request => pending}, stage: :queued}
  end

  @impl true
  def handle_cast({:stage, stage, seq}, state) do
    # Once sync returns, guard projection/catalog work with a fresh hard
    # deadline. A storage pause must not mask a subsequent non-sync stall.
    state =
      if state.delayed? and state.stage == :sync and stage != :sync do
        pending =
          Map.new(state.pending, fn {request, pending} ->
            token = make_ref()
            timer = Process.send_after(self(), {:expired, token}, state.timeout)

            {request,
             %{
               pending
               | token: token,
                 timer: timer,
                 started_at: System.monotonic_time(:millisecond)
             }}
          end)

        %{state | pending: pending}
      else
        state
      end

    {:noreply, %{state | stage: stage, seq: seq || state.seq}}
  end

  def handle_cast({:lock, lock}, state) do
    if state.lock_ref, do: Process.demonitor(state.lock_ref, [:flush])
    ref = if lock && is_port(lock.port), do: :erlang.monitor(:port, lock.port)
    {:noreply, %{state | lock: lock, lock_ref: ref}}
  end

  def handle_cast(:ready, state) do
    cancel_lifecycle(state.lifecycle)
    {:noreply, %{state | lifecycle: nil, stage: :idle}}
  end

  def handle_cast(:cleanup, state) do
    cancel_lifecycle(state.lifecycle)
    token = make_ref()
    timer = Process.send_after(self(), {:expired, token}, state.timeout)

    {:noreply,
     %{
       state
       | stage: :cleanup,
         cleanup_context: %{stage: state.stage, seq: state.seq},
         lifecycle: {token, timer, System.monotonic_time(:millisecond)}
     }}
  end

  @impl true
  def handle_info({:expired, token}, %{failure: nil} = state) do
    case expired_operation(state, token) do
      nil -> {:noreply, state}
      {operation, started_at} -> expire(state, operation, started_at)
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

    Enum.each(:queue.to_list(state.queued), fn {_message, from, _bytes} ->
      GenServer.reply(from, {:error, failure})
    end)

    diagnostic =
      case state.failure do
        {:journal_stalled, diagnostic} -> diagnostic
        _other -> failure_diagnostic(state, state.failure || reason)
      end

    state = %{
      state
      | pending: %{},
        queued: :queue.new(),
        queued_bytes: 0,
        owner_down?: true,
        failure: failure
    }

    state = start_reporters(state, diagnostic)
    finish(state)
  end

  def handle_info({:DOWN, ref, :port, _port, reason}, %{lock_ref: ref} = state) do
    if is_nil(state.lifecycle) and is_nil(state.failure) do
      # The journal traps port exits and cannot process them during sync.
      # Lost exclusive ownership is fatal even while storage is delayed.
      Process.exit(state.owner, :kill)

      {:noreply,
       %{state | failure: {:journal_failure, {:writer_lock_lost, reason}}, lock_ref: nil}}
    else
      {:noreply, %{state | lock_ref: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{guard_ref: ref} = state) do
    Process.exit(state.owner, :kill)
    {:stop, :watchdog_guard_failed, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{reporters: reporters} = state)
      when is_map_key(reporters, ref) do
    finish(%{state | reporters: Map.delete(reporters, ref)})
  end

  def handle_info({:report_timeout, pid}, state) do
    if pid in Map.values(state.reporters), do: Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Once expiry wins, suppress late successful replies and wait for owner DOWN.
  def handle_info(_message, %{failure: failure} = state) when not is_nil(failure),
    do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _reason} = message, state) do
    if state.subscribers[pid] == ref,
      do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}},
      else: handle_request_message(message, state)
  end

  def handle_info(message, state), do: handle_request_message(message, state)

  defp handle_request_message(message, state) do
    # Consume a completed reply before evaluating deadlines. A reply already
    # in the mailbox establishes the outcome; it must not become 'unknown'.
    {next, completed?} = consume_response(message, state)

    if completed? do
      {:noreply, next}
    else
      case overdue_operation(state) do
        nil -> {:noreply, state}
        {operation, started_at} -> expire(state, operation, started_at)
      end
    end
  end

  defp overdue_operation(state) do
    now = System.monotonic_time(:millisecond)

    Enum.find_value(state.pending, fn {_request, pending} ->
      if pending.timer && now - pending.started_at >= state.timeout,
        do: {pending.operation, pending.started_at}
    end)
  end

  defp consume_response(message, state) do
    Enum.reduce(state.pending, {state, false}, fn {request, pending}, {state, _completed?} ->
      case :gen_server.check_response(message, request) do
        {:reply, reply} ->
          {complete_request(state, pending, reply), true}

        _no_response ->
          {state, false}
      end
    end)
  end

  defp complete_request(state, pending, reply) do
    if pending.timer, do: Process.cancel_timer(pending.timer)
    state = set_delayed(state, false)
    GenServer.reply(pending.from, reply)
    dispatch_next(%{state | pending: %{}})
  end

  defp dispatch_next(state) do
    case :queue.out(state.queued) do
      {{:value, {message, from, bytes}}, queued} ->
        dispatch(
          %{state | queued: queued, queued_bytes: state.queued_bytes - bytes},
          message,
          from
        )

      {:empty, _queue} ->
        %{state | stage: :idle}
    end
  end

  defp expire(%{stage: :sync, lifecycle: nil} = state, _operation, _started_at) do
    pending =
      Map.new(state.pending, fn {request, pending} ->
        if pending.timer, do: Process.cancel_timer(pending.timer)
        {request, %{pending | timer: nil, token: nil}}
      end)

    # Leave the original sync in flight: no append retry, no second sync.
    {:noreply, set_delayed(%{state | pending: pending}, true)}
  end

  defp expire(state, operation, started_at), do: stall(state, operation, started_at)

  defp storage_status(%{delayed?: true}), do: :delayed
  defp storage_status(_state), do: :ready

  defp set_delayed(%{delayed?: delayed?} = state, delayed?), do: state

  defp set_delayed(state, delayed?) do
    state = %{state | delayed?: delayed?}

    Enum.each(state.subscribers, fn {subscriber, _ref} ->
      send(subscriber, {:tackle_storage, state.session_id, storage_status(state)})
    end)

    state
  end

  defp stall(state, operation, started_at) do
    diagnostic = diagnostic(state, operation, started_at)
    # Killing the owner ends durable execution, not necessarily disk_log's
    # already-dispatched write. Recovery must replay; never retry here.
    Process.exit(state.owner, :kill)
    {:noreply, %{state | failure: {:journal_stalled, diagnostic}}}
  end

  defp finish(%{owner_down?: true, reporters: reporters} = state) when map_size(reporters) == 0,
    do: {:stop, :normal, state}

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

  # Supervisor teardown replaces the journal's real exit reason with :shutdown
  # for its sibling Session. Preserve payload-free evidence outside that tree,
  # even when the terminal has muted the console logger.
  defp failure_diagnostic(_state, reason) when reason in [:normal, :shutdown], do: nil
  defp failure_diagnostic(_state, {:shutdown, _reason}), do: nil

  defp failure_diagnostic(state, reason) do
    context = state.cleanup_context || %{stage: state.stage, seq: state.seq}

    %{
      "session_id" => state.session_id,
      "operation" => "owner_exit",
      "failure" => failure_kind(reason),
      "stage" => to_string(context.stage),
      "sequence" => context.seq,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "commit_outcome" => "unknown; replay required"
    }
  end

  # Never inspect arbitrary exit reasons: exceptions may embed prompts, tool
  # arguments, or provider responses. Only report recognized failure tags.
  defp failure_kind({:journal_failure, reason}), do: "journal_failure/" <> failure_tag(reason)
  defp failure_kind(reason), do: failure_tag(reason)

  defp failure_tag({tag, _detail})
       when tag in [
              :writer_lock_lost,
              :invalid_commit,
              :journal_sync_failed,
              :journal_append_failed,
              :error_status
            ],
       do: Atom.to_string(tag)

  defp failure_tag(reason)
       when reason in [:killed, :disk_full, :truncated, :unexpected_wrap, :read_only],
       do: Atom.to_string(reason)

  defp failure_tag(_reason), do: "unexpected_owner_exit"

  defp start_reporters(state, diagnostic) do
    # Reporting must not consume the fallback cleanup budget: a blocked logger
    # or diagnostic write cannot prevent closing the backend and releasing its
    # lock. Each operation has its own independent deadline.
    next =
      if match?(%Storage.Lock{port: nil}, state.lock),
        do: start_reporter(state, fn -> release_fallback_lock(state) end),
        else: state

    if diagnostic, do: start_reporter(next, fn -> report(state, diagnostic) end), else: next
  end

  defp start_reporter(state, fun) do
    {pid, ref} = spawn_monitor(fun)
    Process.send_after(self(), {:report_timeout, pid}, @report_timeout)
    %{state | reporters: Map.put(state.reporters, ref, pid)}
  end

  defp release_fallback_lock(%{lock: %Storage.Lock{port: nil}} = state) do
    # Close waits for dispatched backend work. Never release ownership
    # while the disk_log could still be writing after journal death.
    case Reader.close(Reader.name(state.session_id)) do
      :ok -> Storage.release_lock(state.lock)
      {:error, :no_such_log} -> Storage.release_lock(state.lock)
      _error -> :ok
    end
  end

  defp report(state, diagnostic) do
    Logger.error("Session journal failed: #{JSON.encode!(diagnostic)}")

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
