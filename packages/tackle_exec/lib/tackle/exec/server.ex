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
  reported as `"output buffer overflow"`. Input for a command's standard input
  is written by a writer process of its own, so a command that stops reading
  blocks only its writer, never the server; a command whose unwritten input
  exceeds 16 MiB is killed and reported as `"input buffer overflow"`. When
  a command exits or closes its standard input while input is still being
  written, the write fails and the exit status is lost; the command is then
  reported as `"command stopped reading its input; exit status unknown"`. Filesystem operations run in
  short-lived worker processes so a blocking path, such as a FIFO, cannot stall
  the loop.

  This module trusts the host, but it is not trusted by the host: everything it
  sends is validated on the host side.
  """

  alias Tackle.Exec.{Command, FileOps, Protocol}

  @chunk_bytes 64 * 1_024
  @max_pending_bytes 16 * 1_024 * 1_024
  @max_pending_input_bytes 16 * 1_024 * 1_024

  @doc "Runs the exec-server until standard input closes, then halts the VM."
  @spec main() :: no_return()
  def main do
    isolate_stdout()
    Process.flag(:trap_exit, true)
    io = Port.open({:fd, 0, 1}, [:binary, {:packet, 4}, :eof])

    state = %{
      io: io,
      execs: %{},
      ports: %{}
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

      {:input_written, id, bytes} ->
        state |> input_written(id, bytes) |> loop()

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
    case Command.open(params.argv, params.cwd, params.env) do
      {:ok, port, os_pid} ->
        exec = %{
          id: id,
          port: port,
          os_pid: os_pid,
          credit: params.window,
          pending: :queue.new(),
          pending_bytes: 0,
          status: nil,
          failure: nil,
          writer: nil,
          input_bytes: 0
        }

        %{state | execs: Map.put(state.execs, id, exec), ports: Map.put(state.ports, port, id)}

      {:error, reason} ->
        send_message(state, {:error, id, Protocol.wire_error(reason)})
        state
    end
  end

  defp handle_request(state, {:signal, id, signal}) do
    case state.execs do
      %{^id => %{status: nil} = exec} -> kill_group(exec, signal)
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

  defp handle_request(state, {:input, id, data}) do
    case state.execs do
      %{^id => %{status: nil, failure: nil} = exec} -> put_exec(state, input(exec, data))
      _execs -> state
    end
  end

  defp handle_request(state, {:read, id, %{path: path, offset: offset, length: length}}),
    do: run_file_op(state, id, fn -> FileOps.read(path, offset, length) end)

  defp handle_request(state, {:write, id, %{path: path, data: data} = params}) do
    opts = [mkdir_p: params.mkdir_p, mode: params.mode]
    run_file_op(state, id, fn -> with :ok <- FileOps.write(path, data, opts), do: {:ok, nil} end)
  end

  defp handle_request(state, {:delete, id, %{path: path}}),
    do: run_file_op(state, id, fn -> with :ok <- FileOps.delete(path), do: {:ok, nil} end)

  defp handle_request(state, {:stat, id, %{path: path}}),
    do: run_file_op(state, id, fn -> FileOps.stat(path) end)

  defp handle_request(state, {:list, id, %{path: path}}),
    do: run_file_op(state, id, fn -> FileOps.list(path) end)

  defp input(exec, data) do
    if exec.input_bytes + byte_size(data) > @max_pending_input_bytes do
      kill_group(exec, :kill)
      stop_writer(exec)
      %{exec | failure: "input buffer overflow", writer: nil, input_bytes: 0}
    else
      exec = ensure_writer(exec)
      send(exec.writer, {:write, data})
      %{exec | input_bytes: exec.input_bytes + byte_size(data)}
    end
  end

  defp ensure_writer(%{writer: nil, port: port, id: id} = exec) do
    server = self()
    %{exec | writer: spawn(fn -> write_input(server, id, port) end)}
  end

  defp ensure_writer(exec), do: exec

  # Port.command/2 suspends the caller while the command does not read its
  # input; only this process waits. Writing to a closed port raises, which
  # ends the writer.
  defp write_input(server, id, port) do
    receive do
      {:write, data} ->
        if command(port, data) do
          send(server, {:input_written, id, byte_size(data)})
          write_input(server, id, port)
        end
    end
  end

  defp command(port, data) do
    Port.command(port, data)
  rescue
    ArgumentError -> false
  end

  defp input_written(state, id, bytes) do
    case state.execs do
      %{^id => exec} -> put_exec(state, %{exec | input_bytes: max(exec.input_bytes - bytes, 0)})
      _execs -> state
    end
  end

  defp stop_writer(%{writer: nil}), do: :ok
  defp stop_writer(%{writer: writer}), do: Process.exit(writer, :kill)

  defp exec_output(state, id, data) do
    exec = Map.fetch!(state.execs, id)

    cond do
      exec.failure ->
        state

      exec.pending_bytes + byte_size(data) > @max_pending_bytes ->
        kill_group(exec, :kill)

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
    stop_writer(exec)

    flush(%{state | ports: Map.delete(state.ports, port)}, %{
      exec
      | status: status,
        writer: nil
    })
  end

  # A command port that exits without reporting a status is a server-side
  # failure; report it instead of leaving the host waiting.
  defp exec_failed(state, port, reason) do
    id = Map.fetch!(state.ports, port)
    exec = Map.fetch!(state.execs, id)
    kill_group(exec, :kill)
    stop_writer(exec)

    exec = %{
      exec
      | status: 0,
        writer: nil,
        failure: exec.failure || port_failure(reason),
        pending: :queue.new(),
        pending_bytes: 0
    }

    flush(%{state | ports: Map.delete(state.ports, port)}, exec)
  end

  # Writing input to a command that exited or closed its standard input fails
  # with EPIPE, and the port closes without reporting the exit status.
  defp port_failure(:epipe), do: "command stopped reading its input; exit status unknown"
  defp port_failure(reason), do: "command port failed: #{inspect(reason)}"

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
    for {_id, %{status: nil} = exec} <- state.execs do
      kill_group(exec, :kill)
      stop_writer(exec)
    end

    :ok
  end

  defp kill_group(%{os_pid: os_pid}, signal) do
    case Command.kill_group(os_pid, signal) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "tackle exec-server cannot signal commands: " <> reason)
    end
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

  defp send_message(%{io: io}, message) do
    Port.command(io, Protocol.encode(message))
    :ok
  end
end
