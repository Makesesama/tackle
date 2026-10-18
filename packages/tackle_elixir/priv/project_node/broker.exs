# The project node broker. Tackle copies this file into the executor's
# temporary directory and starts it with the project's `elixir`:
#
#     elixir --erl "-start_epmd false -noinput" broker.exs HELPER LOG
#
# with the distribution cookie in ERL_ZFLAGS ("-setcookie ..."), so it is
# never on a command line or in a cookie file; the project nodes inherit it.
#
# It speaks 4-byte length-prefixed Erlang terms with the host over standard
# input and output and drives one project node per Mix project over Erlang
# distribution, which stays inside the executor (the jail, when there is
# one): the broker listens on loopback only, without EPMD, and the project
# nodes it starts do not listen at all. The host trusts nothing this program
# sends and checks every frame.
#
# Standard error may be merged into standard output, so nothing but frames
# may be written there: the broker sends its own output and logs to LOG.
#
# Keep this file free of dependencies and of Elixir APIs newer than 1.15.

defmodule TackleProjectNode.Broker do
  @moduledoc false

  @protocol 1
  @boot_timeout 120_000
  @connect_timeout 60_000
  @max_output 65_536

  def main([helper, log]) do
    isolate_output(log)
    ensure_home(Path.dirname(log))
    Process.flag(:trap_exit, true)
    io = Port.open({:fd, 0, 1}, [:binary, {:packet, 4}, :eof])
    dist_port = start_distribution()
    send_frame(io, {:hello, @protocol})

    loop(%{
      io: io,
      helper: helper,
      dir: Path.dirname(log),
      dist_port: dist_port,
      workers: %{},
      pending: %{}
    })
  end

  # Group leader and logger go to the log file: standard output carries frames.
  defp isolate_output(log) do
    {:ok, device} = File.open(log, [:append, :utf8])
    Process.group_leader(self(), device)
    _ = :logger.remove_handler(:default)
    _ = :logger.add_handler(:default, :logger_std_h, %{config: %{file: String.to_charlist(log)}})
    :ok
  end

  # Distribution reads the cookie file from HOME, and Mix keeps its state
  # there. An executor may clear the environment; then this directory serves
  # as HOME for the broker and the project nodes it starts.
  defp ensure_home(dir) do
    if System.get_env("HOME") in [nil, ""], do: System.put_env("HOME", dir)
    :ok
  end

  defp start_distribution do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    Application.put_env(:kernel, :erl_epmd_node_listen_port, port)
    Application.put_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})
    name = String.to_atom("tackle_broker_#{System.unique_integer([:positive])}@127.0.0.1")
    {:ok, _pid} = Node.start(name, :longnames)
    port
  end

  defp loop(state) do
    io = state.io

    receive do
      {^io, {:data, frame}} ->
        state |> handle_frame(frame) |> loop()

      {^io, :eof} ->
        # A clean shutdown removes the broker's directory; after a failure it
        # stays, with the log.
        File.rm_rf(state.dir)
        System.halt(0)

      {:EXIT, ^io, _reason} ->
        System.halt(1)

      {:reply, id, result} ->
        state |> reply(id, result) |> loop()

      {:EXIT, pid, reason} ->
        state |> worker_exited(pid, reason) |> loop()

      _other ->
        loop(state)
    end
  end

  defp handle_frame(state, frame) do
    case decode(frame) do
      {:request, id, {:compile, root}} when is_integer(id) and is_binary(root) ->
        dispatch(state, id, root, :compile)

      {:request, id, _op} when is_integer(id) ->
        send_frame(state.io, {:reply, id, {:error, "unknown request"}})
        state

      other ->
        IO.puts("tackle broker: invalid frame #{inspect(other)}")
        System.halt(2)
    end
  end

  defp decode(frame) do
    :erlang.binary_to_term(frame, [:safe])
  rescue
    ArgumentError -> :invalid
  end

  defp dispatch(state, id, root, op) do
    {worker, state} = worker(state, root)
    send(worker, {:run, id, op})
    %{state | pending: Map.put(state.pending, id, root)}
  end

  defp worker(state, root) do
    case state.workers do
      %{^root => pid} ->
        {pid, state}

      _workers ->
        broker = self()
        config = Map.take(state, [:helper, :dist_port])
        pid = spawn_link(fn -> TackleProjectNode.Worker.start(broker, root, config) end)
        {pid, %{state | workers: Map.put(state.workers, root, pid)}}
    end
  end

  defp reply(state, id, result) do
    send_frame(state.io, {:reply, id, result})
    %{state | pending: Map.delete(state.pending, id)}
  end

  # A worker that dies takes its project node with it; its pending requests
  # fail and the next request for the project starts a new one.
  defp worker_exited(state, pid, reason) do
    case Enum.find(state.workers, fn {_root, worker} -> worker == pid end) do
      {root, _pid} ->
        message = "project node failed: " <> truncate(inspect(reason), 2_000)

        state =
          Enum.reduce(state.pending, state, fn
            {id, ^root}, acc -> reply(acc, id, {:error, message})
            _entry, acc -> acc
          end)

        %{state | workers: Map.delete(state.workers, root)}

      nil ->
        state
    end
  end

  defp send_frame(io, term) do
    Port.command(io, :erlang.term_to_binary(term))
    :ok
  end

  def truncate(binary, max) when byte_size(binary) <= max, do: binary
  def truncate(binary, max), do: binary_part(binary, 0, max)

  def max_output, do: @max_output
  def boot_timeout, do: @boot_timeout
  def connect_timeout, do: @connect_timeout
end

defmodule TackleProjectNode.Worker do
  @moduledoc false
  # One per Mix project: starts its node, then runs its requests one at a time.

  alias TackleProjectNode.Broker

  def start(broker, root, config) do
    :ok = :net_kernel.monitor_nodes(true, node_type: :all)

    case start_node(root, config) do
      {:ok, node, port} ->
        loop(broker, node, port)

      {:error, message} ->
        fail_requests(broker, message)
    end
  end

  # Requests that arrive after a failed start get the same error until the
  # broker replaces this worker.
  defp fail_requests(broker, message) do
    receive do
      {:run, id, _op} ->
        send(broker, {:reply, id, {:error, message}})
        fail_requests(broker, message)
    after
      0 -> exit({:shutdown, :start_failed})
    end
  end

  defp loop(broker, node, port) do
    receive do
      {:run, id, :compile} ->
        send(broker, {:reply, id, compile(node)})
        loop(broker, node, port)

      {^port, {:data, data}} ->
        IO.write(data)
        loop(broker, node, port)

      {^port, {:exit_status, status}} ->
        exit({:shutdown, {:project_node_exited, status}})

      {:nodedown, ^node, _info} ->
        exit({:shutdown, :project_node_down})

      _other ->
        loop(broker, node, port)
    end
  end

  defp start_node(root, config) do
    case System.find_executable("elixir") do
      nil -> {:error, "elixir was not found on PATH"}
      elixir -> spawn_node(elixir, root, config)
    end
  end

  defp spawn_node(elixir, root, config) do
    name = "tackle_project_#{System.unique_integer([:positive])}@127.0.0.1"
    node = String.to_atom(name)

    # The cookie comes with the inherited ERL_ZFLAGS.
    connect = ~s|true = Node.connect(String.to_atom(System.fetch_env!("TACKLE_BROKER")))|

    erl =
      "-start_epmd false -dist_listen false -noinput -kernel erl_epmd_node_listen_port #{config.dist_port}"

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: root,
        args: ["--erl", erl, "--name", name, "--no-halt", "-e", connect],
        env: [{~c"TACKLE_BROKER", Atom.to_charlist(node())}]
      ])

    with :ok <- await_connection(node, port, ""),
         :ok <- boot(node, config.helper) do
      {:ok, node, port}
    else
      {:error, message} ->
        stop(port)
        {:error, message}
    end
  end

  defp await_connection(node, port, output) do
    receive do
      {:nodeup, ^node, _info} ->
        :ok

      {^port, {:data, data}} ->
        IO.write(data)
        await_connection(node, port, tail(output <> data))

      {^port, {:exit_status, status}} ->
        {:error, "project node exited with status #{status}: #{output}"}
    after
      Broker.connect_timeout() -> {:error, "project node did not connect: #{output}"}
    end
  end

  defp boot(node, helper) do
    with {:ok, _modules} <- rpc(node, Code, :compile_file, [helper], 60_000),
         {:ok, :ok} <- rpc(node, TackleProjectNode.Helper, :boot, [node()], Broker.boot_timeout()) do
      :ok
    else
      {:ok, {:error, message}} -> {:error, "cannot load the project: " <> message}
      {:error, message} -> {:error, "cannot load the project: " <> message}
    end
  end

  defp compile(node) do
    case rpc(node, TackleProjectNode.Helper, :compile, [], :infinity) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, message}} -> {:error, message}
      {:error, message} -> {:error, message}
    end
  end

  defp rpc(node, module, function, args, timeout) do
    {:ok, :erpc.call(node, module, function, args, timeout)}
  catch
    kind, reason ->
      {:error, Broker.truncate(Exception.format_banner(kind, reason), 4_000)}
  end

  defp kill(os_pid) do
    case System.find_executable("kill") do
      nil -> :ok
      kill -> System.cmd(kill, ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end
  end

  defp tail(output) when byte_size(output) <= 4_000, do: output
  defp tail(output), do: binary_part(output, byte_size(output) - 4_000, 4_000)

  # A project node ignores its standard input (`--no-halt`), so closing the
  # port does not stop it; kill the process. Once booted, a node halts by
  # itself when the broker goes away (see TackleProjectNode.Helper.boot/1).
  defp stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> kill(os_pid)
      nil -> :ok
    end

    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end

TackleProjectNode.Broker.main(System.argv())
