defmodule Tackle.Exec.Command do
  @moduledoc """
  Process primitives shared by the jailed exec-server and local executors.

  `open/3` spawns a command as a port owned by the calling process. The runtime
  starts each port child in its own session and process group, so
  `kill_group/2` reaches everything the command started.
  """

  @doc """
  Starts `argv` with standard error merged into standard output.

  `argv[0]` is resolved against `PATH` from `env` when present, otherwise the
  current environment. `env` entries are added to the inherited environment.

  The OS process ID is `nil` when the command finished before it could be
  read; its output and exit status are still delivered to the caller.
  """
  @spec open([String.t()], Path.t(), [{String.t(), String.t()}]) ::
          {:ok, port(), pos_integer() | nil} | {:error, atom() | String.t()}
  def open([command | args], cwd, env) do
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
        nil -> {:ok, port, nil}
      end
    end
  rescue
    error in ErlangError -> {:error, port_error(error)}
  end

  @doc """
  Sends `SIGTERM` or `SIGKILL` to the process group led by `os_pid`.

  A `nil` process ID, from a command that already finished, is ignored.
  """
  @spec kill_group(pos_integer() | nil, :term | :kill) :: :ok | {:error, String.t()}
  def kill_group(nil, _signal), do: :ok

  def kill_group(os_pid, signal) when is_integer(os_pid) and signal in [:term, :kill] do
    name = if signal == :kill, do: "KILL", else: "TERM"

    case System.find_executable("kill") do
      nil ->
        {:error, "kill was not found on PATH"}

      kill ->
        System.cmd(kill, ["-s", name, "--", "-#{os_pid}"], stderr_to_stdout: true)
        :ok
    end
  end

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

  defp port_error(%ErlangError{original: reason}) when is_atom(reason), do: reason
  defp port_error(error), do: Exception.message(error)
end
