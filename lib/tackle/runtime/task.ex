defmodule Tackle.Runtime.Task do
  @moduledoc """
  Supervised turn task under a scope's `WorkSupervisor`.

  `Tackle.Lib.Loop` is synchronous and must never run inside the agent GenServer.
  This helper starts it as a temporary dynamic child of a `DynamicSupervisor`,
  reports a correlated terminal result to the owner, and lets the owner monitor
  crashes separately from normal library settlement.
  """

  @default_shutdown 5_000

  @enforce_keys [:pid, :ref, :monitor]
  defstruct [:pid, :ref, :monitor, :supervisor]

  @type t :: %__MODULE__{
          pid: pid(),
          ref: reference(),
          monitor: reference(),
          supervisor: GenServer.server() | nil
        }

  @doc """
  Starts `fun` as a temporary child of `supervisor`.

  The result is delivered to `owner` (default: the caller) as `{ref, result}`.
  The caller also receives `{:DOWN, monitor, :process, pid, reason}` on crash.
  """
  @spec start(GenServer.server(), (-> term()), keyword()) :: {:ok, t()} | {:error, term()}
  def start(supervisor, fun, opts \\ []) when is_function(fun, 0) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    spec = %{
      id: {__MODULE__, ref},
      start: {__MODULE__, :start_link, [owner, ref, fun]},
      restart: :temporary,
      shutdown: Keyword.get(opts, :shutdown, @default_shutdown),
      type: :worker
    }

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} ->
        {:ok,
         %__MODULE__{pid: pid, ref: ref, monitor: Process.monitor(pid), supervisor: supervisor}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  def start_link(owner, ref, fun) do
    Task.start_link(fn -> send(owner, {ref, fun.()}) end)
  end

  @doc """
  Stops a task with a bounded forced shutdown.

  Cooperative code gets `timeout` to observe cancellation; a task that ignores
  it is killed so scope cleanup always completes.
  """
  @spec shutdown(t() | nil, timeout()) :: :ok
  def shutdown(nil, _timeout), do: :ok

  def shutdown(%__MODULE__{pid: pid, monitor: monitor}, timeout) do
    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
      await_down(pid, monitor, timeout)
    else
      Process.demonitor(monitor, [:flush])
      :ok
    end
  end

  defp await_down(pid, monitor, timeout) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          @default_shutdown -> :ok
        end
    end
  end
end
