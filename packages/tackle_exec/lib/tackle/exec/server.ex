defmodule Tackle.Exec.Server do
  @moduledoc """
  Jail-side exec-server.

  `main/0` speaks `Tackle.Exec.Protocol` over standard input and output and is
  meant to run inside a jail, started by the host through a launcher such as a
  Bubblewrap wrapper:

      erl -noshell -noinput -pa <elixir ebin> -pa <tackle_exec ebin> \\
        -s Elixir.Tackle.Exec.Server main

  Standard output is reserved for protocol frames. The server redirects its own
  group leader and the default logger handler to standard error before it sends
  anything; the launcher decides where standard error goes.

  Commands are spawned as port children, which the runtime already places in
  their own session and process group, so `:signal` reaches the whole group
  through the `kill` executable. Output the host has not granted credit for is
  buffered; a command whose buffered output exceeds 16 MiB is killed and
  reported as `"output buffer overflow"`. Filesystem operations run in
  short-lived worker processes so a blocking path, such as a FIFO, cannot stall
  the loop.

  This module trusts the host, but it is not trusted by the host: everything it
  sends is validated on the host side.
  """

  alias Tackle.Exec.Protocol

  @chunk_bytes 64 * 1_024
  @max_pending_bytes 16 * 1_024 * 1_024

  @doc "Runs the exec-server until standard input closes, then halts the VM."
  @spec main() :: no_return()
  def main do
    isolate_stdout()
    Process.flag(:trap_exit, true)
    io = Port.open({:fd, 0, 1}, [:binary, {:packet, 4}, :eof])

    state = %{
      io: io,
      execs: %{},
      ports: %{},
      kill: System.find_executable("kill")
    }

    send_message(state, Protocol.hello())

    status =
      try do
        loop(state)
      catch
        kind, reason ->
          IO.puts(:stderr, "tackle exec-server crashed: " <> Exception.format(kind, reason))
          1
      end

    System.halt(status)
  end

  defp isolate_stdout do
    Process.group_leader(self(), Process.whereis(:standard_error))
    _ = :logger.remove_handler(:default)
    _ = :logger.add_handler(:default, :logger_std_h, %{config: %{type: :standard_error}})
    :ok
  end

  defp loop(%{io: io} = state) do
    receive do
      {^io, {:data, frame}} ->
        state |> handle_frame(frame) |> loop()

      {^io, :eof} ->
        kill_running(state)
        0

      {:EXIT, ^io, reason} ->
        IO.puts(:stderr, "tackle exec-server lost standard I/O: #{inspect(reason)}")
        kill_running(state)
        1

      {port, {:data, data}} when is_map_key(state.ports, port) ->
        state |> exec_output(Map.fetch!(state.ports, port), data) |> loop()

      {port, {:exit_status, status}} when is_map_key(state.ports, port) ->
        state |> exec_exited(port, status) |> loop()

      {:EXIT, port, reason} when is_map_key(state.ports, port) ->
        state |> exec_failed(port, reason) |> loop()

      {:file_result, id, result} ->
        send_message(state, file_reply(id, result))
        loop(state)

      _other ->
        loop(state)
    end
  end

  defp handle_frame(state, frame) do
    with {:ok, term} <- Protocol.decode(frame),
         {:ok, request} <- Protocol.parse_request(term) do
      handle_request(state, request)
    else
      {:error, reason} ->
        IO.puts(:stderr, "tackle exec-server received an invalid request: #{inspect(reason)}")
        kill_running(state)
        System.halt(2)
    end
  end

  defp handle_request(state, {:exec, id, params}) do
    case spawn_command(params) do
      {:ok, port, os_pid} ->
        exec = %{
          id: id,
          port: port,
          os_pid: os_pid,
          credit: params.window,
          pending: :queue.new(),
          pending_bytes: 0,
          status: nil,
          failure: nil
        }

        %{state | execs: Map.put(state.execs, id, exec), ports: Map.put(state.ports, port, id)}

      {:error, reason} ->
        send_message(state, {:error, id, Protocol.wire_error(reason)})
        state
    end
  end

  defp handle_request(state, {:signal, id, signal}) do
    case state.execs do
      %{^id => %{status: nil} = exec} -> kill_group(state, exec, signal)
      _execs -> :ok
    end

    state
  end

  defp handle_request(state, {:grant, id, bytes}) do
    case state.execs do
      %{^id => exec} -> flush(state, %{exec | credit: exec.credit + bytes})
      _execs -> state
    end
  end

  defp handle_request(state, {:read, id, params}),
    do: run_file_op(state, id, fn -> read(params) end)

  defp handle_request(state, {:write, id, params}),
    do: run_file_op(state, id, fn -> write(params) end)

  defp handle_request(state, {:stat, id, params}),
    do: run_file_op(state, id, fn -> stat(params) end)

  defp spawn_command(%{argv: [command | args], cwd: cwd, env: env}) do
    with {:ok, executable} <- find_executable(command, cwd, env) do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          :hide,
          {:args, args},
          {:arg0, command},
          {:cd, cwd},
          {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
        ])

      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> {:ok, port, os_pid}
        nil -> {:error, "command exited before it started"}
      end
    end
  rescue
    error in ErlangError -> {:error, port_error(error)}
  end

  defp port_error(%ErlangError{original: reason}) when is_atom(reason), do: reason
  defp port_error(error), do: Exception.message(error)

  defp find_executable(command, cwd, env) do
    if String.contains?(command, "/") do
      {:ok, Path.expand(command, cwd)}
    else
      path =
        Enum.find_value(env, System.get_env("PATH", ""), fn
          {"PATH", value} -> value
          _entry -> nil
        end)

      case :os.find_executable(String.to_charlist(command), String.to_charlist(path)) do
        false -> {:error, "#{command}: command not found"}
        executable -> {:ok, List.to_string(executable)}
      end
    end
  end

  defp exec_output(state, id, data) do
    exec = Map.fetch!(state.execs, id)

    cond do
      exec.failure ->
        state

      exec.pending_bytes + byte_size(data) > @max_pending_bytes ->
        kill_group(state, exec, :kill)

        put_exec(state, %{
          exec
          | failure: "output buffer overflow",
            pending: :queue.new(),
            pending_bytes: 0
        })

      true ->
        flush(state, %{
          exec
          | pending: :queue.in(data, exec.pending),
            pending_bytes: exec.pending_bytes + byte_size(data)
        })
    end
  end

  defp exec_exited(state, port, status) do
    id = Map.fetch!(state.ports, port)
    exec = Map.fetch!(state.execs, id)
    flush(%{state | ports: Map.delete(state.ports, port)}, %{exec | status: status})
  end

  # A command port that exits without reporting a status is a server-side
  # failure; report it instead of leaving the host waiting.
  defp exec_failed(state, port, reason) do
    id = Map.fetch!(state.ports, port)
    exec = Map.fetch!(state.execs, id)
    kill_group(state, exec, :kill)

    exec = %{
      exec
      | status: 0,
        failure: exec.failure || "command port failed: #{inspect(reason)}",
        pending: :queue.new(),
        pending_bytes: 0
    }

    flush(%{state | ports: Map.delete(state.ports, port)}, exec)
  end

  defp flush(state, %{credit: credit, pending_bytes: pending} = exec)
       when credit > 0 and pending > 0 do
    {chunk, size, rest} = take(exec.pending, min(credit, @chunk_bytes), [], 0)
    send_message(state, {:out, exec.id, chunk})

    flush(state, %{
      exec
      | credit: credit - size,
        pending: rest,
        pending_bytes: pending - size
    })
  end

  defp flush(state, %{status: nil} = exec), do: put_exec(state, exec)

  defp flush(state, %{pending_bytes: 0} = exec) do
    message =
      if exec.failure,
        do: {:error, exec.id, exec.failure},
        else: {:exit, exec.id, exec.status}

    send_message(state, message)
    %{state | execs: Map.delete(state.execs, exec.id)}
  end

  defp flush(state, exec), do: put_exec(state, exec)

  # Takes up to `limit` bytes from the front of the queue, splitting only the
  # last chunk taken.
  defp take(queue, limit, acc, size) do
    case :queue.out(queue) do
      {{:value, data}, rest} when size + byte_size(data) <= limit ->
        take(rest, limit, [acc | data], size + byte_size(data))

      {{:value, data}, rest} when size < limit ->
        head_size = limit - size
        <<head::binary-size(^head_size), tail::binary>> = data
        {IO.iodata_to_binary([acc | head]), limit, :queue.in_r(tail, rest)}

      _other ->
        {IO.iodata_to_binary(acc), size, queue}
    end
  end

  defp put_exec(state, exec), do: %{state | execs: Map.put(state.execs, exec.id, exec)}

  defp kill_running(state) do
    for {_id, %{status: nil} = exec} <- state.execs, do: kill_group(state, exec, :kill)
    :ok
  end

  defp kill_group(%{kill: nil}, _exec, _signal) do
    IO.puts(:stderr, "tackle exec-server cannot signal commands: kill was not found on PATH")
  end

  defp kill_group(%{kill: kill}, %{os_pid: os_pid}, signal) do
    name = if signal == :kill, do: "KILL", else: "TERM"
    System.cmd(kill, ["-s", name, "--", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  end

  defp run_file_op(state, id, operation) do
    server = self()

    spawn(fn ->
      result =
        try do
          operation.()
        catch
          kind, reason -> {:error, Exception.format_banner(kind, reason)}
        end

      send(server, {:file_result, id, result})
    end)

    state
  end

  defp file_reply(id, {:ok, result}), do: {:ok, id, result}
  defp file_reply(id, {:error, reason}), do: {:error, id, Protocol.wire_error(reason)}

  defp read(%{path: path, offset: offset, length: length}) do
    with {:ok, %File.Stat{type: type, size: size}} <- File.stat(path),
         :ok <- if(type == :directory, do: {:error, :eisdir}, else: :ok),
         {:ok, io} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        case :file.pread(io, offset, length) do
          {:ok, data} -> {:ok, %{data: data, size: size, eof: byte_size(data) < length}}
          :eof -> {:ok, %{data: "", size: size, eof: true}}
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(io)
      end
    end
  end

  defp write(%{path: path, data: data, mkdir_p: mkdir_p}) do
    with :ok <- if(mkdir_p, do: File.mkdir_p(Path.dirname(path)), else: :ok),
         :ok <- File.write(path, data) do
      {:ok, nil}
    end
  end

  defp stat(%{path: path}) do
    with {:ok, %File.Stat{type: type, size: size, mode: mode}} <- File.stat(path) do
      {:ok, %{type: type, size: size, mode: mode}}
    end
  end

  defp send_message(%{io: io}, message) do
    Port.command(io, Protocol.encode(message))
    :ok
  end
end
