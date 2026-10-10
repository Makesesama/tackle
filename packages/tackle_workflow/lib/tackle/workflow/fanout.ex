defmodule Tackle.Workflow.Fanout do
  @moduledoc """
  Bounded, work-conserving fan-out over delegated agent runs.

  `map/5` drives one callback over `count` items regardless of what those items
  are: the callback builds one request per item, the fanout starts that run
  through `Tackle.Runtime`, and the run's outcome is recorded against the
  item's index. Every item ends with exactly one result, in input order.

  At most `limit` runs are in flight. One short-lived watcher awaits each run
  and hands its settlement back to the dispatcher, so a settled run's slot is
  reused by the next item instead of waiting behind a slow straggler.

  An item failure never aborts the batch: the callback raising, the callback
  refusing the item on policy, the runtime refusing the spawn, and an
  uncollectable outcome are all reported as `{:error, reason}` for that item,
  and the caller decides the failure policy. A callback that refuses an item on
  policy returns `{:error, {:spawn_error, reason}, acc}` — or
  `{:error, {:budget_exhausted, reason}, acc}` when the caller's budget is used
  up — to say the item was refused rather than malformed; any other error is
  reported as a malformed request. Runs are never retried, and a run that
  settles is consumed exactly once.

  The runtime refuses rather than queues when a scope is at capacity, and a
  settled run's child slot is released a moment after its outcome, so a refusal
  is not final. Every refusal waits `@capacity_poll_ms` for one of the batch's
  own runs to settle — a settlement frees capacity and buys the batch more
  patience — and then retries. A batch that makes no progress for
  `@capacity_grace_ms` reports the item as `{:capacity, reason}` rather than
  waiting forever, since capacity a stalled batch cannot free may only clear
  much later.

  Watchers are linked to the calling process: killing it kills them, and the
  runtime cancels every run whose requester is gone. A watcher that dies for a
  reason `await/1` cannot report therefore fails the whole batch rather than
  hanging it — deliberately, so a broken handshake is loud. The wait for a
  settlement has no timeout of its own: runs settle within their own idle
  window, and a batch is otherwise bounded by the workflow's deadline.
  """

  alias Tackle.Runtime
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.RunRef

  # Mirrors the transient capacity refusals `Tackle.AgentScope.Coordinator`
  # returns from `admit/4`; a new capacity reason there lands here as a permanent
  # `spawn_error`, so keep this list in step with the coordinator.
  @capacity_reasons [:max_children_per_agent, :max_agents_per_fleet]
  # How long a batch waits for capacity without making progress before it
  # reports the item as refused, and how often it retries while waiting.
  @capacity_poll_ms 10
  @capacity_grace_ms 250

  @typedoc """
  Profile and prompt of one item's delegated run, optionally with extra
  `Tackle.Runtime.request_agent/4` options for that item alone, such as
  `model: "provider/model"`.
  """
  @type request :: {String.t(), String.t()} | {String.t(), String.t(), keyword()}

  @typedoc """
  Why one item has no outcome.

    * `{:callback_error, reason}` — the caller's callback raised or returned
      something other than a request.
    * `{:spawn_error, reason}` — the runtime refused the delegated run for a
      policy reason, such as an unknown profile or spawn depth.
    * `{:capacity, reason}` — the scope stayed at its concurrency limit for as
      long as the batch was willing to wait for a free slot.
    * `{:unavailable, reason}` — the run settled but its outcome could not be
      collected.
    * `{:budget_exhausted, reason}` — the callback refused the item because the
      caller's budget is used up.
  """
  @type item_error ::
          {:callback_error, term()}
          | {:spawn_error, term()}
          | {:capacity, term()}
          | {:unavailable, term()}
          | {:budget_exhausted, term()}

  @typedoc """
  Terminal state of one item. A collected outcome carries the `run_id` of the
  run it settled, so a caller can correlate it with that run's events.
  """
  @type item_result :: {:ok, Outcome.t()} | {:error, item_error()}

  @typedoc """
  Builds one item's request, threading the caller's accumulator.

  Returns that item's `{profile, prompt}` or `{profile, prompt, opts}`, or
  `{:error, reason, acc}` where a `{:spawn_error, reason}` or
  `{:budget_exhausted, reason}` refusal is reported as such instead of as a
  malformed request.
  """
  @type request_builder(acc) ::
          (pos_integer(), acc -> {:ok, request(), acc} | {:error, term(), acc})

  @typedoc """
  Optional observation hooks for `map/6`. They observe the batch and cannot
  change its results, but they run in the dispatcher and are not isolated: a
  hook that raises fails the batch, so callers wrap anything fallible.

    * `:request_opts` — `fn profile -> keyword end`, extra
      `Tackle.Runtime.request_agent/4` options for one item's run, such as an
      event callback;
    * `:on_started` — `fn index, run_ref, request -> any end`, called when an
      item's run is admitted;
    * `:on_settled` — `fn index, result, started -> any end`, called once per
      item when its result is recorded, where `started` is the item's
      `{run_ref, request}` or `nil` when it never got a run.
  """
  @type option ::
          {:request_opts, (String.t() -> keyword())}
          | {:on_started, (pos_integer(), RunRef.t(), request() -> any())}
          | {:on_settled, (pos_integer(), item_result(), {RunRef.t(), request()} | nil -> any())}

  @doc """
  Runs `count` items, at most `limit` at a time, and collects one result each.

  `build_request.(index, acc)` is called exactly once per item, in index order,
  and returns that item's `t:request/0`. Returns the item results in index
  order together with the final accumulator. `t:option/0` lists the hooks a
  caller may pass to observe the batch.
  """
  @spec map(Handle.t(), non_neg_integer(), pos_integer(), acc, request_builder(acc), [option()]) ::
          {[{pos_integer(), item_result()}], acc}
        when acc: term()
  def map(%Handle{} = handle, count, limit, acc, build_request, opts \\ [])
      when is_integer(count) and count >= 0 and is_integer(limit) and limit >= 1 and
             is_function(build_request, 2) and is_list(opts) do
    ctx = %{
      handle: handle,
      count: count,
      limit: limit,
      build_request: build_request,
      request_opts: Keyword.get(opts, :request_opts, fn _profile -> [] end),
      on_started: Keyword.get(opts, :on_started, fn _index, _run_ref, _request -> :ok end),
      on_settled: Keyword.get(opts, :on_settled, fn _index, _result, _started -> :ok end),
      ref: make_ref()
    }

    {results, acc} = pump(1, ctx, %{}, %{}, acc)
    {Enum.map(1..count//1, &{&1, Map.fetch!(results, &1)}), acc}
  end

  # Dispatch loop -----------------------------------------------------------------

  defp pump(index, %{count: count} = ctx, in_flight, results, acc) when index > count do
    drain(ctx, in_flight, results, acc)
  end

  defp pump(index, ctx, in_flight, results, acc) do
    {in_flight, results, acc} = open_slot(ctx, in_flight, results, acc)

    case ctx.build_request.(index, acc) do
      {:error, reason, acc} ->
        results = record(ctx, results, index, {:error, item_error(reason)}, nil)
        pump(index + 1, ctx, in_flight, results, acc)

      {:ok, request, acc} ->
        dispatch(index, request, ctx, in_flight, results, acc)
    end
  end

  # A caller that already decided the item was refused on policy passes that
  # classification through; anything else is a malformed request.
  defp item_error({:spawn_error, _reason} = refusal), do: refusal
  defp item_error({:budget_exhausted, _reason} = refusal), do: refusal
  defp item_error(reason), do: {:callback_error, reason}

  # Starts one item's run, or records why it could not start.
  defp dispatch(index, request, ctx, in_flight, results, acc) do
    case await_capacity(request, ctx, in_flight, results, acc, capacity_grace()) do
      {:ok, run_ref, in_flight, results, acc} ->
        start(index, run_ref, request, ctx, in_flight, results, acc)

      {:error, item_error, in_flight, results, acc} ->
        results = record(ctx, results, index, {:error, item_error}, nil)
        pump(index + 1, ctx, in_flight, results, acc)
    end
  end

  defp start(index, run_ref, request, ctx, in_flight, results, acc) do
    watch(ctx.ref, index, run_ref)
    ctx.on_started.(index, run_ref, request)
    pump(index + 1, ctx, Map.put(in_flight, index, {run_ref, request}), results, acc)
  end

  # Every item's result is recorded exactly once, here, so an observer sees each
  # item settle exactly once too.
  defp record(ctx, results, index, result, started) do
    ctx.on_settled.(index, result, started)
    Map.put(results, index, result)
  end

  # Admits one item's run, waiting out the runtime's capacity refusals.
  #
  # The runtime refuses rather than queues at capacity, and it releases a
  # settled run's child slot a moment after publishing its outcome, so a refusal
  # does not mean the item cannot run. Each refusal waits `@capacity_poll_ms` for
  # one of the batch's own runs to settle — that both frees capacity and buys the
  # batch more patience — and retries. A batch that makes no progress for
  # `@capacity_grace_ms` reports the item instead of waiting forever, since
  # capacity a stalled batch cannot free may only clear much later.
  defp await_capacity(request, ctx, in_flight, results, acc, deadline) do
    case admit(ctx, request) do
      {:ok, run_ref} ->
        {:ok, run_ref, in_flight, results, acc}

      {:capacity, reason} ->
        case settle_within(ctx, in_flight, results, acc, @capacity_poll_ms) do
          {:settled, in_flight, results, acc} ->
            await_capacity(request, ctx, in_flight, results, acc, capacity_grace())

          :idle ->
            if System.monotonic_time(:millisecond) < deadline do
              await_capacity(request, ctx, in_flight, results, acc, deadline)
            else
              {:error, {:capacity, {:rejected, reason}}, in_flight, results, acc}
            end
        end

      {:error, reason} ->
        {:error, {:spawn_error, reason}, in_flight, results, acc}
    end
  end

  # A capacity refusal restarts the wait: a release that lags its settlement by
  # microseconds is the common case, and a batch that keeps waiting without
  # seeing one gives up for this item.
  defp capacity_grace, do: System.monotonic_time(:millisecond) + @capacity_grace_ms

  defp admit(ctx, {profile, prompt}), do: admit(ctx, {profile, prompt, []})

  defp admit(%{handle: handle, request_opts: request_opts}, {profile, prompt, item_opts}) do
    opts = Keyword.merge(request_opts.(profile), item_opts)

    case Runtime.request_agent(handle, profile, prompt, opts) do
      {:ok, %RunRef{} = run_ref} -> {:ok, run_ref}
      {:error, {:rejected, reason}} when reason in @capacity_reasons -> {:capacity, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # Waits until the window has room for another run. `in_flight` maps the
  # indices of the runs the window is currently spending to their run and request.
  defp open_slot(%{limit: limit}, in_flight, results, acc) when map_size(in_flight) < limit,
    do: {in_flight, results, acc}

  defp open_slot(ctx, in_flight, results, acc),
    do: await_settled(ctx, in_flight, results, acc)

  defp drain(_ctx, in_flight, results, acc) when map_size(in_flight) == 0,
    do: {results, acc}

  defp drain(ctx, in_flight, results, acc) do
    {in_flight, results, acc} = await_settled(ctx, in_flight, results, acc)
    drain(ctx, in_flight, results, acc)
  end

  defp await_settled(ctx, in_flight, results, acc) do
    {:settled, in_flight, results, acc} = settle_within(ctx, in_flight, results, acc, :infinity)
    {in_flight, results, acc}
  end

  # Gives the dispatcher a way out when no run settles: the caller decides what
  # to do with a window that stays empty.
  defp settle_within(%{ref: ref} = ctx, in_flight, results, acc, timeout) do
    receive do
      {:fanout_settled, ^ref, index, result} ->
        {started, in_flight} = Map.pop(in_flight, index)
        {:settled, in_flight, record(ctx, results, index, result, started), acc}
    after
      timeout -> :idle
    end
  end

  # Runs --------------------------------------------------------------------------

  # A run settles once and exactly one process may consume it, so each run gets
  # its own watcher. Watchers are linked to the dispatcher: if it is killed, so
  # are they, and the request helpers cancel the runs behind them.
  defp watch(ref, index, %RunRef{} = run_ref) do
    owner = self()

    spawn_link(fn -> send(owner, {:fanout_settled, ref, index, await(run_ref)}) end)

    :ok
  end

  defp await(%RunRef{} = run_ref) do
    case Runtime.await(run_ref, :infinity) do
      %Outcome{} = outcome -> {:ok, %{outcome | run_id: run_ref.run_id}}
      {:error, reason} -> {:error, {:unavailable, reason}}
    end
  rescue
    error -> {:error, {:unavailable, {:await_crashed, Exception.message(error)}}}
  catch
    kind, reason -> {:error, {:unavailable, {kind, reason}}}
  end
end
