defmodule Tackle.AgentService.Call do
  @moduledoc false

  # One model call of an agent service: an unlinked task under the service's
  # `Task.Supervisor`, so a slow or crashing request never blocks or kills the
  # service, and a timer that reaps a request ignoring its adapter's receive
  # timeout. The service passes every message it does not handle itself to
  # `match/2`, which settles the call on its reply, crash, or timeout.

  @grace_ms 5_000

  @enforce_keys [:task, :timer, :meta]
  defstruct [:task, :timer, :meta]

  @typedoc "A running call and the service's data about it, such as the run it describes."
  @type t :: %__MODULE__{task: Task.t(), timer: reference(), meta: term()}

  @doc """
  Runs `fun` as an unlinked task under `supervisor`.

  `timeout` is the request's receive timeout in milliseconds; the call is
  reaped after it and a grace no longer than the timeout itself.
  """
  @spec start(Supervisor.supervisor(), (-> term()), pos_integer(), term()) ::
          {:ok, t()} | {:error, {:task_supervisor_unavailable, term()}}
  def start(supervisor, fun, timeout, meta) when is_integer(timeout) and timeout > 0 do
    task = Task.Supervisor.async_nolink(supervisor, fun)
    timer = Process.send_after(self(), {__MODULE__, task.ref}, timeout + min(timeout, @grace_ms))
    {:ok, %__MODULE__{task: task, timer: timer, meta: meta}}
  catch
    :exit, reason -> {:error, {:task_supervisor_unavailable, reason}}
  end

  @doc """
  Settles `call` when `message` is its reply, its task's exit, or its
  timeout: returns the task's result, `{:error, {:crashed, reason}}`, or
  `{:error, :timeout}` after killing the task (a result or exit that arrived
  just before the timeout is handled still counts). Other messages and a `nil`
  call return `:error`.
  """
  @spec match(t() | nil, term()) :: {:ok, term()} | :error
  def match(%__MODULE__{task: %Task{ref: ref}} = call, {ref, result}) do
    Process.demonitor(ref, [:flush])
    settled(call, result)
  end

  def match(%__MODULE__{task: %Task{ref: ref}} = call, {:DOWN, ref, :process, _pid, reason}),
    do: settled(call, {:error, {:crashed, reason}})

  def match(%__MODULE__{task: %Task{ref: ref} = task} = call, {__MODULE__, ref}) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> settled(call, result)
      {:exit, reason} -> settled(call, {:error, {:crashed, reason}})
      nil -> settled(call, {:error, :timeout})
    end
  end

  def match(_call, _message), do: :error

  defp settled(call, result) do
    Process.cancel_timer(call.timer)
    {:ok, result}
  end
end
