defmodule Tackle.Workflow.API do
  @moduledoc """
  Lua API surface exposed to workflow scripts.

  Workflow scripts call these functions through the global `tackle` table:

      local run = tackle.spawn("scout", "Map the code paths for the change.")
      local outcome = tackle.await(run)
      if outcome.ok then
        return outcome.text
      end

  * `tackle.spawn(profile, prompt)` starts one delegated run through the same
    allowlisted profiles, scope limits, and admission rules as the subagent
    tool and host-defined workflows. It returns an opaque run handle
    immediately, so several spawns overlap.
  * `tackle.await(run)` blocks the script until the run settles and returns an
    outcome table with `ok`, `status`, and `text` fields. Expected failures
    (agent errors, cancellations, timeouts) are returned, never raised, so
    the workflow decides its own failure policy.
  * `tackle.parallel(items, fn, opts)` is bounded fan-out: it starts one
    delegated run per item and returns one result table per item, in input
    order. See below.
  * `tackle.cancel(run, reason)` requests cooperative cancellation of one run.
  * `tackle.log(message)` reports progress to the host's log callback.

  ## Fan-out

  `tackle.parallel(items, fn, opts)` calls `fn(item, index)` once per item of
  the `items` sequence and expects it to return that item's `profile, prompt`:

      local answers = tackle.parallel(questions, function(question, index)
        return "researcher", index .. ". " .. question
      end, {limit = 3})

      for _, answer in ipairs(answers) do
        if answer.ok then
          tackle.log(answer.text)
        end
      end

  `items` must be a sequence table numbered 1..n with no holes and no other
  keys. At most `limit` runs are in flight, and a new item starts as soon as
  any in-flight run settles, so a slow run never holds a free slot. The limit
  defaults to the scope's concurrency ceiling — the smaller of its
  `max_children_per_agent` and `max_concurrent_turns` limits — and is clamped
  to it, so a workflow cannot widen its own concurrency by asking for more.

  Every item produces exactly one table, in input order:

      { index = 2, ok = true, status = "ok", text = "..." }

  `status` is the run's outcome status — `"ok"`, `"error"`, `"cancelled"`,
  `"runtime_error"`, `"timeout"`, or `"rejected"` — or one of:

    * `"callback_error"` — `fn` raised, or returned something other than two
      strings;
    * `"spawn_error"` — the runtime refused the spawn for a policy reason, such
      as an unknown profile, a spawn-depth limit, or a scope that forbids
      delegation;
    * `"capacity"` — the scope stayed at its concurrency limit for as long as
      `tackle.parallel` waits for its own runs to free capacity. Retrying the
      item in a later call may succeed;
    * `"unavailable"` — a settled run's outcome could not be collected.

  `text` carries the answer for a successful run and the reason otherwise.
  Item failures are returned, never raised, and runs are never retried: a
  retried agent run is a second paid model call that may answer differently.
  The workflow decides what to do with a failed item.

  Argument errors raise catchable Lua errors carrying the script's source line,
  so a workflow can implement policy with `pcall`. `tackle.spawn` also raises when
  the runtime refuses a run; `tackle.parallel` reports a refusal on the item it
  belongs to instead.

  ## Profile allowlist

  A host may run a workflow with an explicit allowlist of profile names
  (`Tackle.Workflow.run/3`'s `:profiles` option, which `Tackle.Workflow.Tool`
  forwards from its session context). The allowlist bounds this API and nothing
  else: `tackle.spawn` raises, and `tackle.parallel` reports `spawn_error` on
  the item, for every profile outside it. Without an allowlist, the scope's own
  trusted profiles decide, exactly as they do for the subagent tool.
  """

  use Lua.API, scope: "tackle"

  alias Tackle.Runtime
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.RunRef
  alias Tackle.Workflow.Fanout

  @parallel_helpers :parallel_helpers
  @parallel_options ["limit"]

  # Helpers `tackle.parallel/2,3` calls inside the VM. The item and its index
  # are read in Lua so the callback receives the value the script passed in:
  # decoding an item table and re-encoding it per call would hand the callback
  # a copy with a different identity. `shape/1` reports a table that is not a
  # dense 1..n sequence, where a keyed or holey item would have no index.
  @parallel_helper_source """
  local function tackle_parallel_apply(callback, items, index)
    return callback(items[index], index)
  end

  local function tackle_parallel_shape(items)
    local count = #items
    local seen = 0

    for key in pairs(items) do
      if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then
        return count, false
      end

      seen = seen + 1
    end

    return count, seen == count
  end

  return tackle_parallel_apply, tackle_parallel_shape
  """

  @impl Lua.API
  def install(lua, _scope, _data) do
    {[apply, shape], lua} = Lua.eval!(lua, @parallel_helper_source, decode: false)

    Lua.put_private(lua, @parallel_helpers, %{
      apply: Lua.unwrap(apply),
      shape: Lua.unwrap(shape)
    })
  end

  @doc "Starts one delegated agent run and returns its opaque run handle."
  deflua spawn(profile, prompt) when is_binary(profile) and is_binary(prompt), state do
    %{handle: %Handle{} = handle} = context!(state)

    unless allowed_profile?(state, profile) do
      runtime_exception!("spawn failed: " <> profile_not_allowed(profile))
    end

    case Runtime.request_agent(handle, profile, prompt) do
      {:ok, %RunRef{} = run_ref} ->
        {encoded, state} = Lua.encode!(state, {:userdata, run_ref})
        {encoded, state}

      {:error, reason} ->
        runtime_exception!("spawn failed: #{inspect(reason)}")
    end
  end

  deflua spawn(_profile, _prompt), _state do
    runtime_exception!("tackle.spawn(profile, prompt) requires two strings")
  end

  @doc "Waits for one run and returns its outcome table."
  deflua await(run), state do
    %RunRef{} = run_ref = run_ref!(state, run)

    case Runtime.await(run_ref, :infinity) do
      %Outcome{} = outcome ->
        {encoded, state} = Lua.encode!(state, outcome_table(outcome))
        {encoded, state}

      {:error, reason} ->
        runtime_exception!("await failed: #{inspect(reason)}")
    end
  end

  @doc "Runs one delegated agent run per item, at most `limit` at a time."
  deflua(parallel(items, callback), state, do: run_parallel(items, callback, nil, state))

  deflua(parallel(items, callback, opts), state, do: run_parallel(items, callback, opts, state))

  @doc "Requests cooperative cancellation of one run."
  deflua cancel(run), state do
    %RunRef{} = run_ref = run_ref!(state, run)

    case Runtime.cancel(run_ref, :cancelled) do
      :ok -> {true, state}
      {:error, reason} -> runtime_exception!("cancel failed: #{inspect(reason)}")
    end
  end

  deflua cancel(run, reason) when is_binary(reason), state do
    %RunRef{} = run_ref = run_ref!(state, run)

    case Runtime.cancel(run_ref, reason) do
      :ok -> {true, state}
      {:error, failure} -> runtime_exception!("cancel failed: #{inspect(failure)}")
    end
  end

  @doc "Reports one progress message to the host's log callback."
  deflua log(message) when is_binary(message), state do
    %{server: server} = context!(state)
    send(server, {:workflow_log, message})
    {true, state}
  end

  deflua log(_message), _state do
    runtime_exception!("tackle.log(message) requires a string")
  end

  # Fan-out -----------------------------------------------------------------------

  defp run_parallel(items, callback, opts, state) do
    %{handle: %Handle{} = handle} = context!(state)

    unless is_lua_func(callback) or is_erl_func(callback) do
      parallel_error!("tackle.parallel(items, fn, opts?) requires a function")
    end

    limit = parallel_limit!(state, handle, opts)
    {count, state} = item_count!(state, items)

    {results, state} =
      Fanout.map(handle, count, limit, state, fn index, state ->
        item_request(state, callback, items, index)
      end)

    {encoded, state} = Lua.encode!(state, Enum.map(results, &result_table/1))
    {encoded, state}
  end

  # Invokes the script's callback for one item. The item is passed through Lua
  # untouched, so the callback sees the value the script listed.
  defp item_request(state, callback, items, index) do
    case Lua.call_function(state, helper!(state, :apply), [callback, items, index]) do
      {:ok, [profile, prompt], state} when is_binary(profile) and is_binary(prompt) ->
        if allowed_profile?(state, profile) do
          {:ok, {profile, prompt}, state}
        else
          {:error, {:spawn_error, profile_not_allowed(profile)}, state}
        end

      {:ok, results, state} ->
        {:error, "expected two strings (profile, prompt), got #{describe(results)}", state}

      {:error, exception, state} ->
        {:error, Exception.message(exception), state}
    end
  end

  # Reads the sequence's length in Lua so `#items` honours the real border, and
  # rejects a table that is not a dense 1..n sequence: a keyed or holey item
  # has no index to report a result against.
  defp item_count!(state, items) do
    with true <- is_table(items),
         {:ok, [count, true], state}
         when is_integer(count) and count >= 0 <-
           Lua.call_function(state, helper!(state, :shape), [items]) do
      {count, state}
    else
      {:error, exception, _state} ->
        parallel_error!(Exception.message(exception))

      _other ->
        parallel_error!(
          "tackle.parallel(items, fn, opts?) requires a 1..n sequence table (no holes, no keys)"
        )
    end
  end

  defp parallel_limit!(state, %Handle{} = handle, opts) do
    case requested_limit!(state, opts) do
      nil -> parallel_ceiling(handle)
      limit -> min(limit, parallel_ceiling(handle))
    end
  end

  # A workflow may not widen its own concurrency: the limits it inherited are the
  # ceiling for its fan-out too.
  defp parallel_ceiling(%Handle{limits: %Limits{} = limits}) do
    max(1, min(limits.max_children_per_agent, limits.max_concurrent_turns))
  end

  # A handle without limits carries no ceiling to honour, so serialize rather
  # than guess a concurrency.
  defp parallel_ceiling(%Handle{}), do: 1

  defp requested_limit!(_state, nil), do: nil

  defp requested_limit!(state, opts) do
    unless is_table(opts) do
      parallel_error!("tackle.parallel(items, fn, opts) requires a table of options")
    end

    options = state |> Lua.decode!(opts) |> Lua.Table.as_map()
    unknown = Map.keys(options) -- @parallel_options

    if unknown != [] do
      parallel_error!(
        "unknown tackle.parallel options: #{Enum.map_join(Enum.sort(unknown), ", ", &inspect/1)}"
      )
    end

    case Map.fetch(options, "limit") do
      :error ->
        nil

      {:ok, limit} when is_integer(limit) and limit >= 1 ->
        limit

      {:ok, limit} ->
        parallel_error!("tackle.parallel limit must be a positive integer, got #{inspect(limit)}")
    end
  end

  # Result projection -------------------------------------------------------------

  defp result_table({index, {:ok, %Outcome{} = outcome}}) do
    outcome_table(outcome) |> Map.put("index", index)
  end

  defp result_table({index, {:error, reason}}) do
    %{
      "index" => index,
      "ok" => false,
      "status" => error_status(reason),
      "text" => error_text(reason)
    }
  end

  defp error_status({:callback_error, _reason}), do: "callback_error"
  defp error_status({:spawn_error, _reason}), do: "spawn_error"
  defp error_status({:capacity, _reason}), do: "capacity"
  defp error_status({:unavailable, _reason}), do: "unavailable"

  defp error_text({:callback_error, reason}), do: reason_text(reason)
  defp error_text({:spawn_error, reason}), do: "spawn failed: #{reason_text(reason)}"
  defp error_text({:capacity, reason}), do: "spawn refused at capacity: #{reason_text(reason)}"
  defp error_text({:unavailable, reason}), do: "outcome unavailable: #{reason_text(reason)}"

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp outcome_table(%Outcome{} = outcome) do
    %{
      "ok" => Outcome.ok?(outcome),
      "status" => Atom.to_string(outcome.status),
      "text" => outcome_text(outcome)
    }
  end

  defp outcome_text(%Outcome{status: :ok} = outcome), do: Outcome.answer(outcome) || ""

  defp outcome_text(%Outcome{} = outcome), do: Outcome.message(outcome)

  # Argument and context helpers --------------------------------------------------

  # `nil` means the host left the decision to the scope's trusted profile
  # allowlist; a list is the host's explicit narrowing for workflows.
  defp allowed_profile?(state, profile) do
    %{profiles: profiles} = context!(state)
    is_nil(profiles) or profile in profiles
  end

  defp profile_not_allowed(profile) do
    "profile #{inspect(profile)} is not allowlisted for workflows"
  end

  defp run_ref!(state, run) do
    case Lua.decode!(state, run) do
      {:userdata, %RunRef{} = run_ref} -> run_ref
      _other -> runtime_exception!("expected a run handle returned by tackle.spawn")
    end
  end

  defp context!(state) do
    case Lua.get_private(state, :tackle_workflow) do
      {:ok, context} -> context
      :error -> runtime_exception!("workflow runtime context is unavailable")
    end
  end

  defp helper!(state, name) do
    case Lua.get_private(state, @parallel_helpers) do
      {:ok, %{} = helpers} -> Map.fetch!(helpers, name)
      :error -> parallel_error!("tackle.parallel is unavailable in this VM")
    end
  end

  # The other API errors are raised in the `deflua` body they belong to, so
  # `runtime_exception!/1` can name it. These checks live in helpers, so the
  # exception names `tackle.parallel(...)` explicitly.
  defp parallel_error!(message) do
    raise Lua.RuntimeException, scope: ["tackle"], function: :parallel, message: message
  end

  defp describe([]), do: "no values"

  defp describe(values) when is_list(values) do
    "(" <> Enum.map_join(values, ", ", &type_name/1) <> ")"
  end

  defp type_name(value) when is_table(value), do: "table"
  defp type_name(value) when is_userdata(value), do: "userdata"
  defp type_name(value) when is_lua_func(value) or is_erl_func(value), do: "function"
  defp type_name(nil), do: "nil"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_number(value), do: "number"
  defp type_name(_value), do: "value"
end
