defmodule Tackle.Lib.Compaction do
  @moduledoc """
  Provider-neutral checkpoint compaction of the model-visible projection.

  Compaction never touches the canonical transcript. `Tackle.Lib.State.messages`
  remains the complete, settled conversation; only `model_messages` — the array
  sent to providers — is replaced by a synthetic checkpoint followed by a
  recent tail whose content and tool linkage are preserved:

      [old prefix ..............][recent balanced tail]
                  ↓
      [synthetic checkpoint][recent balanced tail]

  ## Transaction

  One compaction is all-or-nothing:

    1. select and snapshot a plan without mutation;
    2. bound the summarizer input to the window (`Tackle.Lib.Compaction.Input`);
    3. generate and strictly validate the summary;
    4. build the replacement in memory without installing it (in tree mode,
       append the compaction entry to a copy of the tree);
    5. commit one durable record through the configured committer;
    6. only after a successful commit install the replacement.

  A summary, validation, or commit failure leaves the model context unchanged
  for that pass. If a later tightening pass fails after an earlier pass was
  committed, the error includes the latest committed state as a third tuple
  element so the caller can preserve the durable checkpoint.
  A commit failure is reported as `{:error, {:durable_commit_failed, reason}}`
  so the caller can fail closed rather than continue with an unpersisted
  checkpoint.

  ## Progress

  A pass must make real progress, or it fails before anything is committed:

    * its plan shadows at least one message beyond an earlier checkpoint
      (otherwise `{:error, :nothing_to_shadow}`, reported as
      `{:error, :nothing_to_compact}` when no pass committed), and the
      retained tail fits the policy's `max_retained_tokens`
      (`Tackle.Lib.Compaction.Plan`);
    * its summary is complete (`:truncated_summary` when the provider stopped
      at the output limit, `:summary_content_filtered` when it withheld
      output) and smaller than what it shadows (`:summary_not_smaller`); and
    * for `:pressure`, the last allowed pass must bring the estimated context
      below the policy's `trigger_at` (`:insufficient_reduction`), so a
      successful pressure compaction is never immediately due again.
      Earlier tightening passes only have to shrink it.

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
  alias Tackle.Lib.Loop.Gate
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Registry
  alias Tackle.Lib.Tree

  @marker "[[context-checkpoint]]"

  @type trigger :: :pressure | :overflow | :manual

  @doc "Returns the marker that identifies a synthetic checkpoint message."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "Returns true when `message` is a synthetic compaction checkpoint."
  @spec checkpoint?(Message.t() | nil) :: boolean()
  def checkpoint?(%Message{role: :user, content: content}) when is_binary(content),
    do: String.starts_with?(content, @marker)

  def checkpoint?(_message), do: false

  @doc "Returns the effective compaction config for a state."
  @spec config(State.t()) :: Config.t()
  def config(%State{compaction: %Config{} = config}), do: config
  def config(%State{}), do: %{Config.new!([]) | enabled?: false}

  @doc "Returns true when compaction is enabled for a state."
  @spec enabled?(State.t()) :: boolean()
  def enabled?(%State{} = state), do: Config.enabled?(config(state))

  @doc """
  Resolves the effective policy numbers for a state's selected model.

  The policy sees the fixed part of every request (system prompt, tool
  definitions, and checkpoint framing) and the output limit the
  conversation's requests ask for (`:max_tokens` in the adapter options), see
  `Tackle.Lib.Compaction.Policy.resolve/3`.

  Returns `{:error, :no_context_window}` when the adapter declares no context
  window, so automatic pressure compaction is disabled rather than assuming one.
  """
  @spec resolve(State.t(), keyword()) ::
          {:ok, Policy.resolved(), Tackle.Lib.ModelInfo.t() | nil} | {:error, term()}
  def resolve(%State{} = state, opts \\ []) do
    ctx = context(state, opts)

    case model_info(ctx) do
      %Tackle.Lib.ModelInfo{} = info ->
        policy_opts = [fixed_tokens: fixed_tokens(ctx), max_tokens: ctx.max_tokens]

        case Policy.resolve(config(state).policy, info, policy_opts) do
          {:ok, resolved} -> {:ok, resolved, info}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :no_context_window}
    end
  end

  @doc """
  Runs one compaction transaction, possibly running a second tightening pass.

  Returns `{:ok, state, record}`, `{:error, reason}`, or `{:cancelled, reason}`.
  When a later pass fails after a successful commit, returns
  `{:error | :cancelled, reason, committed_state}` instead.

  The optional `:before_provider_call` zero-arity host gate returns `:ok` or
  `{:error, reason}` and runs before each summarizer invocation. Cancellation
  is rechecked after the gate, before summary generation.
  """
  @spec compact(State.t(), trigger(), keyword()) ::
          {:ok, State.t(), Record.t()}
          | {:error | :cancelled, term()}
          | {:error | :cancelled, term(), State.t()}
  def compact(%State{} = state, trigger, opts \\ [])
      when trigger in [:pressure, :overflow, :manual] do
    config = config(state)

    if Config.enabled?(config) do
      run(state, trigger, config, opts)
    else
      {:error, :disabled}
    end
  end

  @doc "Builds the synthetic background message for one summary."
  @spec checkpoint_message(String.t(), String.t()) :: Message.t()
  def checkpoint_message(compaction_id, summary) do
    Message.user(checkpoint_content(summary), id: compaction_id)
  end

  @doc "Returns the summary body of a checkpoint message, if it is one."
  @spec checkpoint_body(Message.t() | nil) :: String.t() | nil
  def checkpoint_body(%Message{content: content}) when is_binary(content) do
    if String.starts_with?(content, @marker) do
      case String.split(content, "\n\n", parts: 2) do
        [_header, body] -> String.trim_trailing(body)
        [_header] -> nil
      end
    end
  end

  def checkpoint_body(_message), do: nil

  defp run(state, trigger, config, opts) do
    case resolve(state, opts) do
      {:ok, resolved, info} ->
        passes(state, trigger, config, resolved, info, opts, 1, nil)

      {:error, :no_context_window} ->
        {:error, :no_context_window}
    end
  end

  defp passes(state, trigger, config, resolved, info, opts, pass, last_record) do
    cond do
      pass > config.max_passes ->
        finish(state, last_record)

      not should_compact?(state, trigger, resolved, info, pass) ->
        finish(state, last_record)

      true ->
        case start_pass(state, trigger, config, resolved, info, opts, pass) do
          {:ok, state, record} ->
            passes(state, trigger, config, resolved, info, opts, pass + 1, record)

          {:error, :nothing_to_shadow} ->
            finish(state, last_record)

          {status, reason} when status in [:error, :cancelled] and not is_nil(last_record) ->
            {status, reason, state}

          other ->
            other
        end
    end
  end

  defp finish(_state, nil), do: {:error, :nothing_to_compact}
  defp finish(state, %Record{} = record), do: {:ok, state, record}

  # The first pass of manual and overflow compaction deliberately bypasses the
  # threshold. Any later tightening pass, and every pressure pass, is gated on
  # the resolved threshold so compaction cannot loop without cause.
  defp should_compact?(state, _trigger, resolved, info, pass) when pass > 1,
    do: pressure?(state, resolved, info)

  defp should_compact?(state, :pressure, resolved, info, _pass),
    do: pressure?(state, resolved, info)

  defp should_compact?(_state, _trigger, _resolved, _info, _pass), do: true

  defp pressure?(state, resolved, info) do
    case ContextUsage.estimate(state, info) do
      %ContextUsage{tokens: tokens} -> Policy.pressure?(resolved, tokens)
      nil -> false
    end
  end

  defp context_tokens_before(state, info, fallback) do
    case ContextUsage.estimate(state, info) do
      %ContextUsage{tokens: tokens} -> tokens
      nil -> fallback
    end
  end

  defp start_pass(state, trigger, config, resolved, info, opts, pass) do
    plan_opts = [
      retain_tokens: resolved.retain_tokens,
      max_retained_tokens: resolved.max_retained_tokens
    ]

    case Plan.select(State.model_messages(state), plan_opts) do
      {:ok, plan} ->
        plan = %{plan | tokens_before: context_tokens_before(state, info, plan.tokens_before)}

        if reachable?(trigger, config, resolved, plan, pass),
          do: attempt(state, trigger, config, resolved, info, plan, pass, opts),
          else: {:error, :insufficient_reduction}

      {:error, _reason} = error ->
        error
    end
  end

  # A pressure compaction must end below the threshold. When even an empty
  # summary could not get the last pass there (a tail the plan could not cut
  # below the cap), the summary is not worth paying for.
  defp reachable?(:pressure, %Config{max_passes: pass}, resolved, plan, pass),
    do: resolved.fixed_tokens + plan.retained_tokens < resolved.trigger_at

  defp reachable?(_trigger, _config, _resolved, _plan, _pass), do: true

  defp attempt(state, trigger, config, resolved, _info, plan, pass, opts) do
    compaction_id = message_id(state)

    emit(
      opts,
      Event.compaction_start(
        compaction_id: compaction_id,
        trigger: trigger,
        pass: pass,
        tokens_before: plan.tokens_before
      )
    )

    started_at = System.monotonic_time()
    ctx = context(state, opts)

    with :ok <- check_cancel(opts),
         {:ok, request} <- build_request(state, config, resolved, ctx, plan, trigger, opts),
         :ok <- await_provider(opts),
         {:ok, summary} <- summarize(state, config, request, opts),
         :ok <- check_cancel(opts),
         :ok <- validate_summary(summary, plan, resolved),
         summary_message = checkpoint_message(compaction_id, summary.content),
         new_model_messages = [summary_message | reset_retained_metadata(plan.retained)],
         {:ok, record} <-
           build_record(
             state,
             compaction_id,
             trigger,
             summary,
             plan,
             ctx,
             new_model_messages,
             pass
           ),
         :ok <- validate_progress(trigger, config, resolved, record, pass),
         {:ok, installed} <- prepare_install(state, record, new_model_messages),
         :ok <- check_cancel(opts),
         :ok <- commit(state, config, record) do
      state = installed

      emit(
        opts,
        Event.compaction_end(
          compaction_id: record.compaction_id,
          trigger: trigger,
          status: :completed,
          pass: pass,
          tokens_before: plan.tokens_before,
          estimated_tokens_after: record.estimated_tokens_after,
          retained_count: length(new_model_messages),
          shadowed_count: length(plan.shadowed_ids),
          duration: duration(started_at),
          summary_model: record.summary_model,
          summary_usage: record.summary_usage
        )
      )

      {:ok, state, record}
    else
      {:cancelled, reason} ->
        emit(opts, finished(compaction_id, trigger, :cancelled, pass, plan, started_at, reason))

        {:cancelled, reason}

      {:error, {:durable_commit_failed, _reason} = error} ->
        emit(opts, finished(compaction_id, trigger, :failed, pass, plan, started_at, error))

        {:error, error}

      {:error, reason} ->
        emit(opts, finished(compaction_id, trigger, :failed, pass, plan, started_at, reason))

        {:error, reason}
    end
  end

  # The summarizer reads the shadowed messages, shortened when they would not
  # fit the window next to the system prompt, the tools, the directive, the
  # summary's output limit, and the safety reserve.
  defp build_request(state, config, resolved, ctx, plan, trigger, opts) do
    instructions = merged_instructions(config.instructions, Keyword.get(opts, :instructions))

    budget =
      resolved.context_window - resolved.summary_max_tokens - resolved.safety_reserve -
        ContextUsage.estimate_text(ctx.system) - ContextUsage.estimate_tools(ctx.tools) -
        ContextUsage.estimate_text(Prompt.directive(instructions: instructions))

    with {:ok, messages, _shortened} <- Input.fit(plan.shadowed, budget) do
      {:ok,
       %Request{
         messages: messages,
         system: ctx.system,
         tools: ctx.tools,
         selection: ctx.selection,
         model: ctx.model,
         model_info: ctx.model_info,
         session_id: state.session_id,
         instructions: instructions,
         trigger: trigger,
         summary_max_tokens: resolved.summary_max_tokens
       }}
    end
  end

  defp summarize(state, config, %Request{} = request, opts) do
    llm_opts = Keyword.merge(state.llm_opts, Keyword.get(opts, :llm_opts, []))

    summarizer_opts = [
      llm_opts: llm_opts,
      cancellation_signal: Keyword.get(opts, :cancellation_signal)
    ]

    case config.summarizer.summarize(request, summarizer_opts) do
      {:ok, %Summary{} = summary} -> {:ok, summary}
      {:error, reason} -> unless_cancelled(opts, {:error, reason})
      other -> unless_cancelled(opts, {:error, {:invalid_summary_result, other}})
    end
  rescue
    error -> unless_cancelled(opts, {:error, {:summarizer_failed, Exception.message(error)}})
  catch
    kind, reason -> unless_cancelled(opts, {:error, {:summarizer_failed, {kind, reason}}})
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

  defp validate_progress(:pressure, %Config{max_passes: pass}, resolved, record, pass) do
    if record.estimated_tokens_after < resolved.trigger_at,
      do: :ok,
      else: {:error, :insufficient_reduction}
  end

  defp validate_progress(_trigger, _config, _resolved, _record, _pass), do: :ok

  defp build_record(
         state,
         compaction_id,
         trigger,
         summary,
         plan,
         ctx,
         new_model_messages,
         pass
       ) do
    estimated_tokens_after =
      ContextUsage.estimate_projection(ctx.system, new_model_messages, ctx.tools)

    {:ok,
     %Record{
       compaction_id: compaction_id,
       trigger: trigger,
       summary_message: checkpoint_message(compaction_id, summary.content),
       shadowed_message_ids: plan.shadowed_ids,
       first_retained_message_id: plan.first_retained_id,
       previous_compaction_id: State.last_compaction_id(state),
       tokens_before: plan.tokens_before,
       estimated_tokens_after: estimated_tokens_after,
       summary_usage: summary.usage,
       summary_model: summary.model || ctx.model,
       created_at: DateTime.to_iso8601(DateTime.utc_now()),
       details: %{"pass" => pass}
     }}
  end

  defp commit(_state, %Config{committer: nil}, _record), do: :ok

  defp commit(state, %Config{committer: module}, %Record{} = record) do
    context = %{
      session_id: state.session_id,
      context: state.context,
      tree: state.tree,
      tree_parent_id: state.tree && state.tree.active_id
    }

    case module.commit(record, context) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:durable_commit_failed, reason}}

      other ->
        {:error, {:durable_commit_failed, {:unexpected_commit_result, other}}}
    end
  rescue
    error -> {:error, {:durable_commit_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:durable_commit_failed, {kind, reason}}}
  end

  # In tree mode a compaction is a first-class entry on the active branch: the
  # record becomes a node, and the model context is re-derived from the tree so
  # the checkpoint applies only to the branch it was created on. Linear mode
  # keeps replacing the explicit model projection, whose head is the record's
  # checkpoint message (`State.last_compaction_id/1` reads its id).
  #
  # The replacement is built before the commit and installed only after it, so
  # a record the tree refuses is never made durable.
  defp prepare_install(%State{tree: %Tree{} = tree} = state, %Record{} = record, _messages) do
    case Tree.append_compaction(tree, record) do
      {:ok, tree, _entry} ->
        {:ok,
         %{
           state
           | tree: tree,
             messages: Tree.transcript(tree),
             model_messages: Tree.model_context(tree)
         }}

      {:error, reason} ->
        {:error, {:invalid_compaction, reason}}
    end
  end

  defp prepare_install(%State{} = state, %Record{}, model_messages),
    do: {:ok, %{state | model_messages: model_messages}}

  defp reset_retained_metadata(messages) do
    Enum.map(messages, fn %Message{} = message ->
      %{message | token_usage: nil, provider_state: nil}
    end)
  end

  defp message_id(%State{id_generator: generator}) when is_function(generator, 0),
    do: generator.()

  defp checkpoint_content(summary) do
    """
    #{@marker}
    Earlier conversation in this session was compacted into the background summary below. Treat it as established context, continue from the retained messages that follow, and do not repeat it to the user.

    #{summary}
    """
  end

  defp await_provider(opts) do
    result = Gate.before_provider_call(Keyword.get(opts, :before_provider_call))

    case check_cancel(opts) do
      :ok -> result
      cancelled -> cancelled
    end
  end

  defp check_cancel(opts) do
    case Keyword.get(opts, :cancellation_signal) do
      nil -> :ok
      signal -> check_signal(signal)
    end
  end

  defp check_signal(signal) do
    if Cancellation.cancelled?(signal) do
      {:cancelled, Cancellation.reason(signal) || :cancelled}
    else
      :ok
    end
  end

  defp context(state, opts) do
    snapshot = Keyword.get(opts, :snapshot)
    selection = (snapshot && snapshot.llm) || state.llm

    llm_opts = (snapshot && snapshot.llm_opts) || state.llm_opts || []

    %{
      selection: selection,
      model: selection && selection.model,
      system: (snapshot && snapshot.system_prompt) || state.system_prompt,
      tools: tools(snapshot, state),
      model_info: selection_model_info(selection),
      max_tokens: Keyword.get(llm_opts, :max_tokens)
    }
  end

  # What every request carries besides the messages, and the checkpoint's own
  # framing, which a compaction cannot shrink.
  defp fixed_tokens(ctx) do
    ContextUsage.estimate_text(ctx.system) + ContextUsage.estimate_tools(ctx.tools) +
      ContextUsage.estimate_text(checkpoint_content(""))
  end

  defp tools(%{tool_registry: registry}, _state) when not is_nil(registry),
    do: Registry.definitions(registry)

  defp tools(_snapshot, %State{tool_registry: registry}), do: Registry.definitions(registry)

  defp model_info(%{model_info: %Tackle.Lib.ModelInfo{} = info}), do: info
  defp model_info(_ctx), do: nil

  defp selection_model_info(%Tackle.Lib.LLM.Selection{model_info: info}), do: info
  defp selection_model_info(_selection), do: nil

  defp emit(opts, %Event{} = event) do
    case Keyword.get(opts, :event_callback) do
      fun when is_function(fun, 1) -> fun.(event)
      _none -> :ok
    end
  end

  defp finished(compaction_id, trigger, status, pass, plan, started_at, reason) do
    Event.compaction_end(
      compaction_id: compaction_id,
      trigger: trigger,
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
