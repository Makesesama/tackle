defmodule Tackle.Lib.Loop.Batch do
  @moduledoc false

  # Runs the jobs of one concurrent tool batch for `Tackle.Lib.Loop.Tools`,
  # each in a task under the run's `:tool_supervisor`, and returns their
  # settlements keyed by each job's position in `jobs`. The caller commits
  # them in call order and stays the only writer of the transcript; the jobs
  # carry only their execution inputs, never the agent state. Only the calling
  # (loop) process emits events: `tool_execution_end` as each job settles,
  # which may be out of call order.
  #
  # The tasks are polled every `@poll_ms`, and the run's cancellation is
  # checked between polls. Every task ends before `run/3` returns:
  #
  #   * On cancellation the tools have already observed the turn signal
  #     through their call signals. Pending tasks get `@grace_ms` in total to
  #     settle, so a tool such as `bash` can stop its OS processes; what
  #     settles is kept, the rest are killed. A killed call has no settlement
  #     and no `tool_execution_end`: the loop settles it as interrupted, with
  #     its `tool_error`, when the turn ends.
  #   * A task that exits instead of settling (for example on an exit signal
  #     from a port it is linked to) settles as crashed.
  #   * A job whose task cannot be started (the supervisor is down or at its
  #     `:max_children`) settles as crashed together with every later job;
  #     the tasks started before it run on and are awaited.
  #
  # Tasks are not linked to the caller, so an exit signal a tool receives
  # cannot take the loop down. Instead each task starts a watchdog that
  # monitors the caller and the task: if the caller goes down (it crashed or
  # its host killed it), the watchdog cancels the call's signal, gives the
  # tool `@grace_ms` to settle, kills it otherwise, and deletes the call's
  # signal. The watchdog ends with its task.
  #
  # Each job's call signal is deleted once the batch is done with it, whether
  # the call settled, crashed, was killed, or never started.

  require Logger

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Loop.Job
  alias Tackle.Lib.Loop.Run
  alias Tackle.Lib.Tool.Error
  alias Tackle.Lib.Tool.Result

  @poll_ms 100
  @grace_ms 2_000

  @type settlement :: {:ok, Result.t()} | {:error, Error.t()}
  @type settlements :: %{non_neg_integer() => settlement()}

  # A started job: its position in the batch, the job, and its task.
  @typep entry :: {non_neg_integer(), Job.t(), Task.t()}

  @doc """
  Settles `jobs` with `settle` in tasks under `run.tool_supervisor`.

  Returns the settlements by job position and `:cancelled` when the run was
  cancelled before every job settled, `:ok` otherwise.
  """
  @spec run([Job.t()], Run.t(), (Job.t() -> settlement())) :: {settlements(), :ok | :cancelled}
  def run(jobs, %Run{} = run, settle) when is_list(jobs) and is_function(settle, 1) do
    {pending, settlements} = start(Enum.with_index(jobs), run, settle, [])
    result = await(pending, settlements, run)
    Enum.each(jobs, &Cancellation.delete(&1.call_signal))
    result
  end

  # ── Starting ──────────────────────────────────────────────────────────

  defp start([], _run, _settle, pending), do: {Enum.reverse(pending), %{}}

  defp start([{job, index} | rest] = unstarted, run, settle, pending) do
    case start_task(job, run.tool_supervisor, settle) do
      {:ok, task} ->
        start(rest, run, settle, [{index, job, task} | pending])

      {:error, kind, reason} ->
        Logger.error(fn ->
          [
            "Could not start tool task for ",
            inspect(job.call.name),
            ": ",
            Exception.format_banner(kind, reason)
          ]
        end)

        settlements =
          Map.new(unstarted, fn {job, index} ->
            {index, ended({:error, Error.crashed(job.call, kind, reason)}, run)}
          end)

        {Enum.reverse(pending), settlements}
    end
  end

  defp start_task(%Job{} = job, supervisor, settle) do
    caller = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :proc_lib.set_label("tool:#{job.call.name}")
        watch(caller, job.call_signal)
        settle.(job)
      end)

    {:ok, task}
  catch
    kind, reason -> {:error, kind, reason}
  end

  # ── Awaiting ──────────────────────────────────────────────────────────

  defp await([], settlements, _run), do: {settlements, :ok}

  defp await(pending, settlements, run) do
    {pending, settlements} = collect(pending, settlements, run, @poll_ms)

    cond do
      pending == [] -> {settlements, :ok}
      Run.cancelled?(run) -> {stop(pending, settlements, run), :cancelled}
      true -> await(pending, settlements, run)
    end
  end

  # Waits up to `timeout` in total for the pending tasks and records what
  # settled. Returns the tasks still pending and the settlements.
  @spec collect([entry()], settlements(), Run.t(), timeout()) :: {[entry()], settlements()}
  defp collect(pending, settlements, run, timeout) do
    replies =
      pending
      |> Enum.map(fn {_index, _job, task} -> task end)
      |> Task.yield_many(timeout)

    {left, settlements} =
      pending
      |> Enum.zip(replies)
      |> Enum.reduce({[], settlements}, fn
        {entry, {_task, nil}}, {left, acc} ->
          {[entry | left], acc}

        {{index, job, _task}, {_, reply}}, {left, acc} ->
          {left, Map.put(acc, index, settled(job, reply, run))}
      end)

    {Enum.reverse(left), settlements}
  end

  # The cancelled batch's tasks get one grace period, not one each; a task
  # whose reply races the kill still keeps it.
  defp stop(pending, settlements, run) do
    {pending, settlements} = collect(pending, settlements, run, @grace_ms)

    Enum.reduce(pending, settlements, fn {index, job, task}, acc ->
      case Task.shutdown(task, :brutal_kill) do
        nil -> acc
        reply -> Map.put(acc, index, settled(job, reply, run))
      end
    end)
  end

  defp settled(_job, {:ok, settlement}, run), do: ended(settlement, run)

  defp settled(%Job{call: call}, {:exit, reason}, run) do
    Logger.error("Tool task for #{call.name} exited: #{inspect(reason)}")
    ended({:error, Error.crashed(call, :exit, reason)}, run)
  end

  defp ended(settlement, run) do
    Run.emit(run, Event.tool_execution_end(settlement))
    settlement
  end

  # ── Watchdog ──────────────────────────────────────────────────────────

  # Runs beside one task until the task ends, holding only the call's signal.
  # It monitors rather than links, so it neither dies with a killed task
  # before cleaning up nor takes the task down if it fails itself.
  defp watch(caller, call_signal) do
    task = self()

    spawn(fn ->
      task_ref = Process.monitor(task)
      caller_ref = Process.monitor(caller)

      receive do
        {:DOWN, ^task_ref, :process, _pid, _reason} ->
          :ok

        {:DOWN, ^caller_ref, :process, _pid, _reason} ->
          stop_orphan(task, task_ref, call_signal)
      end
    end)
  end

  defp stop_orphan(task, task_ref, call_signal) do
    best_effort(fn -> if call_signal, do: Cancellation.cancel(call_signal, :caller_down) end)

    receive do
      {:DOWN, ^task_ref, :process, _pid, _reason} -> :ok
    after
      @grace_ms ->
        Process.exit(task, :kill)
        receive do: ({:DOWN, ^task_ref, :process, _pid, _reason} -> :ok)
    end

    best_effort(fn -> Cancellation.delete(call_signal) end)
  end

  # The cancellation store may be gone (its application stopping); the task
  # must still be stopped.
  defp best_effort(fun) do
    fun.()
  catch
    _kind, _reason -> :ok
  end
end
