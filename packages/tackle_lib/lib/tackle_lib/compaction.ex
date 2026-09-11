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
    2. generate and strictly validate the summary;
    3. commit one durable record through the configured committer;
    4. only after a successful commit install the replacement in memory.

  A summary, validation, or commit failure leaves the model context unchanged.
  A commit failure is reported as `{:error, {:durable_commit_failed, reason}}`
  so the caller can fail closed rather than continue with an unpersisted
  checkpoint.

  After replacement, retained assistant usage no longer describes the current
  request, and provider continuation state may replay large opaque reasoning
  payloads from the pre-compaction context. Both are stripped from the model
  projection while the canonical transcript keeps them. The next assistant
  response re-establishes authoritative usage and continuation checkpoints.

  ## Entry points

    * `:pressure` — the pre-prompt threshold (see `Tackle.Lib.Compaction.Policy`);
    * `:overflow` — one compact-and-retry after a provider
      `:context_window_exceeded` error; and
    * `:manual` — an idle, operator-requested compaction.

  Lifecycle events `:compaction_start`, `:compaction_end` (and
  `:compaction_retry`) are emitted through `:event_callback`. Their metadata
  never includes raw prompts or summary content.
  """

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Compaction.Config
  alias Tackle.Lib.Compaction.Plan
  alias Tackle.Lib.Compaction.Policy
  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Compaction.Request
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Event
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

  Returns `{:error, :no_context_window}` when the adapter declares no context
  window, so automatic pressure compaction is disabled rather than assuming one.
  """
  @spec resolve(State.t(), keyword()) ::
          {:ok, Policy.resolved(), Tackle.Lib.ModelInfo.t() | nil} | {:error, term()}
  def resolve(%State{} = state, opts \\ []) do
    ctx = context(state, opts)

    case model_info(ctx) do
      %Tackle.Lib.ModelInfo{} = info ->
        case Policy.resolve(config(state).policy, info) do
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
  """
  @spec compact(State.t(), trigger(), keyword()) ::
          {:ok, State.t(), Record.t()} | {:error, term()} | {:cancelled, term()}
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
    case Plan.select(State.model_messages(state), retain_tokens: resolved.retain_tokens) do
      {:ok, plan} ->
        plan = %{plan | tokens_before: context_tokens_before(state, info, plan.tokens_before)}
        attempt(state, trigger, config, resolved, info, plan, pass, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp attempt(state, trigger, config, resolved, _info, plan, pass, opts) do
    compaction_id = message_id(state)

    emit(opts, :compaction_start, %{
      compaction_id: compaction_id,
      trigger: trigger,
      pass: pass,
      tokens_before: plan.tokens_before
    })

    started_at = System.monotonic_time()
    ctx = context(state, opts)

    with :ok <- check_cancel(opts),
         {:ok, summary} <- summarize(state, config, resolved, ctx, plan, trigger, opts),
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
         :ok <- commit(state, config, record) do
      state = install(state, record, new_model_messages)

      emit(opts, :compaction_end, %{
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
      })

      {:ok, state, record}
    else
      {:cancelled, reason} ->
        emit(
          opts,
          :compaction_end,
          finished(compaction_id, trigger, :cancelled, plan, started_at, reason)
        )

        {:cancelled, reason}

      {:error, {:durable_commit_failed, _reason} = error} ->
        emit(
          opts,
          :compaction_end,
          finished(compaction_id, trigger, :failed, plan, started_at, error)
        )

        {:error, error}

      {:error, reason} ->
        emit(
          opts,
          :compaction_end,
          finished(compaction_id, trigger, :failed, plan, started_at, reason)
        )

        {:error, reason}
    end
  end

  defp summarize(state, config, resolved, ctx, plan, trigger, opts) do
    request = %Request{
      messages: plan.shadowed,
      system: ctx.system,
      tools: ctx.tools,
      selection: ctx.selection,
      model: ctx.model,
      model_info: ctx.model_info,
      session_id: state.session_id,
      prior_summary: prior_summary(plan),
      instructions: merged_instructions(config.instructions, Keyword.get(opts, :instructions)),
      trigger: trigger,
      summary_max_tokens: resolved.summary_max_tokens
    }

    llm_opts = Keyword.merge(state.llm_opts, Keyword.get(opts, :llm_opts, []))

    case config.summarizer.summarize(request, llm_opts: llm_opts) do
      {:ok, summary} ->
        {:ok, summary}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_summary_result, other}}
    end
  rescue
    error -> {:error, {:summarizer_failed, Exception.message(error)}}
  end

  defp merged_instructions(nil, nil), do: nil
  defp merged_instructions(configured, nil), do: configured
  defp merged_instructions(nil, requested), do: requested
  defp merged_instructions(configured, requested), do: configured <> "\n\n" <> requested

  defp validate_summary(
         %Tackle.Lib.Compaction.Summary{content: content, usage: usage},
         plan,
         resolved
       ) do
    cond do
      not is_binary(content) or content == "" ->
        {:error, :empty_summary}

      truncated?(usage, content, resolved) ->
        {:error, :truncated_summary}

      not summary_reduces?(%{content: content}, plan) ->
        {:error, :summary_not_smaller}

      true ->
        :ok
    end
  end

  defp truncated?(usage, content, resolved) do
    cap = resolved.summary_max_tokens

    output_reached_cap? =
      case usage do
        %{output_tokens: tokens} when is_integer(tokens) -> tokens >= cap
        _missing -> false
      end

    output_reached_cap? or ContextUsage.estimate_text(content) >= cap
  end

  defp summary_reduces?(%{content: content}, plan) do
    ContextUsage.estimate_text(content) < plan.shadowed_tokens
  end

  defp prior_summary(plan) do
    case plan.shadowed do
      [%Message{} = first | _rest] -> checkpoint_body(first)
      [] -> nil
    end
  end

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
  # keeps replacing the explicit model projection as before.
  defp install(%State{tree: %Tree{} = tree} = state, %Record{} = record, _model_messages) do
    case Tree.append_compaction(tree, record) do
      {:ok, tree, _entry} ->
        %{
          state
          | tree: tree,
            messages: Tree.transcript(tree),
            model_messages: Tree.model_context(tree),
            last_compaction_id: record.compaction_id
        }

      {:error, reason} ->
        raise ArgumentError, "cannot append compaction to conversation tree: #{inspect(reason)}"
    end
  end

  defp install(%State{} = state, %Record{} = record, model_messages) do
    %{state | model_messages: model_messages, last_compaction_id: record.compaction_id}
  end

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

    %{
      selection: selection,
      model: (snapshot && snapshot.model) || state.model,
      system: (snapshot && snapshot.system_prompt) || state.system_prompt,
      tools: tools(snapshot, state),
      model_info: selection_model_info(selection)
    }
  end

  defp tools(%{tool_registry: registry}, _state) when not is_nil(registry),
    do: Registry.definitions(registry)

  defp tools(_snapshot, %State{tool_registry: registry}), do: Registry.definitions(registry)

  defp model_info(%{model_info: %Tackle.Lib.ModelInfo{} = info}), do: info
  defp model_info(_ctx), do: nil

  defp selection_model_info(%Tackle.Lib.LLM.Selection{model_info: info}), do: info
  defp selection_model_info(_selection), do: nil

  defp emit(opts, type, data) do
    case Keyword.get(opts, :event_callback) do
      fun when is_function(fun, 1) -> fun.(Event.new(type, data))
      _none -> :ok
    end
  end

  defp finished(compaction_id, trigger, status, plan, started_at, reason) do
    %{
      compaction_id: compaction_id,
      trigger: trigger,
      status: status,
      tokens_before: plan.tokens_before,
      duration: duration(started_at),
      error: summarize_error(reason)
    }
  end

  defp summarize_error({:durable_commit_failed, reason}), do: {:durable_commit_failed, reason}
  defp summarize_error(reason) when is_atom(reason), do: reason
  defp summarize_error(reason), do: inspect(reason)

  defp duration(started_at), do: System.monotonic_time() - started_at
end
