defmodule Tackle.Review.Pool do
  @moduledoc """
  Bounded parallel work queue for the review stages.

  `run/5` runs `fun` on every job with at most `limit` jobs in flight, each
  in a task linked to the caller. Results are folded into an accumulator by
  `:on_result`, which may also enqueue more jobs, so one stage can feed the
  next while it is still running (the review starts verifying a detector
  batch's findings while other batches are still being reviewed). Jobs start
  in queue order; enqueued jobs go to the back. `map/4` is the plain bounded
  parallel map on top of it.

  A raising `fun` produces `{:error, {:crashed, message}}` for its job
  rather than failing the queue.

  The queue stops early, shutting down the tasks still running, when the
  `:cancellation` signal is cancelled or a result satisfies `:cancelled?`.
  A stage's delegated runs are owned by these tasks, so shutting them down
  cancels the runs.

  Callbacks run in the calling process, one at a time, so events they emit
  are ordered.
  """

  alias Tackle.Lib.Cancellation

  @poll_ms 50

  @typedoc """
  Options of `run/5`:

    * `:cancellation` - a `Tackle.Lib.Cancellation` signal checked while
      waiting;
    * `:cancelled?` - `fn result -> boolean end`; a matching result cancels
      the queue (default: never);
    * `:on_start` - `fn job, acc -> acc end`, called when a job starts;
    * `:on_result` - `fn job, result, acc -> {new_jobs, acc} end`, called
      when a job finishes; `new_jobs` are enqueued.
  """
  @type run_option ::
          {:cancellation, Cancellation.signal() | nil}
          | {:cancelled?, (term() -> boolean())}
          | {:on_start, (term(), term() -> term())}
          | {:on_result, (term(), term(), term() -> {[term()], term()})}

  @typedoc """
  Options of `map/4`: `:cancellation` and `:cancelled?` as for `run/5`,
  `:on_start` as `fn item -> any end`, and `:on_result` as
  `fn item, result -> any end`.
  """
  @type option ::
          {:cancellation, Cancellation.signal() | nil}
          | {:cancelled?, (term() -> boolean())}
          | {:on_start, (term() -> any())}
          | {:on_result, (term(), term() -> any())}

  @doc "Runs a work queue (see the module documentation) and returns the final accumulator."
  @spec run([job], pos_integer(), (job -> term()), acc, [run_option()]) ::
          {:ok, acc} | {:error, :cancelled}
        when job: term(), acc: term()
  def run(jobs, limit, fun, acc, opts \\ [])
      when is_list(jobs) and is_integer(limit) and limit > 0 and is_function(fun, 1) do
    ctx = %{
      limit: limit,
      fun: fun,
      signal: Keyword.get(opts, :cancellation),
      cancelled?: Keyword.get(opts, :cancelled?, fn _result -> false end),
      on_start: Keyword.get(opts, :on_start, fn _job, acc -> acc end),
      on_result: Keyword.get(opts, :on_result, fn _job, _result, acc -> {[], acc} end)
    }

    loop(:queue.from_list(jobs), %{}, acc, ctx)
  end

  @doc "Maps `fun` over `items`, returning the results in input order."
  @spec map([item], pos_integer(), (item -> result), [option()]) ::
          {:ok, [result]} | {:error, :cancelled}
        when item: term(), result: term()
  def map(items, limit, fun, opts \\ [])
      when is_list(items) and is_integer(limit) and limit > 0 and is_function(fun, 1) do
    on_start = Keyword.get(opts, :on_start, fn _item -> :ok end)
    on_result = Keyword.get(opts, :on_result, fn _item, _result -> :ok end)

    run_opts = [
      cancellation: Keyword.get(opts, :cancellation),
      cancelled?: Keyword.get(opts, :cancelled?, fn _result -> false end),
      on_start: fn {item, _index}, results ->
        on_start.(item)
        results
      end,
      on_result: fn {item, index}, result, results ->
        on_result.(item, result)
        {[], Map.put(results, index, result)}
      end
    ]

    jobs = Enum.with_index(items)

    with {:ok, results} <- run(jobs, limit, fn {item, _index} -> fun.(item) end, %{}, run_opts) do
      {:ok, Enum.map(0..(length(items) - 1)//1, &Map.fetch!(results, &1))}
    end
  end

  defp loop(queue, running, acc, ctx) do
    cond do
      Cancellation.cancelled?(ctx.signal) ->
        shutdown(running)

      map_size(running) < ctx.limit and not :queue.is_empty(queue) ->
        {{:value, job}, queue} = :queue.out(queue)
        acc = ctx.on_start.(job, acc)
        task = Task.async(fn -> safely(ctx.fun, job) end)
        loop(queue, Map.put(running, task.ref, {task, job}), acc, ctx)

      map_size(running) == 0 ->
        {:ok, acc}

      true ->
        await(queue, running, acc, ctx)
    end
  end

  defp await(queue, running, acc, ctx) do
    receive do
      {ref, result} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        {{_task, job}, running} = Map.pop(running, ref)

        if ctx.cancelled?.(result) do
          ctx.on_result.(job, result, acc)
          shutdown(running)
        else
          finish(job, result, queue, running, acc, ctx)
        end

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        {{_task, job}, running} = Map.pop(running, ref)
        finish(job, {:error, {:crashed, inspect(reason)}}, queue, running, acc, ctx)
    after
      poll_timeout(ctx.signal) -> loop(queue, running, acc, ctx)
    end
  end

  defp finish(job, result, queue, running, acc, ctx) do
    {jobs, acc} = ctx.on_result.(job, result, acc)
    queue = Enum.reduce(jobs, queue, &:queue.in/2)
    loop(queue, running, acc, ctx)
  end

  defp poll_timeout(nil), do: :infinity
  defp poll_timeout(_signal), do: @poll_ms

  defp shutdown(running) do
    Enum.each(running, fn {_ref, {task, _job}} -> Task.shutdown(task, :brutal_kill) end)
    {:error, :cancelled}
  end

  defp safely(fun, job) do
    fun.(job)
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:crashed, Exception.format_banner(kind, reason)}}
  end
end
