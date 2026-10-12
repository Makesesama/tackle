defmodule Tackle.Review.Pool do
  @moduledoc """
  Bounded parallel map for the review stages.

  Runs `fun` on every item with at most `limit` items in flight, each in a
  task linked to the caller, and returns the results in input order. A
  raising `fun` produces `{:error, {:crashed, message}}` for its item rather
  than failing the batch.

  The batch stops early, shutting down the tasks still running, when the
  `:cancellation` signal is cancelled or a result satisfies `:cancelled?`.
  A stage's delegated runs are owned by these tasks, so shutting them down
  cancels the runs.

  Callbacks run in the calling process, one at a time, so events they emit
  are ordered.
  """

  alias Tackle.Lib.Cancellation

  @poll_ms 50

  @typedoc """
  Options:

    * `:cancellation` - a `Tackle.Lib.Cancellation` signal checked while
      waiting;
    * `:cancelled?` - `fn result -> boolean end`; a matching result cancels
      the batch (default: never);
    * `:on_start` - `fn item -> any end`, called when an item starts;
    * `:on_result` - `fn item, result -> any end`, called when it finishes.
  """
  @type option ::
          {:cancellation, Cancellation.signal() | nil}
          | {:cancelled?, (term() -> boolean())}
          | {:on_start, (term() -> any())}
          | {:on_result, (term(), term() -> any())}

  @doc "Maps `fun` over `items` (see the module documentation)."
  @spec map([item], pos_integer(), (item -> result), [option()]) ::
          {:ok, [result]} | {:error, :cancelled}
        when item: term(), result: term()
  def map(items, limit, fun, opts \\ [])
      when is_list(items) and is_integer(limit) and limit > 0 and is_function(fun, 1) do
    ctx = %{
      limit: limit,
      fun: fun,
      signal: Keyword.get(opts, :cancellation),
      cancelled?: Keyword.get(opts, :cancelled?, fn _result -> false end),
      on_start: Keyword.get(opts, :on_start, fn _item -> :ok end),
      on_result: Keyword.get(opts, :on_result, fn _item, _result -> :ok end)
    }

    loop(Enum.with_index(items), %{}, %{}, ctx)
  end

  defp loop([], running, results, _ctx) when map_size(running) == 0 do
    {:ok, results |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
  end

  defp loop(pending, running, results, ctx) do
    cond do
      Cancellation.cancelled?(ctx.signal) ->
        shutdown(running)

      pending != [] and map_size(running) < ctx.limit ->
        [{item, index} | pending] = pending
        ctx.on_start.(item)
        task = Task.async(fn -> safely(ctx.fun, item) end)
        loop(pending, Map.put(running, task.ref, {task, item, index}), results, ctx)

      true ->
        await(pending, running, results, ctx)
    end
  end

  defp await(pending, running, results, ctx) do
    receive do
      {ref, result} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        {{_task, item, index}, running} = Map.pop(running, ref)
        ctx.on_result.(item, result)

        if ctx.cancelled?.(result),
          do: shutdown(running),
          else: loop(pending, running, Map.put(results, index, result), ctx)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        {{_task, item, index}, running} = Map.pop(running, ref)
        result = {:error, {:crashed, inspect(reason)}}
        ctx.on_result.(item, result)
        loop(pending, running, Map.put(results, index, result), ctx)
    after
      poll_timeout(ctx.signal) -> loop(pending, running, results, ctx)
    end
  end

  defp poll_timeout(nil), do: :infinity
  defp poll_timeout(_signal), do: @poll_ms

  defp shutdown(running) do
    Enum.each(running, fn {_ref, {task, _item, _index}} -> Task.shutdown(task, :brutal_kill) end)
    {:error, :cancelled}
  end

  defp safely(fun, item) do
    fun.(item)
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:crashed, Exception.format_banner(kind, reason)}}
  end
end
