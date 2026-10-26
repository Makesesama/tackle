defmodule Tackle.Lib.Compaction do
  @moduledoc """
  Provider-neutral checkpoint compaction of the model-visible projection.

  Compaction never touches the canonical transcript. `Tackle.Lib.State.messages`
  remains the complete, settled conversation; a compaction is an entry in the
  state's tree, and only `model_messages` — the array sent to providers,
  derived from the tree — is replaced by a synthetic checkpoint followed by a
  recent tail whose content and tool linkage are preserved:

      [old prefix ..............][recent balanced tail]
                  ↓
      [synthetic checkpoint][recent balanced tail]

  `Tackle.Lib.Compaction.Checkpoint` builds the checkpoint and applies a
  committed `Tackle.Lib.Compaction.Record` to a message list.

  A state compacts only when its `:compaction` is a
  `Tackle.Lib.Compaction.Config`; `nil` disables compaction.

  ## Transaction

  One compaction is all-or-nothing per pass:

    1. select and snapshot a plan without mutation;
    2. bound the summarizer input to the window (`Tackle.Lib.Compaction.Input`);
    3. generate and strictly validate the summary;
    4. build the replacement in memory without installing it (append the
       compaction entry to a copy of the tree);
    5. commit one durable record through the state's `Tackle.Lib.Committer`;
    6. only after a successful commit install the replacement.

  A summary, validation, or commit failure leaves the model context unchanged
  for that pass. `compact/3` always returns the last committed state: the
  input state when nothing was committed, or the state of an earlier pass
  when a later tightening pass failed, so the caller can keep the durable
  checkpoint. A commit failure is reported as `{:durable_commit_failed,
  reason}` so the caller can fail closed rather than continue with an
  unpersisted checkpoint.

  ## Progress

  A pass must make real progress, or it fails before anything is committed:

    * its plan shadows at least one message beyond an earlier checkpoint
      (otherwise `:nothing_to_compact` when no pass committed), and the
      retained tail fits the policy's `max_retained_tokens`
      (`Tackle.Lib.Compaction.Plan`);
    * its summary is complete (`:truncated_summary` when the provider stopped
      at the output limit, `:summary_content_filtered` when it withheld
      output) and smaller than what it shadows (`:summary_not_smaller`); and
    * for `:pressure`, the last allowed pass must bring the estimated context
      below the policy's `trigger_at` (`:insufficient_reduction`), so a
      successful pressure compaction is never immediately due again.
      Earlier tightening passes only have to shrink it.

  `:disabled`, `:no_context_window`, and `:nothing_to_compact` mean there
  was nothing to do (`nothing_to_do?/1`): a `:pressure` compaction reports
  `:nothing_to_compact` below the threshold, too.

  A custom summarizer that returns anything but `{:ok, %Summary{}}` or
  `{:error, reason}` fails the pass with `{:invalid_summary_result, result}`,
  and one that raises, throws, or exits with `{:summarizer_failed, reason}`.

  After replacement, retained assistant usage no longer describes the current
  request, and provider continuation state may replay large opaque reasoning
  payloads from the pre-compaction context. Both are stripped from the model
  projection while the canonical transcript keeps them. The next assistant
  response re-establishes authoritative usage and continuation checkpoints.

  ## Entry points

    * `:pressure` — the pre-prompt threshold (see `Tackle.Lib.Compaction.Policy`);
    * `:overflow` — one compact-and-retry after a provider
      `Tackle.Lib.LLM.Error` of kind `:context_window_exceeded`; and
    * `:manual` — an idle, operator-requested compaction.

  Lifecycle events `:compaction_start`, `:compaction_end` (and
  `:compaction_retry`) are emitted through `:event_callback`. Their metadata
  never includes raw prompts or summary content.
  """

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Committer
  alias Tackle.Lib.Compaction.Checkpoint
  alias Tackle.Lib.Compaction.Config
  alias Tackle.Lib.Compaction.Input
  alias Tackle.Lib.Compaction.Plan
  alias Tackle.Lib.Compaction.Policy
  alias Tackle.Lib.Compaction.Prompt
  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Compaction.Request
  alias Tackle.Lib.Compaction.Summary
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Loop.Gate
  alias Tackle.Lib.ModelInfo
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Registry
  alias Tackle.Lib.Tree

  @type result ::
          {:ok, State.t(), Record.t()}
          | {:error, term(), State.t()}
          | {:cancelled, term(), State.t()}

  @nothing_to_do [:disabled, :no_context_window, :nothing_to_compact]

  @doc """
  Returns true for the `compact/3` error reasons that mean there was nothing
  to do: compaction is disabled, the model declares no context window, or
  nothing needed compacting.
  """
  @spec nothing_to_do?(term()) :: boolean()
  def nothing_to_do?(reason), do: reason in @nothing_to_do

  @doc """
  Resolves the effective policy numbers for a state's selected model.

  The policy sees the fixed part of every request (system prompt, tool
  definitions, and checkpoint framing) and the output limit the
  conversation's requests ask for (`:max_tokens` in the adapter options), see
  `Tackle.Lib.Compaction.Policy.resolve/3`. A `:snapshot` option takes them
  from a turn's `Tackle.Lib.Snapshot` instead of the state.

  Returns `{:error, :disabled}` for a state without a compaction config, and
  `{:error, :no_context_window}` when the adapter declares no context window,
  so automatic pressure compaction is disabled rather than assuming one.
  """
  @spec resolve(State.t(), keyword()) ::
          {:ok, Policy.resolved(), ModelInfo.t()} | {:error, term()}
  def resolve(%State{} = state, opts \\ []) do
    with {:ok, config} <- config(state) do
      resolve_policy(config, context(state, opts))
    end
  end

  @doc """
  Runs one compaction transaction, possibly running further tightening passes.

  Returns `{:ok, state, record}` with the last committed record, or
  `{:error, reason, state}` / `{:cancelled, reason, state}` where `state` is
  the last committed state: the input state when nothing was committed.

  ## Options

    * `:snapshot` - the turn's `Tackle.Lib.Snapshot`, whose model, system
      prompt, tools, and adapter options the summary uses instead of the
      state's.
    * `:llm_opts` - adapter options merged over the snapshot's (or state's).
    * `:instructions` - operator focus added to the configured instructions.
    * `:event_callback` - receives the lifecycle events.
    * `:cancellation_signal` - checked before the summary and the commit.
    * `:before_provider_call` - zero-arity host gate returning `:ok` or
      `{:error, reason}`, run before each summarizer invocation.
      Cancellation is rechecked after the gate.
  """
  @spec compact(State.t(), Record.trigger(), keyword()) :: result()
  def compact(%State{} = state, trigger, opts \\ []) when is_list(opts) do
    unless trigger in Record.triggers() do
      raise ArgumentError, "unknown compaction trigger: #{inspect(trigger)}"
    end

    with {:ok, config} <- config(state),
         ctx = context(state, opts),
         {:ok, resolved, info} <- resolve_policy(config, ctx) do
      job = %{
        trigger: trigger,
        config: config,
        resolved: resolved,
        info: info,
        ctx: ctx,
        opts: opts
      }

      passes(state, job, 1, nil)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp config(%State{compaction: %Config{} = config}), do: {:ok, config}
  defp config(%State{compaction: nil}), do: {:error, :disabled}

  defp resolve_policy(%Config{} = config, ctx) do
    case ctx.model_info do
      %ModelInfo{} = info ->
        policy_opts = [fixed_tokens: fixed_tokens(ctx), max_tokens: ctx.max_tokens]

        with {:ok, resolved} <- Policy.resolve(config.policy, info, policy_opts) do
          {:ok, resolved, info}
        end

      nil ->
        {:error, :no_context_window}
    end
  end

  defp passes(state, job, pass, last_record) do
    if pass <= job.config.max_passes and should_compact?(state, job, pass) do
      case start_pass(state, job, pass) do
        {:ok, state, record} -> passes(state, job, pass + 1, record)
        {:error, :nothing_to_shadow} -> finish(state, last_record)
        {status, reason} -> {status, reason, state}
      end
    else
      finish(state, last_record)
    end
  end

  defp finish(state, nil), do: {:error, :nothing_to_compact, state}
  defp finish(state, %Record{} = record), do: {:ok, state, record}

  # The first pass of manual and overflow compaction deliberately bypasses the
  # threshold. Any later tightening pass, and every pressure pass, is gated on
  # the resolved threshold so compaction cannot loop without cause.
  defp should_compact?(state, job, pass) when pass > 1, do: pressure?(state, job)
  defp should_compact?(state, %{trigger: :pressure} = job, _pass), do: pressure?(state, job)
  defp should_compact?(_state, _job, _pass), do: true

  defp pressure?(state, job) do
    case ContextUsage.estimate(state, job.info) do
      %ContextUsage{tokens: tokens} -> Policy.pressure?(job.resolved, tokens)
      nil -> false
    end
  end

  defp start_pass(state, job, pass) do
    plan_opts = [
      retain_tokens: job.resolved.retain_tokens,
      max_retained_tokens: job.resolved.max_retained_tokens,
      checkpoint_id: checkpoint_id(state)
    ]

    with {:ok, plan} <- Plan.select(State.model_messages(state), plan_opts) do
      plan = %{plan | tokens_before: context_tokens(state, job.info, plan.tokens_before)}

      if reachable?(job, plan, pass),
        do: attempt(state, job, plan, pass),
        else: {:error, :insufficient_reduction}
    end
  end

  # The id of the checkpoint leading the model context, known from the
  # branch's last compaction record rather than from any message's content.
  defp checkpoint_id(state) do
    case State.last_compaction(state) do
      %Record{summary_message: %{id: id}} -> id
      nil -> nil
    end
  end

  defp context_tokens(state, info, fallback) do
    case ContextUsage.estimate(state, info) do
      %ContextUsage{tokens: tokens} -> tokens
      nil -> fallback
    end
  end

  # A pressure compaction must end below the threshold. When even an empty
  # summary could not get the last pass there (a tail the plan could not cut
  # below the cap), the summary is not worth paying for.
  defp reachable?(%{trigger: :pressure, config: %Config{max_passes: pass}} = job, plan, pass),
    do: job.resolved.fixed_tokens + plan.retained_tokens < job.resolved.trigger_at

  defp reachable?(_job, _plan, _pass), do: true

  defp attempt(state, job, plan, pass) do
    compaction_id = state.id_generator.()
    opts = job.opts

    emit(
      opts,
      Event.compaction_start(
        compaction_id: compaction_id,
        trigger: job.trigger,
        pass: pass,
        tokens_before: plan.tokens_before
      )
    )

    started_at = System.monotonic_time()

    with :ok <- check_cancel(opts),
         {:ok, request} <- build_request(state, job, plan),
         :ok <- await_provider(opts),
         {:ok, summary} <- summarize(job, request),
         :ok <- check_cancel(opts),
         :ok <- validate_summary(summary, plan, job.resolved),
         {:ok, record} <- build_record(state, job, compaction_id, summary, plan, pass),
         :ok <- validate_progress(job, record, pass),
         {:ok, installed, record} <- install(state, record),
         :ok <- check_cancel(opts),
         :ok <- Committer.commit(state, record) do
      emit(
        opts,
        Event.compaction_end(
          compaction_id: compaction_id,
          trigger: job.trigger,
          status: :completed,
          pass: pass,
          tokens_before: plan.tokens_before,
          estimated_tokens_after: record.estimated_tokens_after,
          retained_count: length(State.model_messages(installed)),
          shadowed_count: length(plan.shadowed_ids),
          duration: duration(started_at),
          summary_model: record.summary_model,
          summary_usage: record.summary_usage
        )
      )

      {:ok, installed, record}
    else
      {:cancelled, reason} ->
        emit(opts, finished(compaction_id, job, :cancelled, pass, plan, started_at, reason))
        {:cancelled, reason}

      {:error, reason} ->
        emit(opts, finished(compaction_id, job, :failed, pass, plan, started_at, reason))
        {:error, reason}
    end
  end

  # The summarizer reads the shadowed messages, shortened when they would not
  # fit the window next to the system prompt, the tools, the directive, the
  # summary's output limit, and the safety reserve.
  defp build_request(state, job, plan) do
    %{ctx: ctx, resolved: resolved} = job

    instructions =
      merged_instructions(job.config.instructions, Keyword.get(job.opts, :instructions))

    budget =
      resolved.context_window - resolved.summary_max_tokens - resolved.safety_reserve -
        ContextUsage.estimate_text(ctx.system) - ContextUsage.estimate_tools(ctx.tools) -
        ContextUsage.estimate_text(Prompt.directive(instructions: instructions))

    with {:ok, messages, _shortened} <-
           Input.fit(plan.shadowed, budget, checkpoint_id: checkpoint_id(state)) do
      {:ok,
       %Request{
         messages: messages,
         system: ctx.system,
         tools: ctx.tools,
         selection: ctx.selection,
         session_id: state.session_id,
         instructions: instructions,
         trigger: job.trigger,
         summary_max_tokens: resolved.summary_max_tokens
       }}
    end
  end

  defp summarize(job, %Request{} = request) do
    opts = job.opts

    summarizer_opts = [
      llm_opts: Keyword.merge(job.ctx.llm_opts, Keyword.get(opts, :llm_opts, [])),
      cancellation_signal: Keyword.get(opts, :cancellation_signal)
    ]

    case job.config.summarizer.summarize(request, summarizer_opts) do
      {:ok, %Summary{} = summary} -> {:ok, summary}
      {:error, reason} -> unless_cancelled(opts, {:error, reason})
      other -> unless_cancelled(opts, {:error, {:invalid_summary_result, other}})
    end
  rescue
    error -> unless_cancelled(job.opts, {:error, {:summarizer_failed, Exception.message(error)}})
  catch
    kind, reason -> unless_cancelled(job.opts, {:error, {:summarizer_failed, {kind, reason}}})
  end

  defp unless_cancelled(opts, error) do
    case check_cancel(opts) do
      :ok -> error
      cancelled -> cancelled
    end
  end

  defp merged_instructions(nil, nil), do: nil
  defp merged_instructions(configured, nil), do: configured
  defp merged_instructions(nil, requested), do: requested
  defp merged_instructions(configured, requested), do: configured <> "\n\n" <> requested

  defp validate_summary(%Summary{content: content} = summary, plan, resolved) do
    cond do
      not is_binary(content) ->
        {:error, {:invalid_summary_result, {:ok, summary}}}

      content == "" ->
        {:error, :empty_summary}

      summary.stop_reason == :content_filter ->
        {:error, :summary_content_filtered}

      truncated?(summary, resolved) ->
        {:error, :truncated_summary}

      ContextUsage.estimate_text(content) >= plan.shadowed_tokens ->
        {:error, :summary_not_smaller}

      true ->
        :ok
    end
  end

  # The provider's stop reason decides when it reports one. Without it, a
  # summary whose visible output reached the cap probably was cut off;
  # reasoning tokens are part of a provider's output count but not of the
  # summary, so they do not count toward the cap.
  defp truncated?(%Summary{stop_reason: :max_tokens}, _resolved), do: true

  defp truncated?(%Summary{stop_reason: reason}, _resolved)
       when reason in [:end, :tool_calls],
       do: false

  defp truncated?(%Summary{usage: usage, content: content}, resolved) do
    cap = resolved.summary_max_tokens

    case usage do
      %{output_tokens: output} when is_integer(output) ->
        output - reasoning_tokens(usage) >= cap

      _missing ->
        ContextUsage.estimate_text(content) >= cap
    end
  end

  defp reasoning_tokens(%{reasoning_tokens: tokens}) when is_integer(tokens), do: tokens
  defp reasoning_tokens(_usage), do: 0

  defp validate_progress(
         %{trigger: :pressure, config: %Config{max_passes: pass}} = job,
         record,
         pass
       ) do
    if record.estimated_tokens_after < job.resolved.trigger_at,
      do: :ok,
      else: {:error, :insufficient_reduction}
  end

  defp validate_progress(_job, _record, _pass), do: :ok

  # The record, with the size of the model context it leaves, applied with
  # `Checkpoint.apply_compaction/2` like every other reader of the record.
  defp build_record(state, job, compaction_id, summary, plan, pass) do
    record = %Record{
      compaction_id: compaction_id,
      trigger: job.trigger,
      summary_message: Checkpoint.message(compaction_id, summary.content),
      shadowed_message_ids: plan.shadowed_ids,
      first_retained_message_id: plan.first_retained_id,
      previous_compaction_id: State.last_compaction_id(state),
      tokens_before: plan.tokens_before,
      estimated_tokens_after: 0,
      summary_usage: summary.usage,
      summary_model: summary.model || job.ctx.model,
      created_at: DateTime.utc_now(),
      details: %{pass: pass}
    }

    model_messages = Checkpoint.apply_compaction(State.model_messages(state), record)

    record = %{
      record
      | estimated_tokens_after:
          ContextUsage.estimate_projection(job.ctx.system, model_messages, job.ctx.tools)
    }

    {:ok, record}
  end

  # Builds the state that installs the record without installing it: the
  # caller commits the record first, so a record the tree refuses is never
  # made durable.
  #
  # A compaction is a first-class entry on the active branch: the tree
  # attaches the record to the active entry (`:parent_id`), and the committed
  # record is the one the tree holds. The branch's transcript does not change,
  # and its model context, re-derived by `State.put_tree/2`, starts with the
  # record's checkpoint, which applies only to the branch it was created on.
  defp install(%State{tree: tree} = state, record) do
    case Tree.append_compaction(tree, record) do
      {:ok, tree, entry} -> {:ok, State.put_tree(state, tree), entry.compaction}
      {:error, reason} -> {:error, {:invalid_compaction, reason}}
    end
  end

  defp await_provider(opts) do
    result = Gate.before_provider_call(Keyword.get(opts, :before_provider_call))

    case check_cancel(opts) do
      :ok -> result
      cancelled -> cancelled
    end
  end

  defp check_cancel(opts) do
    signal = Keyword.get(opts, :cancellation_signal)

    if Cancellation.cancelled?(signal),
      do: {:cancelled, Cancellation.reason(signal) || :cancelled},
      else: :ok
  end

  # What the summary is generated with: the turn's snapshot when the loop
  # compacts, the state's own configuration otherwise.
  defp context(state, opts) do
    source = Keyword.get(opts, :snapshot) || state
    selection = source.llm
    llm_opts = source.llm_opts || []

    %{
      selection: selection,
      model: selection && selection.model,
      model_info: selection_model_info(selection),
      system: source.system_prompt,
      tools: Registry.definitions(source.tool_registry),
      llm_opts: llm_opts,
      max_tokens: Keyword.get(llm_opts, :max_tokens)
    }
  end

  # What every request carries besides the messages, and the checkpoint's own
  # framing, which a compaction cannot shrink.
  defp fixed_tokens(ctx) do
    ContextUsage.estimate_text(ctx.system) + ContextUsage.estimate_tools(ctx.tools) +
      ContextUsage.estimate_text(Checkpoint.framing())
  end

  defp selection_model_info(%Selection{model_info: %ModelInfo{} = info}), do: info
  defp selection_model_info(_selection), do: nil

  defp emit(opts, %Event{} = event) do
    case Keyword.get(opts, :event_callback) do
      fun when is_function(fun, 1) -> fun.(event)
      _none -> :ok
    end
  end

  defp finished(compaction_id, job, status, pass, plan, started_at, reason) do
    Event.compaction_end(
      compaction_id: compaction_id,
      trigger: job.trigger,
      status: status,
      pass: pass,
      tokens_before: plan.tokens_before,
      duration: duration(started_at),
      error: summarize_error(reason)
    )
  end

  defp summarize_error({:durable_commit_failed, reason}), do: {:durable_commit_failed, reason}
  defp summarize_error(reason) when is_atom(reason), do: reason
  defp summarize_error(reason), do: inspect(reason)

  defp duration(started_at), do: System.monotonic_time() - started_at
end
