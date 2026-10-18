defmodule Tackle.Exec.Client do
  @moduledoc """
  Host-side owner of a jailed exec-server port.

  The client starts a launcher (for example a Bubblewrap wrapper around
  `Tackle.Exec.Server`) as a port, sends `Tackle.Exec.Protocol` requests, and
  validates every frame that comes back. The exec-server runs untrusted
  commands under the same uid inside the jail, so it is treated as hostile:
  oversized frames, compressed or malformed terms, unexpected replies, invalid
  results, and output beyond the granted credit are protocol violations. A
  violation stops the client, fails every pending request, and kills the
  launcher process.

  The client never blocks on the port. Requests that the jail does not read
  are queued up to a bound, and further requests fail with `:busy`.

  The launcher starts with an environment that keeps only the variables named
  in `:keep_env`. Its standard error is inherited from the host VM, so
  launchers must redirect it (for example to a log file) so jailed code cannot
  write to the host terminal.

  ## Commands

  `exec/3` starts a command and returns a reference. Output is delivered to the
  calling process as messages:

      {:tackle_exec, ref, {:data, binary}}
      {:tackle_exec, ref, {:exit_status, 0..255}}
      {:tackle_exec, ref, {:error, reason}}

  The reference is also a monitor of the client, so if the client exits
  abruptly the stream ends with `{:DOWN, ref, :process, pid, reason}` instead.
  After an `:exit_status` or `:error` message, call
  `Process.demonitor(ref, [:flush])`.

  The caller must `ack/3` the bytes it has consumed; the exec-server sends no
  more than the configured window of unacknowledged output. The exec-server
  cannot slow a command down, so a command that produces more than 16 MiB of
  output the host has not acknowledged is killed and its stream ends with
  `{:error, "output buffer overflow"}`. If the caller exits, the command's
  process group is killed.

  `input/3` writes to a running command's standard input. Input the command
  has not read is buffered in the jail; a command that leaves more than
  16 MiB unread is killed and its stream ends with
  `{:error, "input buffer overflow"}`. Standard input is never closed. A
  command that exits while input is still being written to it ends with
  `{:error, "command stopped reading its input; exit status unknown"}`.

  ## Lifecycle

  When the client stops, it kills the launcher with `SIGKILL` and closes the
  port. A separate reaper process does the same if the client is killed
  without running `terminate/2`. Launchers should make that tear down the
  whole jail, for example with Bubblewrap's `--die-with-parent` and a PID
  namespace.
  """

  use GenServer

  alias Tackle.Exec.{Framer, Protocol}

  @default_max_frame 2 * 1_024 * 1_024
  @default_max_write 16 * 1_024 * 1_024
  @default_max_input 1_024 * 1_024
  @default_window 256 * 1_024
  @default_handshake_timeout 5_000
  @default_call_timeout 60_000
  @default_max_heap_bytes 256 * 1_024 * 1_024
  @default_max_requests 1_024
  @default_keep_env ["PATH", "LANG", "LC_ALL"]
  @request_overhead 4_096
  @flush_interval 10

  @typedoc "Executable and arguments used to start the jailed exec-server."
  @type launcher :: {Path.t(), [String.t()]}

  @typedoc "Errors returned by request functions."
  @type error ::
          :invalid_request
          | :too_large
          | :busy
          | :timeout
          | :exec_server_down
          | atom()
          | String.t()

  @doc """
  Starts a client and its exec-server.

  ## Options

    * `:launcher` - required `{executable, args}` that starts the exec-server.
    * `:max_frame` - largest accepted frame from the jail in bytes (default
      2 MiB). It also bounds `read/5` lengths. Decoding can take up to about
      16 times this much memory.
    * `:max_write` - largest `write/4` payload in bytes (default 16 MiB). Up to
      this many request bytes may be queued while the jail is not reading.
    * `:max_input` - largest `input/3` payload in bytes (default 1 MiB).
    * `:window` - unacknowledged output allowed per command (default 256 KiB).
    * `:max_requests` - pending requests allowed at once (default 1024).
    * `:handshake_timeout` - milliseconds to wait for the hello frame (default 5000).
    * `:max_heap_bytes` - heap limit for the client, including off-heap binaries
      in its mailbox (default 256 MiB). Exceeding it kills the client.
    * `:keep_env` - host environment variables passed to the launcher (default
      `["PATH", "LANG", "LC_ALL"]`). All others are unset.
    * `:cd` - working directory of the launcher (default: the current
      directory). Launchers typically mount it as the jailed workspace.
    * `:name` - optional process name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Starts `argv` inside the jail and streams its output to the caller.

  `argv[0]` is resolved inside the jail, using `PATH` from `:env` when present.

  ## Options

    * `:cwd` - required working directory inside the jail.
    * `:env` - list of `{name, value}` strings added to the command environment.
  """
  @spec exec(GenServer.server(), [String.t()], keyword()) ::
          {:ok, reference()} | {:error, error()}
  def exec(client, argv, opts) do
    params = %{argv: argv, cwd: Keyword.get(opts, :cwd), env: Keyword.get(opts, :env, [])}

    case GenServer.whereis(client) do
      nil ->
        {:error, :exec_server_down}

      pid ->
        ref = Process.monitor(pid)

        case call(pid, {:exec, params, ref}, @default_call_timeout) do
          {:ok, ^ref} ->
            {:ok, ref}

          {:error, reason} ->
            Process.demonitor(ref, [:flush])
            {:error, reason}
        end
    end
  end

  @doc "Acknowledges consumed output so the exec-server may send more."
  @spec ack(GenServer.server(), reference(), non_neg_integer()) :: :ok
  def ack(client, ref, bytes) when is_reference(ref) and is_integer(bytes) and bytes >= 0 do
    GenServer.cast(client, {:ack, ref, bytes})
  end

  @doc """
  Writes `data` to the standard input of a running command.

  Returns once the request is queued for the jail, not when the command has
  read it. Fails with `:unknown_command` when `ref` is not a running command
  of this client, `:too_large` above `:max_input`, and `:busy` while too many
  request bytes are queued.
  """
  @spec input(GenServer.server(), reference(), binary()) :: :ok | {:error, error()}
  def input(client, ref, data) when is_reference(ref) and is_binary(data),
    do: call(client, {:input, ref, data}, @default_call_timeout)

  @doc "Sends `SIGTERM` or `SIGKILL` to the command's process group."
  @spec signal(GenServer.server(), reference(), Protocol.signal()) :: :ok
  def signal(client, ref, signal) when is_reference(ref) and signal in [:term, :kill] do
    GenServer.cast(client, {:signal, ref, signal})
  end

  @doc """
  Reads up to `length` bytes at `offset` from a file inside the jail.

  `eof` is true when fewer than `length` bytes were available. `length` may be
  at most `:max_frame` minus a small overhead.
  """
  @spec read(GenServer.server(), String.t(), non_neg_integer(), pos_integer(), timeout()) ::
          {:ok, %{data: binary(), size: non_neg_integer(), eof: boolean()}} | {:error, error()}
  def read(client, path, offset, length, timeout \\ @default_call_timeout) do
    call(client, {:call, :read, %{path: path, offset: offset, length: length}}, timeout)
  end

  @doc """
  Writes `data` to a file inside the jail.

  ## Options

    * `:mode` - `:replace` (default) rewrites the file in place, `:append`
      appends, and `:create` creates a new owner-only file and fails with
      `{:error, :eexist}` if the path exists.
    * `:mkdir_p` - create missing parent directories (default `false`).
    * `:timeout` - call timeout in milliseconds.
  """
  @spec write(GenServer.server(), String.t(), binary(), keyword()) :: :ok | {:error, error()}
  def write(client, path, data, opts \\ []) do
    params = %{
      path: path,
      data: data,
      mkdir_p: Keyword.get(opts, :mkdir_p, false),
      mode: Keyword.get(opts, :mode, :replace)
    }

    timeout = Keyword.get(opts, :timeout, @default_call_timeout)

    case call(client, {:call, :write, params}, timeout) do
      {:ok, nil} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes a file inside the jail. Directories are not removed."
  @spec delete(GenServer.server(), String.t(), timeout()) :: :ok | {:error, error()}
  def delete(client, path, timeout \\ @default_call_timeout) do
    case call(client, {:call, :delete, %{path: path}}, timeout) do
      {:ok, nil} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the type, size, and mode of a path inside the jail, following symlinks."
  @spec stat(GenServer.server(), String.t(), timeout()) ::
          {:ok, %{type: atom(), size: non_neg_integer(), mode: non_neg_integer()}}
          | {:error, error()}
  def stat(client, path, timeout \\ @default_call_timeout) do
    call(client, {:call, :stat, %{path: path}}, timeout)
  end

  @doc "Lists the entry names of a directory inside the jail, following symlinks."
  @spec list(GenServer.server(), String.t(), timeout()) :: {:ok, [String.t()]} | {:error, error()}
  def list(client, path, timeout \\ @default_call_timeout) do
    call(client, {:call, :list, %{path: path}}, timeout)
  end

  defp call(client, request, timeout) do
    GenServer.call(client, request, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :exec_server_down}
  end

  @impl true
  def init(opts) do
    with {:ok, config} <- config(opts),
         {:ok, port, os_pid} <- open_launcher(config) do
      Process.flag(:trap_exit, true)

      Process.flag(:max_heap_size, %{
        size: div(config.max_heap_bytes, :erlang.system_info(:wordsize)),
        kill: true,
        error_logger: true,
        include_shared_binaries: true
      })

      Process.send_after(self(), :handshake_timeout, config.handshake_timeout)

      {:ok,
       %{
         port: port,
         os_pid: os_pid,
         reaper: start_reaper(os_pid),
         framer: Framer.new(config.max_frame),
         config: config,
         phase: :handshake,
         next_id: 1,
         requests: %{},
         refs: %{},
         outbox: :queue.new(),
         outbox_bytes: 0
       }}
    else
      {:error, reason} -> {:stop, {:shutdown, reason}}
    end
  end

  defp config(opts) do
    config = %{
      launcher: Keyword.get(opts, :launcher),
      max_frame: Keyword.get(opts, :max_frame, @default_max_frame),
      max_write: Keyword.get(opts, :max_write, @default_max_write),
      max_input: Keyword.get(opts, :max_input, @default_max_input),
      window: Keyword.get(opts, :window, @default_window),
      max_requests: Keyword.get(opts, :max_requests, @default_max_requests),
      handshake_timeout: Keyword.get(opts, :handshake_timeout, @default_handshake_timeout),
      max_heap_bytes: Keyword.get(opts, :max_heap_bytes, @default_max_heap_bytes),
      keep_env: Keyword.get(opts, :keep_env, @default_keep_env),
      cd: Keyword.get_lazy(opts, :cd, &File.cwd!/0)
    }

    integers = [:max_frame, :max_write, :max_input, :window, :max_requests, :handshake_timeout]

    cond do
      not launcher?(config.launcher) ->
        {:error, {:invalid_option, :launcher}}

      key = Enum.find(integers, &(not positive_integer?(Map.fetch!(config, &1)))) ->
        {:error, {:invalid_option, key}}

      config.max_frame <= @request_overhead ->
        {:error, {:invalid_option, :max_frame}}

      not positive_integer?(config.max_heap_bytes) ->
        {:error, {:invalid_option, :max_heap_bytes}}

      not (is_list(config.keep_env) and Enum.all?(config.keep_env, &is_binary/1)) ->
        {:error, {:invalid_option, :keep_env}}

      not (is_binary(config.cd) and File.dir?(config.cd)) ->
        {:error, {:invalid_option, :cd}}

      true ->
        {:ok, config}
    end
  end

  defp launcher?({executable, args}) when is_binary(executable) and is_list(args),
    do: Enum.all?(args, &is_binary/1)

  defp launcher?(_launcher), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp open_launcher(%{launcher: {executable, args}, keep_env: keep_env, cd: cd}) do
    env =
      for {name, _value} <- System.get_env(), name not in keep_env do
        {String.to_charlist(name), false}
      end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :stream,
        :exit_status,
        :use_stdio,
        :hide,
        {:args, args},
        {:env, env},
        {:cd, cd}
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> {:ok, port, os_pid}
      nil -> {:error, {:launcher_failed, :exited}}
    end
  rescue
    error in ErlangError -> {:error, {:launcher_failed, launcher_error(error)}}
  end

  @impl true
  def handle_call({:exec, params, ref}, {caller, _tag}, state) do
    id = state.next_id
    request = {:exec, id, Map.put(params, :window, state.config.window)}

    with :ok <- check_capacity(state),
         {:ok, request} <- Protocol.parse_request(request) do
      exec = %{
        kind: :exec,
        ref: ref,
        caller: caller,
        monitor: Process.monitor(caller),
        granted: state.config.window,
        received: 0,
        acked: 0
      }

      state = %{
        state
        | next_id: id + 1,
          requests: Map.put(state.requests, id, exec),
          refs: Map.put(state.refs, ref, id)
      }

      {:reply, {:ok, ref}, send_request(state, request)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, op, params}, from, state) do
    id = state.next_id

    with :ok <- check_capacity(state),
         {:ok, request} <- Protocol.parse_request({op, id, params}),
         :ok <- check_size(op, params, state.config) do
      entry = %{kind: :call, op: op, params: Map.delete(params, :data), from: from}
      state = %{state | next_id: id + 1, requests: Map.put(state.requests, id, entry)}
      {:noreply, send_request(state, request)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:input, _ref, ""}, _from, state), do: {:reply, :ok, state}

  def handle_call({:input, ref, data}, _from, state) do
    with {:ok, id, _exec} <- fetch_exec(state, ref),
         :ok <- check_input(data, state) do
      {:reply, :ok, send_request(state, {:input, id, data})}
    else
      :error -> {:reply, {:error, :unknown_command}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:ack, ref, bytes}, state) do
    case fetch_exec(state, ref) do
      {:ok, id, exec} -> {:noreply, grant(state, id, exec, bytes)}
      :error -> {:noreply, state}
    end
  end

  def handle_cast({:signal, ref, signal}, state) do
    case fetch_exec(state, ref) do
      {:ok, id, _exec} -> {:noreply, send_request(state, {:signal, id, signal})}
      :error -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Framer.push(state.framer, data) do
      {:ok, frames, framer} -> handle_frames(frames, %{state | framer: framer})
      {:error, reason} -> violation(state, reason)
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.reaper, :launcher_exited)
    {:stop, {:shutdown, {:exec_server_exited, status}}, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    send(state.reaper, :launcher_exited)
    {:stop, {:shutdown, :exec_server_port_closed}, %{state | port: nil}}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(:flush_outbox, state), do: {:noreply, flush_outbox(state)}

  def handle_info(:handshake_timeout, %{phase: :handshake} = state) do
    {:stop, {:shutdown, :handshake_timeout}, state}
  end

  def handle_info(:handshake_timeout, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.requests, fn {_id, entry} -> Map.get(entry, :monitor) == monitor end) do
      {id, exec} ->
        orphan = %{exec | caller: nil, monitor: nil}

        state =
          %{state | requests: Map.put(state.requests, id, orphan)}
          |> send_request({:signal, id, :kill})

        {:noreply, grant(state, id, orphan, orphan.received - orphan.acked)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.requests, fn
      {_id, %{kind: :call, from: from}} -> GenServer.reply(from, {:error, :exec_server_down})
      {_id, %{kind: :exec} = exec} -> notify(exec, {:error, :exec_server_down})
    end)

    if state.port do
      # Kill before closing: once the port is closed the launcher may exit and
      # its OS process ID may be reused.
      send(state.reaper, :launcher_exited)
      kill_os_process(state.os_pid)
      close_port(state.port)
    end

    :ok
  end

  defp handle_frames([], state), do: {:noreply, state}

  defp handle_frames([frame | frames], state) do
    with {:ok, term} <- Protocol.decode(frame),
         {:ok, message} <- Protocol.parse_message(term),
         {:ok, state} <- handle_message(message, state) do
      handle_frames(frames, state)
    else
      {:error, reason} -> violation(state, reason)
      {:stop, reason, state} -> {:stop, reason, state}
    end
  end

  defp handle_message({:hello, version}, %{phase: :handshake} = state) do
    if version == Protocol.version(),
      do: {:ok, %{state | phase: :ready}},
      else: {:stop, {:shutdown, {:unsupported_protocol_version, version}}, state}
  end

  defp handle_message(_message, %{phase: :handshake}), do: {:error, :expected_hello}
  defp handle_message({:hello, _version}, _state), do: {:error, :unexpected_hello}

  defp handle_message({:out, id, data}, state) do
    case Map.fetch(state.requests, id) do
      {:ok, %{kind: :exec} = exec} ->
        received = exec.received + byte_size(data)

        if received > exec.granted do
          {:error, :credit_exceeded}
        else
          exec = %{exec | received: received}
          state = %{state | requests: Map.put(state.requests, id, exec)}

          if exec.caller do
            notify(exec, {:data, data})
            {:ok, state}
          else
            {:ok, grant(state, id, exec, byte_size(data))}
          end
        end

      _other ->
        {:error, {:unexpected_reply, id}}
    end
  end

  defp handle_message({:exit, id, status}, state) do
    finish_exec(state, id, {:exit_status, status})
  end

  defp handle_message({:error, id, reason}, state) do
    case Map.fetch(state.requests, id) do
      {:ok, %{kind: :exec}} ->
        finish_exec(state, id, {:error, Protocol.error_reason(reason)})

      {:ok, %{kind: :call, from: from}} ->
        GenServer.reply(from, {:error, Protocol.error_reason(reason)})
        {:ok, %{state | requests: Map.delete(state.requests, id)}}

      :error ->
        {:error, {:unexpected_reply, id}}
    end
  end

  defp handle_message({:ok, id, result}, state) do
    with {:ok, %{kind: :call, op: op, params: params, from: from}} <-
           Map.fetch(state.requests, id),
         {:ok, result} <- Protocol.parse_result(op, params, result) do
      GenServer.reply(from, {:ok, result})
      {:ok, %{state | requests: Map.delete(state.requests, id)}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, {:unexpected_reply, id}}
    end
  end

  defp finish_exec(state, id, result) do
    case Map.fetch(state.requests, id) do
      {:ok, %{kind: :exec} = exec} ->
        notify(exec, result)
        if exec.monitor, do: Process.demonitor(exec.monitor, [:flush])

        {:ok,
         %{
           state
           | requests: Map.delete(state.requests, id),
             refs: Map.delete(state.refs, exec.ref)
         }}

      _other ->
        {:error, {:unexpected_reply, id}}
    end
  end

  defp fetch_exec(state, ref) do
    with {:ok, id} <- Map.fetch(state.refs, ref),
         {:ok, exec} <- Map.fetch(state.requests, id) do
      {:ok, id, exec}
    end
  end

  # Grants at most the bytes received but not yet acknowledged, so the
  # outstanding credit never exceeds the configured window.
  defp grant(state, id, exec, bytes) do
    bytes = min(bytes, exec.received - exec.acked)

    if bytes > 0 do
      exec = %{exec | acked: exec.acked + bytes, granted: exec.granted + bytes}

      %{state | requests: Map.put(state.requests, id, exec)}
      |> send_request({:grant, id, bytes})
    else
      state
    end
  end

  defp check_capacity(state) do
    cond do
      map_size(state.requests) >= state.config.max_requests -> {:error, :busy}
      state.outbox_bytes > state.config.max_write -> {:error, :busy}
      true -> :ok
    end
  end

  defp check_input(data, state) do
    cond do
      byte_size(data) > state.config.max_input -> {:error, :too_large}
      state.outbox_bytes > state.config.max_write -> {:error, :busy}
      true -> :ok
    end
  end

  defp check_size(:read, %{length: length}, config)
       when length > config.max_frame - @request_overhead,
       do: {:error, :too_large}

  defp check_size(:write, %{data: data}, config) when byte_size(data) > config.max_write,
    do: {:error, :too_large}

  defp check_size(_op, _params, _config), do: :ok

  defp notify(%{caller: nil}, _message), do: :ok

  defp notify(%{caller: caller, ref: ref}, message),
    do: send(caller, {:tackle_exec, ref, message})

  # Port.command/2 suspends the caller while the port is busy, and a suspended
  # process neither drains its mailbox nor enforces its heap limit. Never block:
  # queue frames the port does not accept and retry on a timer.
  defp send_request(state, request) do
    frame = Protocol.encode_frame(request)

    if :queue.is_empty(state.outbox) and Port.command(state.port, frame, [:nosuspend]) do
      state
    else
      if :queue.is_empty(state.outbox),
        do: Process.send_after(self(), :flush_outbox, @flush_interval)

      %{
        state
        | outbox: :queue.in(frame, state.outbox),
          outbox_bytes: state.outbox_bytes + byte_size(frame)
      }
    end
  end

  defp flush_outbox(state) do
    case :queue.out(state.outbox) do
      {{:value, frame}, outbox} ->
        if Port.command(state.port, frame, [:nosuspend]) do
          flush_outbox(%{
            state
            | outbox: outbox,
              outbox_bytes: state.outbox_bytes - byte_size(frame)
          })
        else
          Process.send_after(self(), :flush_outbox, @flush_interval)
          state
        end

      {:empty, _outbox} ->
        state
    end
  end

  defp violation(state, reason) do
    {:stop, {:shutdown, {:protocol_violation, reason}}, state}
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp launcher_error(%ErlangError{original: reason}) when is_atom(reason), do: reason
  defp launcher_error(error), do: Exception.message(error)

  defp start_reaper(os_pid) do
    client = self()

    spawn(fn ->
      monitor = Process.monitor(client)

      receive do
        :launcher_exited -> :ok
        {:DOWN, ^monitor, :process, _pid, _reason} -> kill_os_process(os_pid)
      end
    end)
  end

  defp kill_os_process(os_pid) do
    case System.find_executable("kill") do
      nil -> :os.cmd(~c"kill -KILL #{os_pid}")
      kill -> System.cmd(kill, ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
