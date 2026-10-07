defmodule Tackle.Exec.TestSupport do
  @moduledoc false

  alias Tackle.Exec.Client

  @doc "Launcher that runs the real exec-server in a plain `erl` without a jail."
  def server_launcher, do: erl_launcher(["-s", "Elixir.Tackle.Exec.Server", "main"])

  @doc "Launcher that runs a misbehaving fake exec-server."
  def fake_launcher(mode) when is_atom(mode) do
    erl_launcher(["-s", "Elixir.Tackle.Exec.FakeServer", "main", Atom.to_string(mode)])
  end

  @doc "File that receives the standard error of test launchers."
  def stderr_log, do: Path.join(System.tmp_dir!(), "tackle_exec_test_stderr.log")

  # Like a production launcher, keep the exec-server's standard error away from
  # the host's terminal.
  defp erl_launcher(args) do
    sh = System.find_executable("sh") || raise "sh was not found on PATH"
    erl = System.find_executable("erl") || raise "erl was not found on PATH"
    elixir_ebin = Path.join(:code.lib_dir(:elixir), "ebin")
    ebin = :tackle_exec |> :code.lib_dir() |> Path.join("ebin")
    script = ~S(log=$1; shift; exec "$@" 2>>"$log")

    {sh,
     ["-c", script, "sh", stderr_log(), erl, "-noshell", "-noinput", "-pa", elixir_ebin] ++
       ["-pa", ebin | args]}
  end

  @doc "Collects a command's output, acknowledging each chunk."
  def collect(client, ref, timeout \\ 5_000, output \\ "") do
    receive do
      {:tackle_exec, ^ref, {:data, data}} ->
        Client.ack(client, ref, byte_size(data))
        collect(client, ref, timeout, output <> data)

      {:tackle_exec, ^ref, {:exit_status, status}} ->
        Process.demonitor(ref, [:flush])
        {:ok, status, output}

      {:tackle_exec, ^ref, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason, output}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:down, reason, output}
    after
      timeout -> {:timeout, output}
    end
  end

  @doc "Runs a command to completion."
  def run(client, argv, opts) do
    with {:ok, ref} <- Client.exec(client, argv, opts) do
      collect(client, ref)
    end
  end

  @doc "Waits until an OS process no longer exists."
  def wait_until_dead(os_pid, attempts \\ 100)

  def wait_until_dead(_os_pid, 0), do: false

  def wait_until_dead(os_pid, attempts) do
    if alive?(os_pid) do
      Process.sleep(20)
      wait_until_dead(os_pid, attempts - 1)
    else
      true
    end
  end

  @doc "Returns whether an OS process exists and is not a zombie."
  def alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        # The state follows the parenthesised command name.
        [_, rest] = String.split(stat, ") ", parts: 2)
        not String.starts_with?(rest, "Z")

      {:error, _reason} ->
        false
    end
  end
end
