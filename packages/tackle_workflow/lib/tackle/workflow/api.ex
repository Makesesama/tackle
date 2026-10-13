defmodule Tackle.Workflow.API do
  @moduledoc """
  Lua API surface exposed to workflow scripts.

  Workflow scripts call these functions through the global `tackle` table:

      local run = tackle.spawn("scout", "Map the code paths for the change.")
      local outcome = tackle.await(run)
      if outcome.ok then
        return outcome.text
      end

  * `tackle.spawn(profile, prompt, opts?)` starts one delegated run through the
    same allowlisted profiles, scope limits, and admission rules as the
    subagent tool and host-defined workflows. It returns an opaque run handle
    immediately, so several spawns overlap. See "Spawn options" for `opts`.
  * `tackle.await(run)` blocks the script until the run settles and returns an
    outcome table with `ok`, `status`, and `text` fields, plus the run facts
    described below. Expected failures (agent errors, cancellations, timeouts)
    are returned, never raised, so the workflow decides its own failure policy.
  * `tackle.parallel(items, fn, opts)` is bounded fan-out: it starts one
    delegated run per item and returns one result table per item, in input
    order. See below.
  * `tackle.cancel(run, reason)` requests cooperative cancellation of one run.
  * `tackle.classify(state, questions, opts?)` asks a host-granted decision
    model typed questions about `state`. See "Classification".
  * `tackle.budget()` returns the workflow's token accounting. See "Run facts
    and token budget".
  * `tackle.log(message)` reports progress to the host's log callback.

  ## Run facts and token budget

  Every outcome table also carries facts the harness recorded while the run
  worked, so a workflow can tell whether a run did anything without trusting
  its answer:

    * `tokens` — model tokens the run reported;
    * `tool_calls` — tool calls the run settled;
    * `failed_tool_calls` — how many of them failed.

  `tackle.budget()` returns `{used = n}` with the tokens all of the workflow's
  runs and remote classifications have reported so far, plus `limit` and
  `remaining` when the host gave the workflow a token budget
  (`Tackle.Workflow.run/3`'s `:token_budget`). Once `used` reaches `limit`,
  `tackle.spawn` and remote `tackle.classify` calls raise, and `tackle.parallel`
  reports `"budget_exhausted"` for every item it has not started yet. Runs
  already in flight finish, so a workflow can spend more than its budget by
  what those runs use — with `tackle.parallel`, up to `limit` runs at once.
  The budget belongs to one workflow: it limits starting runs, not a session's
  total spend. `Tackle.Workflow.Meter` documents what is counted.

  ## Spawn options

  `opts` is an optional table. Its only key is `model`, a `"provider/model"`
  reference that overrides the profile's model for that one run, exactly like
  the subagent tool's `model` argument:

      local run = tackle.spawn("scout", "Map the code paths.", {model = "provider/fast-model"})

  The scope's backend resolves the model only against models its trusted
  configuration already makes available; an unavailable model, or a host that
  does not support model selection, refuses the spawn. Unknown keys and
  non-string or empty models raise.

  ## Fan-out

  `tackle.parallel(items, fn, opts)` calls `fn(item, index)` once per item of
  the `items` sequence and expects it to return that item's `profile, prompt`,
  optionally followed by a spawn options table (see "Spawn options"):

      local answers = tackle.parallel(questions, function(question, index)
        return "researcher", index .. ". " .. question
      end, {limit = 3})

      -- per-item model selection
      tackle.parallel(files, function(file)
        return "reviewer", "Review " .. file, {model = "provider/strong-model"}
      end)

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

      { index = 2, ok = true, status = "ok", text = "...",
        tokens = 1200, tool_calls = 3, failed_tool_calls = 0 }

  `status` is the run's outcome status — `"ok"`, `"error"`, `"cancelled"`,
  `"runtime_error"`, `"timeout"`, or `"rejected"` — or one of:

    * `"callback_error"` — `fn` raised, or returned something other than two
      strings and an optional spawn options table;
    * `"spawn_error"` — the runtime refused the spawn for a policy reason, such
      as an unknown profile, a spawn-depth limit, or a scope that forbids
      delegation;
    * `"capacity"` — the scope stayed at its concurrency limit for as long as
      `tackle.parallel` waits for its own runs to free capacity. Retrying the
      item in a later call may succeed;
    * `"budget_exhausted"` — the workflow's token budget was used up before
      the item started;
    * `"unavailable"` — a settled run's outcome could not be collected.

  `text` carries the answer for a successful run and the reason otherwise.
  Every item carries run facts — zeros for an item that never started a run —
  except an `"unavailable"` item, whose run's facts cannot be collected.
  Item failures are returned, never raised, and runs are never retried: a
  retried agent run is a second paid model call that may answer differently.
  The workflow decides what to do with a failed item.

  Argument errors raise catchable Lua errors carrying the script's source line,
  so a workflow can implement policy with `pcall`. `tackle.spawn` also raises when
  the runtime refuses a run; `tackle.parallel` reports a refusal on the item it
  belongs to instead.

  ## Classification

  `tackle.classify(state, questions, opts?)` asks a small decision model typed
  questions instead of spending a delegated agent run:

      local result = tackle.classify(review.text, {
        verdict = {type = "choice", instructions = "Does the review approve the change?",
                   criteria = {approve = "No blocking findings", revise = "Blocking findings"}}
      })
      if result.ok and result.answers.verdict.choice == "approve" then ... end

  `state` is a string or a table of strings, numbers, booleans, and tables.
  `questions` maps names to question specs, and the result's `answers` maps
  the same names to answers; `Tackle.Workflow.Classify` documents both. `opts`
  is an optional table with two keys: `model`, a `"provider/model"` decision
  model reference, and `label`, a short name for the call in the host's
  progress view (`Tackle.Workflow.Progress`). Without `model` the host's
  default decision model answers.

  The host grants decision models with `Tackle.Workflow.run/3`'s `:decisions`
  option (`Tackle.Workflow.Decisions`); a script can only select a model that
  grant offers. A successful call returns

      { ok = true, status = "ok", model = "provider/model", tokens = 0,
        answers = { verdict = { type = "choice", choice = "approve", ... } } }

  When the model cannot answer, the call returns `ok = false`, `status`
  `"error"` or `"cancelled"`, and the reason in `text`; it is never retried.
  Argument errors, a session without decision models, an unknown model, and an
  exhausted token budget raise catchable Lua errors, like `tackle.spawn`.

  `tokens` is what the call added to the workflow's token usage. A local
  decision model (`Tackle.Lib.Decision.local?/0`) spends no budgeted tokens, so
  its calls report `0`, run even after the budget is spent, and never change
  `tackle.budget()`. A remote model's tokens count like a run's, as far as its
  adapter reports them: a call that fails before the model answers, or an
  adapter that reports no usage, adds nothing.

  ## Profile allowlist

  A host may run a workflow with an explicit allowlist of profile names
  (`Tackle.Workflow.run/3`'s `:profiles` option, which `Tackle.Workflow.Tool`
  forwards from its session context). The allowlist bounds this API and nothing
  else: `tackle.spawn` raises, and `tackle.parallel` reports `spawn_error` on
  the item, for every profile outside it. Without an allowlist, the scope's own
  trusted profiles decide, exactly as they do for the subagent tool.
  """

  use Lua.API, scope: "tackle"

  alias Tackle.Lib.Decision.{Request, Selection}
  alias Tackle.Runtime
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.RunRef
  alias Tackle.Workflow.Classify
  alias Tackle.Workflow.Decisions
  alias Tackle.Workflow.Fanout
  alias Tackle.Workflow.Meter
  alias Tackle.Workflow.Progress

  @parallel_helpers :parallel_helpers
  @parallel_options ["limit"]
  @spawn_options ["model"]
  @classify_options ["model", "label"]

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
    start_spawn(state, profile, prompt, [])
  end

  deflua spawn(_profile, _prompt), _state do
    runtime_exception!("tackle.spawn(profile, prompt, opts?) requires two strings")
  end

  deflua spawn(profile, prompt, opts) when is_binary(profile) and is_binary(prompt), state do
    case spawn_options(state, opts) do
      {:ok, spawn_opts} -> start_spawn(state, profile, prompt, spawn_opts)
      {:error, message} -> runtime_exception!(message)
    end
  end

  deflua spawn(_profile, _prompt, _opts), _state do
    runtime_exception!("tackle.spawn(profile, prompt, opts?) requires two strings")
  end

  @doc "Waits for one run and returns its outcome table."
  deflua await(run), state do
    %RunRef{} = run_ref = run_ref!(state, run)

    case Runtime.await(run_ref, :infinity) do
      %Outcome{} = outcome ->
        Progress.emit(
          observer(state),
          Progress.run_finished(run_ref, nil, outcome.status, Outcome.ok?(outcome))
        )

        facts = Meter.run_facts(meter!(state), run_ref.run_id)
        {encoded, state} = Lua.encode!(state, outcome_table(outcome) |> Map.merge(facts))
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

  @doc "Returns the workflow's token accounting: `used`, and `limit` and `remaining`."
  deflua budget(), state do
    {encoded, state} = Lua.encode!(state, Meter.budget(meter!(state)))
    {encoded, state}
  end

  @doc "Asks a host-granted decision model typed questions about a state."
  deflua(classify(input, questions), state, do: run_classify(state, input, questions, nil))

  deflua(classify(input, questions, opts), state, do: run_classify(state, input, questions, opts))

  @doc "Reports one progress message to the host's log callback."
  deflua log(message) when is_binary(message), state do
    %{server: server} = context!(state)
    Progress.emit(observer(state), %{type: :log, message: message})
    send(server, {:workflow_log, message})
    {true, state}
  end

  deflua log(_message), _state do
    runtime_exception!("tackle.log(message) requires a string")
  end

  defp start_spawn(state, profile, prompt, spawn_opts) do
    %{handle: %Handle{} = handle} = context!(state)

    unless allowed_profile?(state, profile) do
      spawn_error!("spawn failed: " <> profile_not_allowed(profile))
    end

    meter = meter!(state)

    if Meter.exhausted?(meter) do
      spawn_error!("spawn failed: " <> budget_exhausted(meter))
    end

    on_event = observer(state)
    opts = Keyword.merge(run_opts(meter, on_event, profile), spawn_opts)

    case Runtime.request_agent(handle, profile, prompt, opts) do
      {:ok, %RunRef{} = run_ref} ->
        Progress.emit(on_event, Progress.run_started(run_ref, profile, prompt))
        {encoded, state} = Lua.encode!(state, {:userdata, run_ref})
        {encoded, state}

      {:error, reason} ->
        spawn_error!("spawn failed: #{inspect(reason)}")
    end
  end

  # Decodes a spawn options table into `Tackle.Runtime.request_agent/4` options.
  # The values are model-generated input; the runtime and backend validate the
  # model itself against trusted configuration.
  defp spawn_options(_state, nil), do: {:ok, []}

  defp spawn_options(state, opts) do
    if is_table(opts) do
      options = state |> Lua.decode!(opts) |> Lua.Table.as_map()

      case Map.keys(options) -- @spawn_options do
        [] -> spawn_model(options)
        unknown -> {:error, "unknown spawn options: #{format_keys(unknown)}"}
      end
    else
      {:error, "spawn options must be a table, got #{type_name(opts)}"}
    end
  end

  defp spawn_model(options) do
    case Map.fetch(options, "model") do
      :error ->
        {:ok, []}

      {:ok, model} when is_binary(model) and model != "" ->
        {:ok, [model: model]}

      {:ok, model} ->
        {:error, "spawn option model must be a non-empty string, got #{inspect(model)}"}
    end
  end

  defp format_keys(keys), do: keys |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

  # Every run reports its child events to the workflow's meter, and to the host's
  # observer when there is one.
  defp run_opts(%Meter{} = meter, on_event, profile) do
    forward = Keyword.get(Progress.request_opts(on_event, profile), :event_callback)

    [
      event_callback: fn run_ref, event ->
        Meter.record(meter, run_ref.run_id, event)
        if forward, do: forward.(run_ref, event)
      end
    ]
  end

  defp budget_exhausted(%Meter{token_budget: budget} = meter) do
    "token budget exhausted (used #{Meter.tokens_used(meter)} of #{budget} tokens)"
  end

  # Fan-out -----------------------------------------------------------------------

  defp run_parallel(items, callback, opts, state) do
    %{handle: %Handle{} = handle} = context!(state)

    unless is_lua_func(callback) or is_erl_func(callback) do
      parallel_error!("tackle.parallel(items, fn, opts?) requires a function")
    end

    limit = parallel_limit!(state, handle, opts)
    {count, state} = item_count!(state, items)
    on_event = observer(state)
    meter = meter!(state)
    id = Progress.parallel_id()
    Progress.emit(on_event, %{type: :parallel_started, id: id, count: count, limit: limit})

    {results, state} =
      Fanout.map(
        handle,
        count,
        limit,
        state,
        fn index, state -> item_request(state, callback, items, index) end,
        [request_opts: &run_opts(meter, on_event, &1)] ++ fanout_observer(on_event, id)
      )

    Progress.emit(on_event, %{type: :parallel_finished, id: id})
    {encoded, state} = Lua.encode!(state, Enum.map(results, &result_table(&1, meter)))
    {encoded, state}
  end

  defp fanout_observer(nil, _id), do: []

  defp fanout_observer(on_event, id) do
    [
      on_started: fn index, run_ref, {profile, prompt, _opts} ->
        parallel = %{id: id, index: index}
        Progress.emit(on_event, Progress.run_started(run_ref, profile, prompt, parallel))
      end,
      on_settled: fn index, result, started ->
        Progress.emit(on_event, settled_event(id, index, result, started))
      end
    ]
  end

  defp settled_event(_id, _index, {:ok, %Outcome{} = outcome}, {run_ref, {profile, _, _}}),
    do: Progress.run_finished(run_ref, profile, outcome.status, Outcome.ok?(outcome))

  # A watcher that could not collect the outcome still settles the run it
  # watched; an admitted run has no other way to fail here.
  defp settled_event(_id, _index, {:error, {:unavailable, _reason}}, {run_ref, {profile, _, _}}),
    do: Progress.run_finished(run_ref, profile, :unavailable, false)

  defp settled_event(id, index, {:error, reason}, nil) do
    %{
      type: :item_failed,
      parallel: %{id: id, index: index},
      status: error_status(reason),
      text: error_text(reason)
    }
  end

  # Invokes the script's callback for one item. The item is passed through Lua
  # untouched, so the callback sees the value the script listed.
  defp item_request(state, callback, items, index) do
    case Lua.call_function(state, helper!(state, :apply), [callback, items, index]) do
      {:ok, [profile, prompt], state} when is_binary(profile) and is_binary(prompt) ->
        item_spawn(state, profile, prompt, nil)

      {:ok, [profile, prompt, opts], state} when is_binary(profile) and is_binary(prompt) ->
        item_spawn(state, profile, prompt, opts)

      {:ok, results, state} ->
        {:error,
         "expected two strings and an optional options table (profile, prompt, opts?), " <>
           "got #{describe(results)}", state}

      {:error, exception, state} ->
        {:error, Exception.message(exception), state}
    end
  end

  defp item_spawn(state, profile, prompt, opts) do
    meter = meter!(state)

    with {:ok, spawn_opts} <- spawn_options(state, opts),
         {:allowed, true} <- {:allowed, allowed_profile?(state, profile)},
         {:budget, false} <- {:budget, Meter.exhausted?(meter)} do
      {:ok, {profile, prompt, spawn_opts}, state}
    else
      {:error, message} -> {:error, message, state}
      {:allowed, false} -> {:error, {:spawn_error, profile_not_allowed(profile)}, state}
      {:budget, true} -> {:error, {:budget_exhausted, budget_exhausted(meter)}, state}
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

  defp result_table({index, {:ok, %Outcome{} = outcome}}, meter) do
    outcome
    |> outcome_table()
    |> Map.merge(Meter.run_facts(meter, outcome.run_id))
    |> Map.put("index", index)
  end

  defp result_table({index, {:error, reason}}, _meter) do
    %{
      "index" => index,
      "ok" => false,
      "status" => error_status(reason),
      "text" => error_text(reason)
    }
    |> Map.merge(unstarted_facts(reason))
  end

  # An item that never started a run spent nothing. An `unavailable` item did
  # start one, but its run cannot be told apart, so it reports no facts at all
  # rather than zeros that would be wrong.
  defp unstarted_facts({:unavailable, _reason}), do: %{}

  defp unstarted_facts(_reason),
    do: %{"tokens" => 0, "tool_calls" => 0, "failed_tool_calls" => 0}

  defp error_status({:callback_error, _reason}), do: "callback_error"
  defp error_status({:spawn_error, _reason}), do: "spawn_error"
  defp error_status({:capacity, _reason}), do: "capacity"
  defp error_status({:unavailable, _reason}), do: "unavailable"
  defp error_status({:budget_exhausted, _reason}), do: "budget_exhausted"

  defp error_text({:callback_error, reason}), do: reason_text(reason)
  defp error_text({:spawn_error, reason}), do: "spawn failed: #{reason_text(reason)}"
  defp error_text({:capacity, reason}), do: "spawn refused at capacity: #{reason_text(reason)}"
  defp error_text({:unavailable, reason}), do: "outcome unavailable: #{reason_text(reason)}"
  defp error_text({:budget_exhausted, reason}), do: "spawn refused: #{reason_text(reason)}"

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

  # Classification ----------------------------------------------------------------

  defp run_classify(state, input, questions, opts) do
    decisions = decisions!(state)
    %{model: model_ref, label: label} = classify_opts!(state, opts)
    data = classify_arg!(Classify.state(decode_value(state, input)))
    questions = classify_arg!(Classify.questions(decode_value(state, questions)))
    %Selection{} = selection = select_decision!(decisions, model_ref)
    request = Request.new(data, questions, selection.model)

    case Request.validate(request) do
      :ok -> :ok
      {:error, {:invalid_decision_request, detail}} -> classify_error!(request_error(detail))
    end

    meter = meter!(state)

    if not selection.local and Meter.exhausted?(meter) do
      classify_error!(budget_exhausted(meter))
    end

    on_event = observer(state)
    id = Progress.classify_id()
    Progress.emit(on_event, Progress.classify_started(id, label, selection, questions))

    table =
      case Decisions.decide(decisions, selection, request) do
        {:ok, result} ->
          # Tokens are spent once the model answered, even if the answer is unusable.
          tokens = if selection.local, do: 0, else: Meter.add_usage(meter, result.usage)
          Classify.result_table(result, questions, selection, tokens)

        {:error, reason} ->
          Classify.failure_table(reason)
      end

    Progress.emit(on_event, Progress.classify_finished(id, label, table))

    {encoded, state} = Lua.encode!(state, table)
    {encoded, state}
  end

  defp decode_value(state, value) do
    if is_table(value), do: Lua.decode!(state, value), else: value
  end

  defp decisions!(state) do
    case context!(state) do
      %{decisions: %Decisions{} = decisions} -> decisions
      _other -> classify_error!("no decision models are available in this session")
    end
  end

  defp classify_opts!(_state, nil), do: %{model: nil, label: nil}

  defp classify_opts!(state, opts) do
    unless is_table(opts) do
      classify_error!("classify options must be a table, got #{type_name(opts)}")
    end

    options = state |> Lua.decode!(opts) |> Lua.Table.as_map()

    case Map.keys(options) -- @classify_options do
      [] -> :ok
      unknown -> classify_error!("unknown classify options: #{format_keys(unknown)}")
    end

    %{model: classify_option!(options, "model"), label: classify_option!(options, "label")}
  end

  defp classify_option!(options, key) do
    case Map.fetch(options, key) do
      :error ->
        nil

      {:ok, value} when is_binary(value) and value != "" ->
        value

      {:ok, value} ->
        classify_error!(
          "classify option #{key} must be a non-empty string, got #{inspect(value)}"
        )
    end
  end

  defp classify_arg!({:ok, value}), do: value
  defp classify_arg!({:error, message}), do: classify_error!(message)

  defp select_decision!(decisions, model_ref) do
    case Decisions.select(decisions, model_ref) do
      {:ok, selection} ->
        selection

      {:error, :no_model} ->
        classify_error!(
          "no default decision model is configured; pass {model = ...}" <>
            available_models(decisions)
        )

      {:error, {kind, _detail}} when kind in [:unknown_adapter, :unknown_decision_model] ->
        classify_error!(
          "decision model #{inspect(model_ref)} is not available" <> available_models(decisions)
        )

      {:error, {:invalid_model_ref, _ref}} ->
        classify_error!(
          "decision model #{inspect(model_ref)} is not a \"provider/model\" reference" <>
            available_models(decisions)
        )

      # A grant the host misconfigured, not a script mistake.
      {:error, reason} ->
        classify_error!(
          "decision model #{inspect(model_ref || decisions.default_model)} " <>
            "could not be selected: #{inspect(reason)}"
        )
    end
  end

  defp available_models(decisions) do
    case Decisions.available(decisions) do
      [] -> ""
      refs -> " (available: #{Enum.join(refs, ", ")})"
    end
  end

  defp request_error(:empty_state), do: "state must not be empty"
  defp request_error(:invalid_state), do: "state must be JSON-compatible"

  defp request_error({:question_count, count}),
    do: "classify takes 1 to #{Request.max_questions()} questions, got #{count}"

  defp request_error({:request_too_large, bytes}),
    do: "the request is #{bytes} bytes; the limit is #{Request.max_encoded_bytes()}"

  defp request_error(detail), do: "invalid classification request: #{inspect(detail)}"

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

  defp observer(state) do
    case Lua.get_private(state, :tackle_workflow) do
      {:ok, %{on_event: on_event}} -> on_event
      _other -> nil
    end
  end

  defp meter!(state) do
    %{meter: %Meter{} = meter} = context!(state)
    meter
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
  # exception names `tackle.parallel(...)` or `tackle.spawn(...)` explicitly.
  defp parallel_error!(message) do
    raise Lua.RuntimeException, scope: ["tackle"], function: :parallel, message: message
  end

  defp spawn_error!(message) do
    raise Lua.RuntimeException, scope: ["tackle"], function: :spawn, message: message
  end

  defp classify_error!(message) do
    raise Lua.RuntimeException, scope: ["tackle"], function: :classify, message: message
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
