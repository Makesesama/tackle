defmodule Tackle.Lib.Loop do
  @moduledoc """
  ReAct-style agent loop.

  Implements a Reasoning + Acting loop where the agent:
  1. Receives a user query
  2. Thinks about how to respond
  3. Optionally calls tools to gather information
  4. Repeats until it has a final answer

  ## Provider-agnostic

  The loop never talks to an LLM directly — it calls the configured
  `Tackle.Lib.LLM` adapter. Configure it with:

      config :tackle_lib, llm: MyApp.AI.TackleAdapter

  ## Host-supplied system prompt

  The loop uses `state.system_prompt` as-is. The host composes it (typically
  with `Tackle.Lib.SystemPrompt` helpers for the tool block and response guidance).
  Tool execution always uses provider-native tool calls. If a prompt renderer
  returns a response schema, it is used only for structured non-tool responses.

  ## Provider call gate

  `run/3` and `continue/2` accept a `:before_provider_call` zero-arity callback.
  It runs immediately before every provider `generate/2` or `stream/3` dispatch,
  including retries, and before each compaction summarizer invocation. It must
  return `:ok` or `{:error, reason}`. An error skips that dispatch and follows
  the ordinary provider error path. Cancellation is
  checked again after the callback, so a cancellation while it is blocked skips
  the provider call. The callback is host policy; the library has no storage
  knowledge.

  ## Tool execution gate

  `run/3` and `continue/2` also accept a `:before_tool_execution` zero-arity
  callback with the same contract. It runs after the `before_tool_call` hooks
  have accepted a call, and before any of those tools execute: once per
  concurrent batch, or once per call under the sequential policy. It is skipped
  when every call it would cover is read-only (`Tackle.Lib.Tool.effect/1`) or
  will not run because its tool cannot be resolved. A host that records tool
  intent without waiting in `before_tool_call` uses it as a single barrier
  before the effects. An error aborts the step like a rejecting
  `before_tool_call` hook, and no tool runs. Cancellation is checked again after
  the callback.

  ## Append-only provider context

  Each generation receives the persisted user, assistant, and tool messages
  without a synthetic per-step message. Loop-wide guidance belongs in the
  stable system prompt so provider prompt caches can reuse the complete
  preceding request.

  """

  require Logger

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Compaction
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Event
  alias Tackle.Lib.Hook
  alias Tackle.Lib.LLM
  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages
  alias Tackle.Lib.Loop.Run
  alias Tackle.Lib.Retry
  alias Tackle.Lib.State
  alias Tackle.Lib.SystemPrompt
  alias Tackle.Lib.Telemetry
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Batch
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error, as: ToolError
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Registry
  alias Tackle.Lib.Tool.Result, as: ToolResult

  @doc """
  Runs the agent loop for a user query.

  ## Options

  Unknown options raise `ArgumentError`.

    * `:event_callback` - Function called with `%Tackle.Lib.Event{}` structs. The loop
      also puts it into every tool's execution context as `:event_callback`, so tools
      can report progress through the same path.
    * `:tool_context` - Map of additional host context merged over `state.context` for
      tool execution only (default `%{}`). Hooks do not see it. The loop's own
      `:event_callback` and `:tool_call_id` keys, and the per-call
      `:cancellation_signal` when the run has a signal, take precedence over it.
    * `:llm_stream` - When true, use the optional `stream/3` callback in `Tackle.Lib.LLM` if the adapter supports it.
      Usage is still reported once per response, by the loop's own `:usage` event.
    * `:cancellation_signal` - Optional `Tackle.Lib.Cancellation.Signal` checked between loop steps.
      Tools receive the per-call child signal (`Tackle.Lib.Cancellation.for_call/2`).
    * `:turn_id` - Host-assigned turn id stored on the per-turn snapshot. When omitted,
      the state's configured id generator is used.
    * `:tool_supervisor` - Optional `Task.Supervisor` used when the state's tool policy is
      `:concurrent`. Ignored (and not required) for the default sequential policy.
    * `:before_provider_call` - Optional zero-arity callback returning `:ok` or
      `{:error, reason}`, invoked before every provider dispatch, including retries
      and compaction summaries.
    * `:before_tool_execution` - Optional zero-arity callback returning `:ok` or
      `{:error, reason}`, invoked after `before_tool_call` hooks accept a call
      and before the accepted tools execute (see "Tool execution gate").
    * `:take_incoming_messages` - Optional zero-arity host callback returning
      `{:ok, [message]}` or `{:error, reason}`. Incoming text is appended as user
      messages immediately before the next provider call. The callback is polled
      before the first call, after each complete tool batch, and after a final
      assistant response so steering never interrupts an executing tool batch.
  """
  @spec run(State.t(), String.t(), keyword()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()}
  def run(%State{} = state, user_input, opts \\ []) do
    run = Run.new!(opts, state)
    state = reset_turn(state)

    emit(run, Event.new(:turn_start, %{session_id: state.session_id}))

    if cancelled?(run) do
      cancel(state, run)
    else
      state = settle_unresolved_tool_calls(state, run, "interrupted")
      user_message = Message.user(user_input, id_generator: state.id_generator)
      state = State.add_message(state, user_message)

      case emit_and_finalize_message(state, run, user_message) do
        {:ok, state} -> loop(state, run)
        {:error, state} -> finish(:error, state, run)
      end
    end
  end

  @doc """
  Re-runs the agent loop against existing state WITHOUT appending a new user
  message. Used to retry a turn that errored: the user message is already in
  state, so we resume the loop directly. Like `run/3`, it starts a new turn:
  the iteration counter, status, and error are reset, so the retry gets a full
  `max_iterations` budget, and a fresh snapshot of the state's configuration
  is captured.

  Accepts the same options as `run/3`; unknown options raise `ArgumentError`.
  """
  @spec continue(State.t(), keyword()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()}
  def continue(%State{} = state, opts \\ []) do
    run = Run.new!(opts, state)
    state = reset_turn(state)

    emit(run, Event.new(:turn_start, %{session_id: state.session_id}))

    state
    |> settle_unresolved_tool_calls(run, "interrupted")
    |> loop(run)
  end

  # Every turn starts from a clean per-turn state: `max_iterations` bounds one
  # turn, and a previous turn's error or status must not leak into this one.
  defp reset_turn(%State{} = state) do
    %{
      state
      | current_iteration: 0,
        status: :idle,
        error: nil,
        pending_assistant_id: nil,
        overflow_retries: 0
    }
  end

  # Each turn runs against configuration frozen when it starts.
  defp loop(%State{} = state, run) do
    if cancelled?(run) do
      cancel(state, run)
    else
      case append_incoming_messages(state, run) do
        {:ok, state, _count} -> continue_loop(state, run)
        {:error, state} -> finish(:error, state, run)
      end
    end
  end

  defp continue_loop(%State{} = state, run) do
    cond do
      cancelled?(run) ->
        cancel(state, run)

      State.max_iterations_reached?(state) ->
        Logger.warning("Agent reached max iterations (#{state.max_iterations})")
        fail(state, run, "Reached maximum iterations without completing", :max_iterations)

      true ->
        iterate(state, run)
    end
  end

  defp iterate(state, run) do
    state = State.increment_iteration(state)
    state = State.set_status(state, :thinking)

    emit(run, Event.new(:status_change, %{status: :thinking}))

    assistant_id = state.id_generator.()
    state = %{state | pending_assistant_id: assistant_id}
    emit(run, Event.message_start(id: assistant_id, role: :assistant))

    emit(run, Event.new(:step_start, %{iteration: state.current_iteration}))

    case maybe_auto_compact(state, run) do
      {:ok, state} ->
        before_prompt(state, run)

      {:error, reason, committed_state} ->
        fail(committed_state, run, "Compaction failed: #{inspect(reason)}", reason)

      {:cancelled, _reason, committed_state} ->
        cancel(committed_state, run)
    end
  end

  defp before_prompt(state, run) do
    case invoke_before_prompt(state, run) do
      {:ok, state} ->
        call_provider(state, run)

      {:error, reason} ->
        fail(state, run, "Hook aborted before prompt: #{inspect(reason)}", reason)
    end
  end

  defp call_provider(state, run) do
    case call_llm(state, run) do
      {:error, reason} = error ->
        cond do
          cancelled?(run) or recoverable_overflow?(state, reason, run) ->
            handle_llm_call_result(error, state, run)

          Retry.available?(run.snapshot.retry, 0) and Retry.retryable?(reason) ->
            retry_llm(state, run, reason, 1)

          true ->
            handle_llm_call_result(error, state, run)
        end

      result ->
        handle_llm_call_result(result, state, run)
    end
  end

  defp retry_llm(state, run, reason, attempt) do
    retry = run.snapshot.retry
    delay_ms = Retry.delay(retry, attempt)

    emit(
      run,
      Event.new(
        :retry_scheduled,
        %{
          attempt: attempt,
          max_retries: retry.max_retries,
          delay_ms: delay_ms,
          reason: reason
        },
        id: state.pending_assistant_id
      )
    )

    case Retry.wait(delay_ms, run.cancellation_signal) do
      :ok ->
        if cancelled?(run) do
          emit_retry_end(run, false, attempt, reason)
          handle_llm_call_result({:error, reason}, state, run)
        else
          emit(
            run,
            Event.new(:retry_start, %{attempt: attempt}, id: state.pending_assistant_id)
          )

          handle_retry_result(call_llm(state, run), state, run, attempt)
        end

      {:cancelled, _reason} ->
        emit_retry_end(run, false, attempt, reason)
        handle_llm_call_result({:error, reason}, state, run)
    end
  end

  defp handle_retry_result({:error, reason} = error, state, run, attempt) do
    retry = run.snapshot.retry

    cond do
      cancelled?(run) or recoverable_overflow?(state, reason, run) ->
        emit_retry_end(run, false, attempt, reason)
        handle_llm_call_result(error, state, run)

      Retry.available?(retry, attempt) and Retry.retryable?(reason) ->
        retry_llm(state, run, reason, attempt + 1)

      true ->
        emit_retry_end(run, false, attempt, reason)
        handle_llm_call_result(error, state, run)
    end
  end

  defp handle_retry_result(result, state, run, attempt) do
    emit_retry_end(run, true, attempt, nil)
    handle_llm_call_result(result, state, run)
  end

  defp emit_retry_end(run, success?, attempt, reason) do
    data = %{success?: success?, attempt: attempt}
    data = if is_nil(reason), do: data, else: Map.put(data, :reason, reason)
    emit(run, Event.new(:retry_end, data))
  end

  defp handle_llm_call_result({:ok, %{data: response} = result}, state, run) do
    if cancelled?(run) do
      cancel(state, run)
    else
      emit_llm_settlement_events(run, state, result)

      case invoke_after_prompt(state, response, run) do
        {:ok, state} ->
          handle_llm_response(state, response, run, result)

        {:error, reason} ->
          fail(state, run, "Hook aborted after prompt: #{inspect(reason)}", reason)
      end
    end
  end

  defp handle_llm_call_result({:error, reason}, state, run) do
    cond do
      cancelled?(run) ->
        cancel(state, run)

      recoverable_overflow?(state, reason, run) ->
        recover_overflow(state, reason, run)

      true ->
        Logger.error("LLM call failed: #{inspect(reason)}")
        fail(state, run, "Failed to get response: #{inspect(reason)}", reason)
    end
  end

  # Provider-confirmed context overflow is distinct from proactive pressure. The
  # turn may compact and reissue the same request up to the policy's
  # `overflow_retry_limit`, bypassing the normal threshold. If a compaction
  # pass was committed before a later pass failed, the smaller context is
  # still worth a retry; any other compaction failure keeps the original
  # provider error.
  defp recover_overflow(state, reason, run) do
    Logger.warning("Provider reported context overflow; compacting and retrying")

    emit(run, Event.new(:compaction_retry, %{trigger: :overflow, reason: reason}))

    case Compaction.compact(state, :overflow, compaction_opts(run)) do
      {:ok, state, _record} ->
        retry_after_overflow(state, run)

      {:error, {:durable_commit_failed, _reason} = error} ->
        fail(state, run, inspect(error), error)

      {:error, {:durable_commit_failed, _reason} = error, committed_state} ->
        fail(committed_state, run, inspect(error), error)

      {:cancelled, _reason} ->
        cancel(state, run)

      {:cancelled, _reason, committed_state} ->
        cancel(committed_state, run)

      {:error, _compaction_reason, committed_state} ->
        retry_after_overflow(committed_state, run)

      {:error, _compaction_reason} ->
        fail(state, run, "Failed to get response: #{inspect(reason)}", reason)
    end
  end

  defp retry_after_overflow(state, run) do
    call_provider(%{state | overflow_retries: state.overflow_retries + 1}, run)
  end

  defp recoverable_overflow?(%State{} = state, reason, run) do
    LLM.context_window_exceeded?(reason) and Compaction.enabled?(state) and
      overflow_retries_remaining?(state, run)
  end

  defp overflow_retries_remaining?(%State{} = state, run) do
    case Compaction.resolve(state, snapshot: run.snapshot) do
      {:ok, resolved, _info} -> state.overflow_retries < resolved.overflow_retry_limit
      {:error, _reason} -> false
    end
  end

  defp maybe_auto_compact(state, run) do
    with true <- Compaction.enabled?(state),
         {:ok, resolved, info} <- Compaction.resolve(state, snapshot: run.snapshot),
         true <- resolved.usable?,
         %ContextUsage{tokens: tokens} <- ContextUsage.estimate(state, info),
         true <- Compaction.Policy.pressure?(resolved, tokens) do
      case compact_with_state(state, :pressure, run) do
        {:ok, state, _record} ->
          {:ok, state}

        {:error, {:durable_commit_failed, _reason} = error, committed_state} ->
          {:error, error, committed_state}

        {:cancelled, reason, committed_state} ->
          {:cancelled, reason, committed_state}

        {:error, _reason, committed_state} ->
          # Continue with a prior committed checkpoint if there is one; otherwise
          # the model surface is unchanged. Only durability failures are fatal.
          {:ok, committed_state}
      end
    else
      _skip -> {:ok, state}
    end
  end

  # Keep Compaction.compact/3's public result shape; only Loop normalizes
  # failures to include the state that must survive the turn.
  defp compact_with_state(state, trigger, run) do
    case Compaction.compact(state, trigger, compaction_opts(run)) do
      {status, reason} when status in [:error, :cancelled] -> {status, reason, state}
      result -> result
    end
  end

  defp compaction_opts(run) do
    [
      snapshot: run.snapshot,
      event_callback: run.event_callback,
      before_provider_call: run.before_provider_call
    ]
    |> maybe_put_cancellation_signal(run.cancellation_signal)
  end

  defp call_llm(%State{} = state, run) do
    snapshot = run.snapshot
    system_prompt = snapshot.system_prompt

    # Each persisted turn is its own role-tagged map. Assistant tool calls and
    # tool results are linked by tool_call_id, and subsequent requests extend
    # this array without injecting or replacing synthetic messages. Compaction
    # may have replaced the array with a checkpoint plus a recent tail.
    structured_messages = Messages.to_provider(State.model_messages(state))

    response_schema =
      SystemPrompt.response_schema(
        prompt_renderer: snapshot.prompt_renderer,
        prompt_renderer_opts: snapshot.prompt_renderer_opts
      )

    tool_definitions = provider_tool_definitions(run.snapshot.tool_registry)
    native_tools? = tool_definitions != []

    generate_opts =
      LLM.request_opts(
        [
          model: snapshot.model,
          session_id: state.session_id,
          system: system_prompt,
          messages: structured_messages,
          native_tools: native_tools?,
          tools: tool_definitions
        ]
        |> maybe_put_cancellation_signal(run.cancellation_signal),
        [temperature: 0.3, strict_schema: false],
        Policy.sanitize_llm_opts(snapshot.llm_opts)
      )

    with :ok <- Tackle.Lib.ProviderGate.await(run.before_provider_call),
         false <- cancelled?(run) do
      if run.llm_stream? do
        pending_id = state.pending_assistant_id

        LLM.stream_with(
          snapshot.llm || snapshot.llm_adapter,
          response_schema,
          generate_opts,
          fn
            # The loop reports each response's usage once, when the response
            # settles (`emit_llm_settlement_events/3`). Streaming adapters and
            # the non-streaming fallback also report it, which would make
            # hosts that sum usage events count every response twice.
            %Event{type: :usage} ->
              :ok

            event ->
              event
              |> stamp_pending_id(pending_id)
              |> then(&emit(run, &1))
          end
        )
      else
        LLM.generate_with(
          snapshot.llm || snapshot.llm_adapter,
          response_schema,
          generate_opts
        )
      end
    else
      {:error, _reason} = error -> error
      true -> {:error, :cancelled}
    end
  end

  # Streaming delta events from the adapter carry no message id (the provider
  # doesn't know the id Tackle.Lib minted in :message_start). Stamp the pending
  # assistant id onto them so subscribers can route deltas to the correct
  # in-flight message bubble. Events that already carry an id are left as-is.
  defp stamp_pending_id(%Event{id: id} = event, _pending_id) when is_binary(id) and id != "",
    do: event

  defp stamp_pending_id(%Event{} = event, pending_id) when is_binary(pending_id),
    do: %{event | id: pending_id}

  defp stamp_pending_id(event, _pending_id), do: event

  defp handle_llm_response(state, response, run, result) do
    case get_tool_calls(response) do
      {:ok, tool_calls} ->
        handle_valid_llm_response(state, response, run, result, tool_calls)

      {:error, reason} ->
        fail(state, run, "Invalid provider tool calls: #{inspect(reason)}", reason)
    end
  end

  defp handle_valid_llm_response(state, response, run, result, tool_calls) do
    thinking = get_string_field(response, "thinking")
    content = get_string_field(response, "content")

    message_opts = [
      content: content,
      thinking: thinking,
      token_usage: Map.get(result, :usage),
      model: Map.get(result, :model),
      provider_state: Map.get(result, :provider_state),
      id: state.pending_assistant_id,
      id_generator: state.id_generator
    ]

    cond do
      tool_calls != [] ->
        run = %{run | empty_response_retried?: false}
        handle_tool_call_response(state, run, tool_calls, message_opts)

      content && content != "" ->
        run = %{run | empty_response_retried?: false}
        handle_content_response(state, run, content, message_opts)

      true ->
        handle_empty_response(state, run)
    end
  end

  defp handle_tool_call_response(state, run, tool_calls, message_opts) do
    # Assign ids to every tool call up front so the SAME id is stored on the
    # assistant message's tool_calls AND later threaded onto each tool result
    # (tool_call_id). This is the call->result linkage providers require; it is
    # what lets the next request carry a structured, correctly-paired history
    # instead of a flattened blob.
    tool_calls = Enum.map(tool_calls, &ensure_tool_call_id(&1, state))
    assistant_message = Message.assistant(Keyword.put(message_opts, :tool_calls, tool_calls))
    state = State.add_message(state, assistant_message)

    case emit_and_finalize_message(state, run, assistant_message) do
      {:ok, state} ->
        state =
          state
          |> clear_pending_assistant_id()
          |> State.set_status(:acting)

        emit(run, Event.new(:status_change, %{status: :acting}))

        case execute_tool_calls(state, tool_calls, run) do
          {:ok, state} -> loop(state, run)
          {:error, state} -> finish(:error, state, run)
          {:cancelled, state} -> cancel(state, run)
        end

      {:error, state} ->
        finish(:error, state, run)
    end
  end

  defp handle_content_response(state, run, content, message_opts) do
    assistant_message =
      message_opts
      |> Keyword.put(:content, content)
      |> Message.assistant()

    state =
      state
      |> State.add_message(assistant_message)
      |> State.set_status(:completed)

    finalize_completed_assistant_message(state, run, assistant_message)
  end

  # A response with neither content nor tool calls (a content filter, a
  # reasoning-only reply, or a server returning an empty message) is asked again
  # once, as a retry of the same request: the retry events let hosts discard any
  # text streamed for it. A second empty response in a row ends the turn rather
  # than inventing an answer or spending provider calls without bound.
  defp handle_empty_response(state, %Run{empty_response_retried?: false} = run) do
    Logger.warning("LLM response had neither tool calls nor content; asking again")
    run = %{run | empty_response_retried?: true}

    emit(
      run,
      Event.new(
        :retry_scheduled,
        %{attempt: 1, max_retries: 1, delay_ms: 0, reason: :empty_response},
        id: state.pending_assistant_id
      )
    )

    emit(run, Event.new(:retry_start, %{attempt: 1}, id: state.pending_assistant_id))
    handle_retry_result(call_llm(state, run), state, run, 1)
  end

  defp handle_empty_response(state, run),
    do: fail(state, run, "The model returned an empty response", :empty_response)

  defp finalize_completed_assistant_message(state, run, assistant_message) do
    case emit_and_finalize_message(state, run, assistant_message) do
      {:ok, state} ->
        state = clear_pending_assistant_id(state)
        continue_after_assistant(state, run)

      {:error, state} ->
        finish(:error, state, run)
    end
  end

  defp continue_after_assistant(state, run) do
    if cancelled?(run) do
      cancel(state, run)
    else
      case append_incoming_messages(state, run) do
        {:ok, state, 0} -> before_turn_end(state, run)
        {:ok, state, _count} -> continue_loop(state, run)
        {:error, state} -> finish(:error, state, run)
      end
    end
  end

  # Runs the `before_turn_end` hooks, which may continue the turn with feedback
  # messages (for example from a compile gate) instead of completing it.
  defp before_turn_end(state, run) do
    case Hook.invoke_before_turn_end(
           run.snapshot.hooks,
           state,
           hook_context(state, run)
         ) do
      {:ok, context, messages} ->
        state = %{state | context: state_context(context, state.context)}

        cond do
          cancelled?(run) ->
            cancel(state, run)

          messages == [] ->
            finish(:ok, state, run)

          true ->
            continue_after_turn_end_hooks(state, run, messages)
        end

      {:error, reason} ->
        fail(state, run, "Hook aborted before turn end: #{inspect(reason)}", reason)
    end
  end

  defp continue_after_turn_end_hooks(state, run, messages) do
    case append_incoming_batch(state, run, messages) do
      {:ok, state, _count} -> continue_loop(state, run)
      {:error, state} -> finish(:error, state, run)
    end
  end

  defp append_incoming_messages(state, %Run{take_incoming_messages: nil}),
    do: {:ok, state, 0}

  defp append_incoming_messages(state, run) do
    case take_incoming_messages(run) do
      {:ok, incoming} ->
        append_incoming_batch(state, run, incoming)

      {:error, reason} ->
        {:error, State.set_error(state, "Could not receive queued messages: #{inspect(reason)}")}
    end
  end

  # The host has handed these messages over, so every one of them is added to
  # the state before any is finalized: if a finalizing hook fails partway, the
  # rest are not lost from the returned state.
  defp append_incoming_batch(state, run, incoming) do
    messages = Enum.map(incoming, &Message.user(&1, id_generator: state.id_generator))
    state = Enum.reduce(messages, state, &State.add_message(&2, &1))

    Enum.reduce_while(messages, {:ok, state, 0}, fn message, {:ok, state, count} ->
      case emit_and_finalize_message(state, run, message) do
        {:ok, state} -> {:cont, {:ok, state, count + 1}}
        {:error, state} -> {:halt, {:error, state}}
      end
    end)
  end

  defp take_incoming_messages(%Run{take_incoming_messages: callback})
       when is_function(callback, 0) do
    case callback.() do
      {:ok, messages} when is_list(messages) -> validate_incoming_messages(messages)
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_incoming_messages, other}}
    end
  rescue
    error -> {:error, {:incoming_messages_callback_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:incoming_messages_callback_failed, {kind, reason}}}
  end

  defp validate_incoming_messages(messages) do
    if Enum.all?(messages, &(is_binary(&1) and &1 != "")) do
      {:ok, messages}
    else
      {:error, {:invalid_incoming_messages, messages}}
    end
  end

  defp get_string_field(response, key) do
    case response do
      %{^key => value} when is_binary(value) -> value
      map when is_map(map) -> Map.get(map, key)
    end
  end

  defp get_tool_calls(response) do
    raw_calls =
      case response do
        %{"tool_calls" => calls} when is_list(calls) -> calls
        %{tool_calls: calls} when is_list(calls) -> calls
        _ -> []
      end

    Enum.reduce_while(raw_calls, {:ok, []}, fn raw_call, {:ok, calls} ->
      case Call.normalize(raw_call) do
        {:ok, call} -> {:cont, {:ok, [call | calls]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp execute_tool_calls(%State{} = state, tool_calls, run) do
    case state.tool_policy do
      %Policy{execution_mode: :concurrent} ->
        execute_tool_calls_concurrently(state, tool_calls, run)

      %Policy{} ->
        execute_tool_calls_sequentially(state, tool_calls, run)
    end
  end

  defp execute_tool_calls_sequentially(state, tool_calls, run) do
    Enum.reduce_while(tool_calls, state, fn tool_call, acc_state ->
      execute_tool_call_until_cancelled(tool_call, acc_state, run)
    end)
    |> settle_tool_batch()
  end

  # Concurrent execution keeps the loop process as the only writer of `State`:
  # every call in the batch is prepared and dispatched here, tools settle in
  # supervised tasks, and the results are committed back in the model's order.
  defp execute_tool_calls_concurrently(state, tool_calls, run) do
    supervisor = run.tool_supervisor

    cond do
      is_nil(supervisor) ->
        raise ArgumentError,
              "concurrent tool execution requires a :tool_supervisor option; " <>
                "pass a Task.Supervisor or use the sequential tool policy"

      cancelled?(run) ->
        {:cancelled, cancel_state(state, run)}

      true ->
        run_concurrent_batch(tool_calls, state, run, supervisor)
    end
  end

  defp run_concurrent_batch(tool_calls, state, run, supervisor) do
    case prepare_tool_batch(tool_calls, state, run) do
      {:ok, jobs, state} ->
        case await_tool_gate(Enum.map(jobs, & &1.call), run) do
          :ok ->
            run_tool_jobs(jobs, state, run, supervisor)

          {:error, reason} ->
            # No job ran, so no settlement will delete the per-call signals.
            Enum.each(jobs, &Cancellation.delete(&1.call_signal))
            {:error, tool_gate_error(state, reason)}
        end

      {:cancelled, state} ->
        {:cancelled, state}

      {:abort, state} ->
        {:error, state}
    end
  end

  defp run_tool_jobs(jobs, state, run, supervisor) do
    if cancelled?(run) do
      Enum.each(jobs, &Cancellation.delete(&1.call_signal))
      {:cancelled, cancel_state(state, run)}
    else
      {settlements, outcome} =
        Batch.run(
          jobs,
          supervisor,
          &settle_tool_call/1,
          &emit_tool_execution_end(&1, run),
          fn -> cancelled?(run) end
        )

      state = commit_tool_batch(jobs, settlements, state, run)

      case {state.status, outcome} do
        {:error, _status} -> {:error, state}
        {_status, :cancelled} -> {:cancelled, cancel_state(state, run)}
        _other -> {:ok, state}
      end
    end
  end

  defp settle_tool_batch(%State{status: :cancelled} = state), do: {:cancelled, state}
  defp settle_tool_batch(%State{status: :error} = state), do: {:error, state}
  defp settle_tool_batch(%State{} = state), do: {:ok, state}

  # A turn that ends while tool calls are unresolved leaves an assistant
  # message whose calls have no results. Providers reject that history on the
  # next request, which makes a stopped session impossible to continue, so an
  # interrupted batch is settled with synthetic error results before the turn
  # terminates, and a turn starting from such a history settles them first.
  # The results go through the normal message finalization path, so durable
  # sessions persist them like any other tool result. A failing finalization
  # hook does not replace the outcome being settled.
  defp settle_unresolved_tool_calls(%State{} = state, run, outcome) do
    settled =
      state.messages
      |> Messages.unresolved_tool_calls()
      |> Enum.reduce(state, &settle_interrupted_tool_call(&1, &2, run, outcome))

    %{settled | status: state.status, error: state.error}
  end

  defp settle_interrupted_tool_call(%{id: id, name: name}, %State{} = state, run, outcome) do
    content = "Error: Tool execution was #{outcome} before this call completed."

    message =
      Message.tool_result(id, name, content, id_generator: state.id_generator)

    state = State.add_message(state, message)

    case emit_and_finalize_message(state, run, message) do
      {:ok, state} ->
        emit(
          run,
          Event.new(:tool_error, %{
            tool_call_id: id,
            name: name,
            error: content,
            reason: :interrupted
          })
        )

        state

      {:error, state} ->
        state
    end
  end

  defp execute_tool_call_until_cancelled(tool_call, state, run) do
    if cancelled?(run) do
      {:halt, cancel_state(state, run)}
    else
      tool_call
      |> execute_single_tool(state, run)
      |> continue_or_cancel(run)
    end
  end

  defp continue_or_cancel({:ok, %State{} = state}, run) do
    if cancelled?(run) do
      {:halt, cancel_state(state, run)}
    else
      {:cont, state}
    end
  end

  defp continue_or_cancel({status, %State{} = state}, _run)
       when status in [:abort, :cancelled],
       do: {:halt, state}

  defp ensure_tool_call_id(%Call{id: id} = call, _state) when is_binary(id) and id != "",
    do: call

  defp ensure_tool_call_id(%Call{} = call, state),
    do: %{call | id: generate_call_id(state)}

  defp execute_single_tool(%Call{arguments: _args} = tool_call, state, run) do
    tool_call_id = tool_call.id || generate_call_id(state)
    tool_call = %{tool_call | id: tool_call_id}

    with {:hook, {:ok, state}} <- {:hook, invoke_before_tool_call(state, tool_call, run)},
         {:gate, :ok, _state} <- {:gate, await_tool_gate([tool_call], run), state} do
      if cancelled?(run) do
        {:cancelled, cancel_state(state, run)}
      else
        do_execute_single_tool(tool_call, state, run)
      end
    else
      {:hook, {:error, reason}} ->
        {:abort, State.set_error(state, "Hook aborted before tool call: #{inspect(reason)}")}

      {:gate, {:error, reason}, state} ->
        {:abort, tool_gate_error(state, reason)}
    end
  end

  defp await_tool_gate(calls, run) do
    if Enum.any?(calls, &external_effect?(&1, run)),
      do: Tackle.Lib.ProviderGate.await(run.before_tool_execution, :before_tool_execution),
      else: :ok
  end

  # A call whose tool cannot be resolved never runs, so it has no effect to
  # guard. Anything the loop cannot classify is treated as external.
  defp external_effect?(%Call{} = call, run) do
    case Registry.resolve(run.snapshot.tool_registry, call) do
      {:ok, %{module: module}} -> Tool.effect(module) == :external
      {:error, _reason} -> false
    end
  catch
    _kind, _reason -> true
  end

  defp tool_gate_error(state, reason),
    do: State.set_error(state, "Tool execution gate failed: #{inspect(reason)}")

  defp do_execute_single_tool(%Call{name: name, arguments: args} = tool_call, state, run) do
    emit(
      run,
      Event.new(:tool_start, %{tool_call_id: tool_call.id, name: name, arguments: args})
    )

    settlement = tool_call |> execution_job(state, run) |> settle_tool_call()
    emit_tool_execution_end(settlement, run)
    append_tool_settlement(settlement, state, run)
  end

  # ── Concurrent batch ──────────────────────────────────────────────────

  # Runs every `before_tool_call` hook up front, emits each `tool_start`, and
  # captures one execution job per call. Hooks are gates, so an abort anywhere in
  # the batch stops the whole batch before any tool runs.
  defp prepare_tool_batch(tool_calls, state, run) do
    Enum.reduce_while(Enum.with_index(tool_calls), {:ok, [], state}, fn {call, index},
                                                                        {:ok, jobs, acc_state} ->
      tool_call = %{call | id: call.id || generate_call_id(acc_state)}

      case invoke_before_tool_call(acc_state, tool_call, run) do
        {:ok, acc_state} ->
          if cancelled?(run) do
            {:halt, {:cancelled, cancel_state(acc_state, run)}}
          else
            prepare_tool_job(tool_call, index, jobs, acc_state, run)
          end

        {:error, reason} ->
          {:halt,
           {:abort,
            State.set_error(acc_state, "Hook aborted before tool call: #{inspect(reason)}")}}
      end
    end)
    |> case do
      {:ok, jobs, state} -> {:ok, Enum.reverse(jobs), state}
      {:cancelled, state} -> {:cancelled, state}
      {:abort, state} -> {:abort, state}
    end
  end

  defp prepare_tool_job(tool_call, index, jobs, acc_state, run) do
    emit(
      run,
      Event.new(:tool_start, %{
        tool_call_id: tool_call.id,
        name: tool_call.name,
        arguments: tool_call.arguments
      })
    )

    job = Map.put(execution_job(tool_call, acc_state, run), :index, index)
    {:cont, {:ok, [job | jobs], acc_state}}
  end

  # Execution progress is transient and may arrive out of call order. Keep it
  # separate from tool_end/tool_error, which follow ordered message persistence.
  # Only the loop emits these events, never the worker tasks.
  defp emit_tool_execution_end({:ok, %ToolResult{} = result}, run) do
    emit(
      run,
      Event.new(:tool_execution_end, %{
        tool_call_id: result.tool_call_id,
        name: result.name,
        status: :completed,
        result: result.content
      })
    )
  end

  defp emit_tool_execution_end({:error, %ToolError{} = error}, run) do
    emit(
      run,
      Event.new(:tool_execution_end, %{
        tool_call_id: error.tool_call_id,
        name: error.name || "unknown",
        status: :failed,
        error: error.message,
        reason: error.reason
      })
    )
  end

  # Commits every available settlement in call order. A cancelled batch can lack
  # settlements for tools that never finished; those calls are skipped so a tool
  # that did run still records its result.
  defp commit_tool_batch(jobs, settlements, state, run) do
    Enum.reduce_while(jobs, state, fn %{index: index}, acc_state ->
      case Map.fetch(settlements, index) do
        {:ok, settlement} -> commit_tool_settlement(settlement, acc_state, run)
        :error -> {:cont, acc_state}
      end
    end)
  end

  defp commit_tool_settlement(settlement, acc_state, run) do
    case append_tool_settlement(settlement, acc_state, run) do
      {:ok, acc_state} -> {:cont, acc_state}
      {:abort, acc_state} -> {:halt, acc_state}
    end
  end

  # The loop owns transcript state; tool tasks receive only the resolved call,
  # execution context, and telemetry inputs. Hooks may update context between
  # calls, so each job is built after its before_tool_call hook has run.
  defp execution_job(%Call{name: name} = call, state, run) do
    # Preserve the task's exception telemetry and crash settlement if preparing
    # a call fails (for example, an invalid host execution context).
    call_signal = Cancellation.for_call(run.cancellation_signal, call.id)

    execution =
      try do
        case Registry.resolve(run.snapshot.tool_registry, call) do
          {:ok, %{module: module}} ->
            {:ok, module, tool_context(state, run, call, call_signal)}

          {:error, reason} ->
            {:error, reason}
        end
      catch
        kind, reason -> {:raise, kind, reason, __STACKTRACE__}
      end

    %{
      call: call,
      call_signal: call_signal,
      execution: execution,
      telemetry_name: telemetry_tool_name(name, state.context),
      telemetry_adapter: get_in(state.context, [:telemetry, :adapter])
    }
  end

  # Runs one call's settle pipeline (execute, validate, telemetry).
  # Sequential execution calls this inline; concurrent execution calls it inside a
  # supervised task. It never touches agent state or emits agent events. Once the
  # call settles, its per-call cancellation record (if a host cancelled it) is no
  # longer observed by anyone, so it is deleted.
  defp settle_tool_call(%{call_signal: call_signal} = job) do
    settle_tool_call_job(job)
  after
    Cancellation.delete(call_signal)
  end

  defp settle_tool_call_job(%{
         call: tool_call,
         execution: execution,
         telemetry_name: telemetry_name,
         telemetry_adapter: telemetry_adapter
       }) do
    telemetry_ref = Telemetry.start([:tackle, :tool, :execution], %{tool_name: telemetry_name})
    started_at = System.monotonic_time()

    try do
      settlement =
        with_tool_telemetry_context(telemetry_adapter, telemetry_ref, fn ->
          case execution do
            {:ok, tool_module, context} -> Tool.settle(tool_module, tool_call, context)
            {:error, reason} -> registry_error(tool_call, reason)
            {:raise, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
          end
        end)

      Telemetry.stop(
        [:tackle, :tool, :execution],
        telemetry_ref,
        %{duration: Telemetry.monotonic_duration(started_at), count: 1},
        %{tool_name: telemetry_name, outcome: tool_outcome(settlement)}
      )

      settlement
    catch
      # Tool.settle/3 turns a tool's own failures into error results. What is
      # left (preparing the call's context failed, or a telemetry adapter
      # crashed) settles the call as crashed under either execution policy, so
      # one call cannot take down the loop and leave its batch unresolved.
      kind, reason ->
        stacktrace = __STACKTRACE__

        Telemetry.exception(
          [:tackle, :tool, :execution],
          telemetry_ref,
          %{duration: Telemetry.monotonic_duration(started_at), count: 1},
          %{tool_name: telemetry_name, error_type: kind}
        )

        Logger.error(fn ->
          [
            "Tool call ",
            inspect(tool_call.name),
            " crashed: ",
            Exception.format(kind, reason, stacktrace)
          ]
        end)

        {:error, ToolError.crashed(tool_call, kind, reason)}
    end
  end

  defp with_tool_telemetry_context(adapter, telemetry_ref, fun)
       when is_reference(telemetry_ref) and is_function(fun, 0) do
    if is_atom(adapter) and not is_nil(adapter) do
      adapter.with_context(telemetry_ref, fun)
    else
      fun.()
    end
  end

  defp telemetry_tool_name(name, context) when is_binary(name) do
    allowed_names = get_in(context, [:telemetry, :tool_names]) || []
    if name in allowed_names, do: name, else: "other"
  end

  defp telemetry_tool_name(_name, _state), do: "other"

  defp tool_outcome({:ok, %ToolResult{}}), do: :success
  defp tool_outcome({:error, %ToolError{reason: reason}}), do: bounded_tool_error(reason)
  defp tool_outcome(_settlement), do: :execution_error

  defp bounded_tool_error(reason)
       when reason in [
              :invalid_input,
              :invalid_output,
              :execution_error,
              :unknown_tool,
              :stale_tool_definition
            ],
       do: reason

  defp bounded_tool_error(_reason), do: :execution_error

  defp provider_tool_definitions(%Registry{} = registry) do
    Registry.definitions(registry)
  end

  defp append_tool_settlement({:ok, %ToolResult{} = result}, state, run) do
    tool_message =
      Message.tool_result(result.tool_call_id, result.name, result.content,
        id_generator: state.id_generator,
        parts: result.parts
      )

    event =
      Event.new(:tool_end, %{
        tool_call_id: result.tool_call_id,
        name: result.name,
        result: result.content,
        raw: result.raw,
        metadata: result.metadata
      })

    finalize_tool_settlement(state, run, tool_message, event, result)
  end

  defp append_tool_settlement({:error, %ToolError{} = error}, state, run) do
    name = error.name || "unknown"

    tool_message =
      Message.tool_result(error.tool_call_id, name, error.content,
        id_generator: state.id_generator
      )

    event =
      Event.new(:tool_error, %{
        tool_call_id: error.tool_call_id,
        name: name,
        error: error.message,
        reason: error.reason,
        details: error.details,
        metadata: error.metadata
      })

    finalize_tool_settlement(state, run, tool_message, event, error)
  end

  defp finalize_tool_settlement(state, run, tool_message, event, settlement) do
    state = State.add_message(state, tool_message)

    case emit_and_finalize_message(state, run, tool_message) do
      {:ok, state} ->
        emit(run, event)

        case invoke_after_tool_call(state, settlement, run) do
          {:ok, state} ->
            {:ok, state}

          {:error, reason} ->
            {:abort, State.set_error(state, "Hook aborted after tool call: #{inspect(reason)}")}
        end

      {:error, state} ->
        {:abort, state}
    end
  end

  defp registry_error(%Call{} = call, :unknown_tool) do
    {:error,
     %ToolError{
       tool_call_id: call.id,
       name: call.name,
       reason: :unknown_tool,
       message: "Unknown tool: #{call.name}",
       content: "Error: Unknown tool: #{call.name}",
       metadata: %{definition_id: call.definition_id}
     }}
  end

  defp registry_error(%Call{} = call, :stale_tool_definition) do
    {:error,
     %ToolError{
       tool_call_id: call.id,
       name: call.name,
       reason: :stale_tool_definition,
       message: "Stale tool definition for #{call.name}; ask for the current tool list and retry",
       content:
         "Error: Stale tool definition for #{call.name}; ask for the current tool list and retry",
       metadata: %{definition_id: call.definition_id}
     }}
  end

  defp maybe_put_cancellation_signal(opts, nil), do: opts

  defp maybe_put_cancellation_signal(opts, signal),
    do: Keyword.put(opts, :cancellation_signal, signal)

  # Tools see the state's context with the run's `:tool_context` merged over
  # it, and the loop's own keys on top: the run's event callback, so a tool can
  # report progress through the same path as the loop, and the call's id.
  # Tools receive their call's child signal: it observes turn cancellation and
  # can also be cancelled on its own to stop just this call. The loop's boundary
  # checks keep using the turn signal.
  defp tool_context(%State{} = state, %Run{} = run, %Call{} = tool_call, call_signal) do
    context =
      state.context
      |> Map.merge(run.tool_context)
      |> Map.put(:event_callback, run.event_callback)
      |> Map.put(:tool_call_id, tool_call.id)

    case call_signal do
      nil -> context
      signal -> Map.put(context, :cancellation_signal, signal)
    end
  end

  defp cancelled?(%Run{cancellation_signal: signal}), do: Cancellation.cancelled?(signal)

  defp cancel_state(%State{} = state, run) do
    reason = run.cancellation_signal |> Cancellation.reason() |> cancellation_reason()
    State.set_cancelled(state, reason)
  end

  defp cancellation_reason(nil), do: "Cancelled"
  defp cancellation_reason(reason) when is_binary(reason), do: reason
  defp cancellation_reason(reason), do: inspect(reason)

  # Events are observations: a crashing host callback is logged and the turn
  # goes on, so an observer's bug cannot leave the transcript half-settled.
  defp emit(run, %Event{} = event) do
    run.event_callback.(event)
    :ok
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        [
          "Event callback crashed on ",
          inspect(event.type),
          ": ",
          Exception.format(kind, reason, stacktrace)
        ]
      end)

      :ok
  end

  defp emit_llm_settlement_events(run, %State{} = state, result) do
    usage = Map.get(result, :usage)

    if usage do
      emit(run, Event.usage(usage))
    end

    emit(
      run,
      Event.new(:step_end, %{
        iteration: state.current_iteration,
        usage: usage,
        model: Map.get(result, :model),
        provider: Map.get(result, :provider)
      })
    )
  end

  defp generate_call_id(%State{id_generator: id_generator}), do: id_generator.()

  # --- Hook invocations ---

  defp invoke_before_prompt(%State{} = state, run) do
    invoke_hook(state, run, :before_prompt, [state])
  end

  defp invoke_after_prompt(%State{} = state, response, run) do
    invoke_hook(state, run, :after_prompt, [state, response])
  end

  defp invoke_before_tool_call(%State{} = state, %Call{} = tool_call, run) do
    invoke_hook(state, run, :before_tool_call, [state, tool_call])
  end

  defp invoke_after_tool_call(%State{} = state, tool_result, run) do
    invoke_hook(state, run, :after_tool_call, [state, tool_result])
  end

  defp invoke_after_message(%State{} = state, %Message{} = message, run) do
    invoke_hook(state, run, :after_message, [state, message])
  end

  defp invoke_hook(%State{} = state, run, event, args) do
    case Hook.invoke(run.snapshot.hooks, event, args, hook_context(state, run)) do
      {:ok, context} -> {:ok, %{state | context: state_context(context, state.context)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Hooks see the run's cancellation signal, so a slow hook (such as a gate that
  # compiles the project) can stop early. The signal belongs to this run and is
  # not kept in the state's context, unless the host put that key there itself.
  defp hook_context(%State{context: %{cancellation_signal: _} = context}, _run),
    do: context

  defp hook_context(%State{context: context}, %Run{cancellation_signal: signal})
       when not is_nil(signal),
       do: Map.put(context, :cancellation_signal, signal)

  defp hook_context(%State{context: context}, _run), do: context

  defp state_context(context, %{cancellation_signal: _}), do: context
  defp state_context(context, _original), do: Map.delete(context, :cancellation_signal)

  defp emit_and_finalize_message(%State{} = state, run, %Message{} = message) do
    emit(run, Event.message_end(message))

    case invoke_after_message(state, message, run) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:error, State.set_error(state, "Hook aborted after message: #{inspect(reason)}")}
    end
  end

  defp clear_pending_assistant_id(%State{} = state) do
    %{state | pending_assistant_id: nil}
  end

  # --- Turn end ---

  defp cancel(%State{} = state, run),
    do: finish(:cancelled, cancel_state(state, run), run)

  defp fail(%State{} = state, run, message, reason),
    do: finish(:error, State.set_error(state, message), run, reason)

  # Every turn ends here, whatever the outcome: an assistant message that was
  # started is no longer pending, tool calls left without results are settled,
  # the outcome's events are emitted (an error outcome reports the error with
  # its `reason`, when there is one), and the `after_turn` hooks run last.
  defp finish(outcome, %State{} = state, run, reason \\ nil)
       when outcome in [:ok, :error, :cancelled] do
    state = clear_pending_assistant_id(state)

    state =
      if outcome == :ok,
        do: state,
        else: settle_unresolved_tool_calls(state, run, interrupted_as(outcome))

    emit_turn_end(outcome, state, run, reason)

    state =
      case Hook.invoke(run.snapshot.hooks, :after_turn, [state], state.context) do
        {:ok, context} -> %{state | context: context}
        _ -> state
      end

    {outcome, state}
  end

  defp interrupted_as(:error), do: "aborted"
  defp interrupted_as(:cancelled), do: "cancelled"

  defp emit_turn_end(:ok, state, run, _reason) do
    emit(run, Event.new(:status_change, %{status: :completed}))
    emit(run, Event.new(:turn_end, %{session_id: state.session_id, status: :completed}))
  end

  defp emit_turn_end(:cancelled, state, run, _reason) do
    emit(run, Event.new(:status_change, %{status: :cancelled}))

    emit(
      run,
      Event.new(:turn_cancelled, %{session_id: state.session_id, reason: state.error})
    )

    emit(run, Event.new(:turn_end, %{session_id: state.session_id, status: :cancelled}))
  end

  defp emit_turn_end(:error, state, run, reason) do
    data =
      if is_nil(reason), do: %{error: state.error}, else: %{error: state.error, reason: reason}

    emit(run, Event.new(:error, data))
    emit(run, Event.new(:status_change, %{status: :error}))
    emit(run, Event.new(:turn_end, %{session_id: state.session_id, status: :error}))
  end
end
