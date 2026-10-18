defmodule Tackle.Elixir.ProjectNode do
  @moduledoc """
  Host-side client of a project node broker.

  The broker (`priv/project_node/broker.exs`) is an Elixir program that runs
  where the agent's commands run, through a `Tackle.Executor`: inside the
  jail when the session is jailed. It starts one project node per Mix project
  and drives it over Erlang distribution, which stays inside the executor;
  this client never joins it. The client talks to the broker over the
  command's standard input and output with `Tackle.Elixir.ProjectNode.Protocol`
  frames and treats everything the broker says as hostile: frames are size
  limited and checked, and any violation stops the client and the broker.

  The broker and its helper are written to a fresh directory under the
  executor's temporary directory and started with the `elixir` found on the
  executor's `PATH`, so project nodes use the project's own Elixir. The
  broker's standard error and logs go to `broker.log` in that directory.

  A linked reader process owns the broker command and forwards its events, so
  the broker stops when this process stops. The client also stops after an
  idle period without requests.
  """

  use GenServer

  alias Tackle.Elixir.ProjectNode.Protocol
  alias Tackle.Exec.Framer
  alias Tackle.Executor
  alias Tackle.Lib.Cancellation

  @max_frame 4 * 1_024 * 1_024
  @max_heap_bytes 256 * 1_024 * 1_024
  @default_handshake_timeout 30_000
  @default_idle_timeout 30 * 60 * 1_000
  @default_request_timeout 300_000
  @poll_interval 50

  @typedoc "Errors returned by requests."
  @type error :: :timeout | :cancelled | :node_down | String.t()

  @doc """
  Starts a client and its broker, returning once the broker has answered.

  ## Options

    * `:executor` - required `Tackle.Executor` to run the broker with.
    * `:handshake_timeout` - milliseconds to wait for the broker to start
      (default 30 seconds).
    * `:idle_timeout` - milliseconds without requests before the client and
      its broker stop (default 30 minutes).
    * `:elixir` - the `elixir` executable (default: `"elixir"`, resolved on
      the executor's `PATH`).
    * `:name` - optional process name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Compiles the Mix project at `root`, an absolute path as seen by the
  executor, starting its project node on first use.

  ## Options

    * `:timeout_ms` - give up after this many milliseconds (default 5 minutes).
    * `:cancellation_signal` - a `Tackle.Lib.Cancellation` signal; give up when
      it is cancelled.

  Giving up does not stop a compile that is already running in the project
  node; its result is discarded.
  """
  @spec compile(GenServer.server(), Path.t(), keyword()) ::
          {:ok, Protocol.compile_result()} | {:error, error()}
  def compile(server, root, opts \\ []) when is_binary(root) do
    request(server, {:compile, Path.expand(root)}, opts)
  end

  defp request(server, request, opts) do
    deadline =
      System.monotonic_time(:millisecond) +
        Keyword.get(opts, :timeout_ms, @default_request_timeout)

    signal = Keyword.get(opts, :cancellation_signal)

    case GenServer.whereis(server) do
      nil ->
        {:error, :node_down}

      pid ->
        monitor = Process.monitor(pid)

        case call(pid, {:request, request}) do
          {:ok, id} ->
            await(pid, monitor, id, request, deadline, signal)

          {:error, reason} ->
            Process.demonitor(monitor, [:flush])
            {:error, reason}
        end
    end
  end

  defp call(pid, message) do
    GenServer.call(pid, message)
  catch
    :exit, _reason -> {:error, :node_down}
  end

  defp await(pid, monitor, id, request, deadline, signal) do
    receive do
      {__MODULE__, ^id, {:ok, result}} ->
        Process.demonitor(monitor, [:flush])
        parse(request, result)

      {__MODULE__, ^id, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :node_down}
    after
      wait_time(deadline) ->
        cond do
          Cancellation.cancelled?(signal) -> give_up(pid, monitor, id, :cancelled)
          System.monotonic_time(:millisecond) >= deadline -> give_up(pid, monitor, id, :timeout)
          true -> await(pid, monitor, id, request, deadline, signal)
        end
    end
  end

  defp parse(request, result) do
    case Protocol.parse_result(request, result) do
      {:ok, result} -> {:ok, result}
      {:error, :invalid_result} -> {:error, "the project node sent an invalid result"}
    end
  end

  # Synchronous, so a reply the server sent before forgetting the request is
  # already in the mailbox and is flushed here, not left for later.
  defp give_up(pid, monitor, id, reason) do
    _ = call(pid, {:forget, id})
    Process.demonitor(monitor, [:flush])

    receive do
      {__MODULE__, ^id, _reply} -> :ok
    after
      0 -> :ok
    end

    {:error, reason}
  end

  defp wait_time(deadline),
    do: min(max(deadline - System.monotonic_time(:millisecond), 0), @poll_interval)

  # -- Server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    Process.flag(:max_heap_size, %{
      size: div(@max_heap_bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: true,
      include_shared_binaries: true
    })

    executor = Keyword.fetch!(opts, :executor)
    handshake_timeout = Keyword.get(opts, :handshake_timeout, @default_handshake_timeout)

    with {:ok, argv, dir} <- install(executor, Keyword.get(opts, :elixir, "elixir")),
         {:ok, reader, handle} <- start_reader(executor, argv, dir),
         deadline = System.monotonic_time(:millisecond) + handshake_timeout,
         {:ok, framer, frames} <- handshake(reader, Framer.new(@max_frame), deadline) do
      state = %{
        executor: executor,
        reader: reader,
        handle: handle,
        framer: framer,
        next_id: 1,
        pending: %{},
        idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout)
      }

      case handle_frames(frames, state) do
        {:ok, state} -> {:ok, state, state.idle_timeout}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # The broker's sources go to a fresh directory, created exclusively, in the
  # executor's temporary directory, which a jail keeps private.
  defp install(executor, elixir) do
    dir =
      Path.join(
        Executor.tmp_dir(executor),
        "tackle-project-node-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    priv = :code.priv_dir(:tackle_elixir) |> to_string() |> Path.join("project_node")
    broker = Path.join(dir, "broker.exs")
    helper = Path.join(dir, "helper.ex")

    with {:ok, broker_source} <- File.read(Path.join(priv, "broker.exs")),
         {:ok, helper_source} <- File.read(Path.join(priv, "helper.ex")),
         :ok <- Executor.write(executor, broker, broker_source, mkdir_p: true, mode: :create),
         :ok <- Executor.write(executor, helper, helper_source, mode: :create) do
      log = Path.join(dir, "broker.log")

      # Standard error goes to the log, not into the frames: the exec-server
      # merges it into standard output, and the VM can print to it before the
      # broker's own code runs.
      argv =
        ["sh", "-c", ~S(log="$1"; shift; exec "$@" 2>>"$log"), "sh", log] ++
          [elixir, "--erl", "-start_epmd false -noinput", broker, helper, log]

      {:ok, argv, dir}
    else
      {:error, reason} -> {:error, {:install_failed, reason}}
    end
  end

  defp start_reader(executor, argv, dir) do
    client = self()
    reader = spawn_link(fn -> read(client, executor, argv, dir) end)

    receive do
      {^reader, {:started, handle}} -> {:ok, reader, handle}
      {^reader, {:exec_failed, reason}} -> {:error, {:broker_failed, reason}}
      {:EXIT, ^reader, reason} -> {:error, {:broker_failed, reason}}
    end
  end

  # Owns the broker command: Tackle.Executor.Local links its port to this
  # process, and Tackle.Executor.Jailed kills the command when it exits. It
  # does not trap exits, so it dies with the client and the broker stops; a
  # broken pipe to the broker kills it too, which stops the client.
  defp read(client, executor, argv, dir) do
    # The distribution cookie of the broker and its project nodes: read at
    # boot from the environment, never on a command line or in a file.
    cookie = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    env = [{"ERL_ZFLAGS", "-setcookie " <> cookie}]

    case Executor.exec(executor, argv, cwd: dir, env: env) do
      {:ok, handle} ->
        send(client, {self(), {:started, handle}})
        forward(client, executor, handle)

      {:error, reason} ->
        send(client, {self(), {:exec_failed, reason}})
    end
  end

  defp forward(client, executor, handle) do
    case Executor.await(executor, handle, 1_000) do
      :timeout ->
        forward(client, executor, handle)

      {:data, data} ->
        send(client, {self(), {:data, data}})
        forward(client, executor, handle)

      {:exit_status, status} ->
        exit({:shutdown, {:broker_exited, status}})

      {:error, reason} ->
        exit({:shutdown, {:broker_failed, reason}})
    end
  end

  defp handshake(reader, framer, deadline) do
    receive do
      {^reader, {:data, data}} ->
        with {:ok, frames, framer} <- push(framer, data) do
          case frames do
            [] -> handshake(reader, framer, deadline)
            [hello | rest] -> check_hello(hello, framer, rest)
          end
        end

      {:EXIT, ^reader, {:shutdown, reason}} ->
        {:error, reason}

      {:EXIT, ^reader, reason} ->
        {:error, reason}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :handshake_timeout}
    end
  end

  defp check_hello(frame, framer, rest) do
    version = Protocol.version()

    case decode(frame) do
      {:ok, {:hello, ^version}} -> {:ok, framer, rest}
      {:ok, {:hello, other}} -> {:error, {:unsupported_protocol_version, other}}
      _other -> {:error, {:protocol_violation, :expected_hello}}
    end
  end

  @impl true
  def handle_call({:request, request}, {caller, _tag}, state) do
    id = state.next_id

    case Executor.input(state.executor, state.handle, Protocol.encode_request(id, request)) do
      :ok ->
        state = %{state | next_id: id + 1, pending: Map.put(state.pending, id, caller)}
        {:reply, {:ok, id}, state, state.idle_timeout}

      {:error, reason} ->
        {:stop, {:shutdown, {:broker_failed, reason}}, {:error, :node_down}, state}
    end
  end

  def handle_call({:forget, id}, _from, state) do
    state = %{state | pending: Map.delete(state.pending, id)}
    {:reply, :ok, state, state.idle_timeout}
  end

  @impl true
  def handle_info({reader, {:data, data}}, %{reader: reader} = state) do
    with {:ok, frames, framer} <- push(state.framer, data),
         {:ok, state} <- handle_frames(frames, %{state | framer: framer}) do
      {:noreply, state, state.idle_timeout}
    else
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state),
    do: {:stop, reason, state}

  def handle_info(:timeout, %{pending: pending} = state) when map_size(pending) == 0,
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state, state.idle_timeout}

  defp push(framer, data) do
    case Framer.push(framer, data) do
      {:ok, frames, framer} -> {:ok, frames, framer}
      {:error, reason} -> {:error, {:protocol_violation, reason}}
    end
  end

  defp handle_frames(frames, state) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, state} ->
      case decode(frame) do
        {:ok, {:reply, id, result}} -> {:cont, {:ok, deliver(state, id, result)}}
        {:ok, {:hello, _version}} -> {:halt, {:error, {:protocol_violation, :unexpected_hello}}}
        {:error, reason} -> {:halt, {:error, {:protocol_violation, reason}}}
      end
    end)
  end

  defp decode(frame) do
    with {:ok, term} <- Protocol.decode(frame) do
      Protocol.parse_message(term)
    end
  end

  defp deliver(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {caller, pending} ->
        send(caller, {__MODULE__, id, result})
        %{state | pending: pending}
    end
  end
end
