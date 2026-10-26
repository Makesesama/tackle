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

  alias Tackle.Lib.Compaction
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Event
  alias Tackle.Lib.Hook
  alias Tackle.Lib.LLM
  alias Tackle.Lib.Message
  alias Tackle.Lib.Loop.Run
  alias Tackle.Lib.Loop.Tools
  alias Tackle.Lib.Messages
  alias Tackle.Lib.Retry
  alias Tackle.Lib.State
  alias Tackle.Lib.SystemPrompt
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Registry

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
    * `:tool_supervisor` - `Task.Supervisor` used when the state's tool policy is
      `:concurrent`; without one, a concurrent policy raises `ArgumentError` before
      the turn starts. Ignored (and not required) for the default sequential policy.
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

    Run.emit(run, Event.new(:turn_start, %{session_id: state.session_id}))

    if Run.cancelled?(run) do
      cancel(state, run)
    else
      state = Tools.settle_interrupted(state, run, "interrupted")
      user_message = Message.user(user_input, id_generator: state.id_generator)
      state = State.add_message(state, user_message)

      case Run.finalize_message(state, run, user_message) do
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

    Run.emit(run, Event.new(:turn_start, %{session_id: state.session_id}))

    state
    |> Tools.settle_interrupted(run, "interrupted")
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
    if Run.cancelled?(run) do
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
      Run.cancelled?(run) ->
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

    Run.emit(run, Event.new(:status_change, %{status: :thinking}))

    assistant_id = state.id_generator.()
    state = %{state | pending_assistant_id: assistant_id}
    Run.emit(run, Event.message_start(id: assistant_id, role: :assistant))

    Run.emit(run, Event.new(:step_start, %{iteration: state.current_iteration}))

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
          Run.cancelled?(run) or recoverable_overflow?(state, reason, run) ->
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

    Run.emit(
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
        if Run.cancelled?(run) do
          emit_retry_end(run, false, attempt, reason)
          handle_llm_call_result({:error, reason}, state, run)
        else
          Run.emit(
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
      Run.cancelled?(run) or recoverable_overflow?(state, reason, run) ->
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
    Run.emit(run, Event.new(:retry_end, data))
  end

  defp handle_llm_call_result({:ok, %{data: response} = result}, state, run) do
    if Run.cancelled?(run) do
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
      Run.cancelled?(run) ->
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

    Run.emit(run, Event.new(:compaction_retry, %{trigger: :overflow, reason: reason}))

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
         false <- Run.cancelled?(run) do
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
              |> then(&Run.emit(run, &1))
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

    case Run.finalize_message(state, run, assistant_message) do
      {:ok, state} ->
        state =
          state
          |> clear_pending_assistant_id()
          |> State.set_status(:acting)

        Run.emit(run, Event.new(:status_change, %{status: :acting}))

        case Tools.execute(state, tool_calls, run) do
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

    Run.emit(
      run,
      Event.new(
        :retry_scheduled,
        %{attempt: 1, max_retries: 1, delay_ms: 0, reason: :empty_response},
        id: state.pending_assistant_id
      )
    )

    Run.emit(run, Event.new(:retry_start, %{attempt: 1}, id: state.pending_assistant_id))
    handle_retry_result(call_llm(state, run), state, run, 1)
  end

  defp handle_empty_response(state, run),
    do: fail(state, run, "The model returned an empty response", :empty_response)

  defp finalize_completed_assistant_message(state, run, assistant_message) do
    case Run.finalize_message(state, run, assistant_message) do
      {:ok, state} ->
        state = clear_pending_assistant_id(state)
        continue_after_assistant(state, run)

      {:error, state} ->
        finish(:error, state, run)
    end
  end

  defp continue_after_assistant(state, run) do
    if Run.cancelled?(run) do
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
           Run.hook_context(state, run)
         ) do
      {:ok, context, messages} ->
        state = Run.put_hook_context(state, context)

        cond do
          Run.cancelled?(run) ->
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
      case Run.finalize_message(state, run, message) do
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

  defp ensure_tool_call_id(%Call{id: id} = call, _state) when is_binary(id) and id != "",
    do: call

  defp ensure_tool_call_id(%Call{} = call, state),
    do: %{call | id: generate_call_id(state)}

  defp provider_tool_definitions(%Registry{} = registry) do
    Registry.definitions(registry)
  end

  defp maybe_put_cancellation_signal(opts, nil), do: opts

  defp maybe_put_cancellation_signal(opts, signal),
    do: Keyword.put(opts, :cancellation_signal, signal)

  defp emit_llm_settlement_events(run, %State{} = state, result) do
    usage = Map.get(result, :usage)

    if usage do
      Run.emit(run, Event.usage(usage))
    end

    Run.emit(
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
    Run.invoke_hook(state, run, :before_prompt, [state])
  end

  defp invoke_after_prompt(%State{} = state, response, run) do
    Run.invoke_hook(state, run, :after_prompt, [state, response])
  end

  defp clear_pending_assistant_id(%State{} = state) do
    %{state | pending_assistant_id: nil}
  end

  # --- Turn end ---

  defp cancel(%State{} = state, run),
    do: finish(:cancelled, Run.mark_cancelled(state, run), run)

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
        else: Tools.settle_interrupted(state, run, interrupted_as(outcome))

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
    Run.emit(run, Event.new(:status_change, %{status: :completed}))
    Run.emit(run, Event.new(:turn_end, %{session_id: state.session_id, status: :completed}))
  end

  defp emit_turn_end(:cancelled, state, run, _reason) do
    Run.emit(run, Event.new(:status_change, %{status: :cancelled}))

    Run.emit(
      run,
      Event.new(:turn_cancelled, %{session_id: state.session_id, reason: state.error})
    )

    Run.emit(run, Event.new(:turn_end, %{session_id: state.session_id, status: :cancelled}))
  end

  defp emit_turn_end(:error, state, run, reason) do
    data =
      if is_nil(reason), do: %{error: state.error}, else: %{error: state.error, reason: reason}

    Run.emit(run, Event.new(:error, data))
    Run.emit(run, Event.new(:status_change, %{status: :error}))
    Run.emit(run, Event.new(:turn_end, %{session_id: state.session_id, status: :error}))
  end
end
