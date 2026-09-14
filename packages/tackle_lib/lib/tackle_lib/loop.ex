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
  alias Tackle.Lib.JSON
  alias Tackle.Lib.LLM
  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages
  alias Tackle.Lib.Retry
  alias Tackle.Lib.Snapshot
  alias Tackle.Lib.State
  alias Tackle.Lib.SystemPrompt
  alias Tackle.Lib.Telemetry
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error, as: ToolError
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Registry
  alias Tackle.Lib.Tool.Result, as: ToolResult

  @doc """
  Runs the agent loop for a user query.

  ## Options
    * `:event_callback` - Function called with `%Tackle.Lib.Event{}` structs.
    * `:event_context` - Additional host context merged into tool execution context.
    * `:llm_stream` - When true, use `Tackle.Lib.LLM.stream/4` if the adapter supports it.
    * `:cancellation_signal` - Optional `Tackle.Lib.Cancellation.Signal` checked between loop steps.
    * `:turn_id` - Host-assigned turn id stored on the per-turn snapshot. When omitted,
      the state's configured id generator is used.
    * `:tool_supervisor` - Optional `Task.Supervisor` used when the state's tool policy is
      `:concurrent`. Ignored (and not required) for the default sequential policy.
    * `:take_incoming_messages` - Optional zero-arity host callback returning
      `{:ok, [message]}` or `{:error, reason}`. Incoming text is appended as user
      messages immediately before the next provider call. The callback is polled
      before the first call, after each complete tool batch, and after a final
      assistant response so steering never interrupts an executing tool batch.
  """
  @spec run(State.t(), String.t(), keyword()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()}
  def run(%State{} = state, user_input, opts \\ []) do
    callbacks = callbacks(opts)
    snapshot = Snapshot.capture(state, turn_id: Keyword.get(opts, :turn_id))
    callbacks = Map.put(callbacks, :snapshot, snapshot)
    state = %{state | pending_assistant_id: nil, snapshot: snapshot, overflow_retries: 0}

    emit(callbacks, Event.new(:turn_start, %{session_id: state.session_id}))

    if cancelled?(callbacks) do
      do_after_turn(state, cancel_run(state, callbacks), callbacks)
    else
      user_message = Message.user(user_input, id_generator: state.id_generator)
      state = State.add_message(state, user_message)

      case emit_and_finalize_message(state, callbacks, user_message) do
        {:ok, state} ->
          loop(state, callbacks)

        {:error, state} ->
          {:error, do_after_turn_cleanup(state, callbacks)}
      end
    end
  end

  @doc """
  Re-runs the agent loop against existing state WITHOUT appending a new user
  message. Used to retry a turn that errored: the user message is already in
  state, so we resume the loop directly. Resets the iteration counter so the
  retry gets a full budget.
  """
  @spec continue(State.t(), keyword()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()}
  def continue(%State{} = state, opts \\ []) do
    callbacks = callbacks(opts)
    snapshot = continue_snapshot(state, Keyword.get(opts, :turn_id))
    callbacks = Map.put(callbacks, :snapshot, snapshot)

    state = %{
      state
      | current_iteration: 0,
        status: :idle,
        error: nil,
        pending_assistant_id: nil,
        snapshot: snapshot,
        overflow_retries: 0
    }

    loop(state, callbacks)
  end

  defp continue_snapshot(%State{snapshot: %Snapshot{} = snapshot}, turn_id)
       when is_binary(turn_id) and turn_id != "",
       do: %{snapshot | turn_id: turn_id}

  defp continue_snapshot(%State{snapshot: %Snapshot{} = snapshot}, _turn_id), do: snapshot

  defp continue_snapshot(%State{} = state, turn_id),
    do: Snapshot.capture(state, turn_id: turn_id)

  defp loop(%State{} = state, callbacks) do
    if cancelled?(callbacks) do
      do_after_turn(state, cancel_run(state, callbacks), callbacks)
    else
      case append_incoming_messages(state, callbacks) do
        {:ok, state, _count} ->
          continue_loop(state, callbacks)

        {:error, reason, state} ->
          final_state =
            State.set_error(state, "Could not receive queued messages: #{inspect(reason)}")

          {:error, do_after_turn_cleanup(final_state, callbacks)}
      end
    end
  end

  defp continue_loop(%State{} = state, callbacks) do
    cond do
      cancelled?(callbacks) ->
        do_after_turn(state, cancel_run(state, callbacks), callbacks)

      State.max_iterations_reached?(state) ->
        Logger.warning("Agent reached max iterations (#{state.max_iterations})")
        final_state = State.set_error(state, "Reached maximum iterations without completing")
        {:error, do_after_turn_cleanup(final_state, callbacks)}

      true ->
        iterate(state, callbacks)
    end
  end

  defp iterate(state, callbacks) do
    state = State.increment_iteration(state)
    state = State.set_status(state, :thinking)

    emit(callbacks, Event.new(:status_change, %{status: :thinking}))

    assistant_id = state.id_generator.()
    state = %{state | pending_assistant_id: assistant_id}
    emit(callbacks, Event.message_start(id: assistant_id, role: :assistant))

    emit(callbacks, Event.new(:step_start, %{iteration: state.current_iteration}))

    case maybe_auto_compact(state, callbacks) do
      {:ok, state} ->
        before_prompt(state, callbacks)

      {:error, reason} ->
        final_state = State.set_error(state, "Compaction failed: #{inspect(reason)}")
        {:error, do_after_turn_cleanup(final_state, callbacks)}

      {:cancelled, reason} ->
        do_after_turn(state, cancel_run(%{state | error: reason}, callbacks), callbacks)
    end
  end

  defp before_prompt(state, callbacks) do
    case invoke_before_prompt(state, callbacks) do
      {:ok, state} ->
        call_provider(state, callbacks)

      {:error, reason} ->
        final_state = State.set_error(state, "Hook aborted before prompt: #{inspect(reason)}")
        {:error, do_after_turn_cleanup(final_state, callbacks)}
    end
  end

  defp call_provider(state, callbacks) do
    case call_llm(state, callbacks) do
      {:error, reason} = error ->
        cond do
          cancelled?(callbacks) or recoverable_overflow?(state, reason, callbacks) ->
            handle_llm_call_result(error, state, callbacks)

          Retry.available?(snapshot(callbacks).retry, 0) and Retry.retryable?(reason) ->
            retry_llm(state, callbacks, reason, 1)

          true ->
            handle_llm_call_result(error, state, callbacks)
        end

      result ->
        handle_llm_call_result(result, state, callbacks)
    end
  end

  defp retry_llm(state, callbacks, reason, attempt) do
    retry = snapshot(callbacks).retry
    delay_ms = Retry.delay(retry, attempt)

    emit(
      callbacks,
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

    case Retry.wait(delay_ms, callbacks.cancellation_signal) do
      :ok ->
        if cancelled?(callbacks) do
          emit_retry_end(callbacks, false, attempt, reason)
          handle_llm_call_result({:error, reason}, state, callbacks)
        else
          emit(
            callbacks,
            Event.new(:retry_start, %{attempt: attempt}, id: state.pending_assistant_id)
          )

          handle_retry_result(call_llm(state, callbacks), state, callbacks, attempt)
        end

      {:cancelled, _reason} ->
        emit_retry_end(callbacks, false, attempt, reason)
        handle_llm_call_result({:error, reason}, state, callbacks)
    end
  end

  defp handle_retry_result({:error, reason} = error, state, callbacks, attempt) do
    retry = snapshot(callbacks).retry

    cond do
      cancelled?(callbacks) or recoverable_overflow?(state, reason, callbacks) ->
        emit_retry_end(callbacks, false, attempt, reason)
        handle_llm_call_result(error, state, callbacks)

      Retry.available?(retry, attempt) and Retry.retryable?(reason) ->
        retry_llm(state, callbacks, reason, attempt + 1)

      true ->
        emit_retry_end(callbacks, false, attempt, reason)
        handle_llm_call_result(error, state, callbacks)
    end
  end

  defp handle_retry_result(result, state, callbacks, attempt) do
    emit_retry_end(callbacks, true, attempt, nil)
    handle_llm_call_result(result, state, callbacks)
  end

  defp emit_retry_end(callbacks, success?, attempt, reason) do
    data = %{success?: success?, attempt: attempt}
    data = if is_nil(reason), do: data, else: Map.put(data, :reason, reason)
    emit(callbacks, Event.new(:retry_end, data))
  end

  defp handle_llm_call_result({:ok, %{data: response} = result}, state, callbacks) do
    if cancelled?(callbacks) do
      do_after_turn(clear_pending_assistant_id(state), cancel_run(state, callbacks), callbacks)
    else
      emit_llm_settlement_events(callbacks, state, result)

      case invoke_after_prompt(state, response, callbacks) do
        {:ok, state} ->
          handle_llm_response(state, response, callbacks, result)

        {:error, reason} ->
          final_state = State.set_error(state, "Hook aborted after prompt: #{inspect(reason)}")
          {:error, do_after_turn_cleanup(final_state, callbacks)}
      end
    end
  end

  defp handle_llm_call_result({:error, reason}, state, callbacks) do
    cond do
      cancelled?(callbacks) ->
        do_after_turn(clear_pending_assistant_id(state), cancel_run(state, callbacks), callbacks)

      recoverable_overflow?(state, reason, callbacks) ->
        recover_overflow(state, reason, callbacks)

      true ->
        Logger.error("LLM call failed: #{inspect(reason)}")

        final_state =
          State.set_error(
            clear_pending_assistant_id(state),
            "Failed to get response: #{inspect(reason)}"
          )

        error_event = Event.new(:error, %{error: final_state.error, reason: reason})
        emit(callbacks, error_event)
        {:error, do_after_turn_cleanup(final_state, callbacks)}
    end
  end

  # Provider-confirmed context overflow is distinct from proactive pressure. A
  # single compact-and-retry is allowed per turn: bypass the normal threshold,
  # compact once, and reissue the same request. Any compaction failure keeps the
  # original provider error.
  defp recover_overflow(state, reason, callbacks) do
    Logger.warning("Provider reported context overflow; attempting one compaction retry")

    emit(callbacks, Event.new(:compaction_retry, %{trigger: :overflow, reason: reason}))

    case Compaction.compact(state, :overflow, compaction_opts(state, callbacks)) do
      {:ok, state, _record} ->
        state = %{state | overflow_retries: state.overflow_retries + 1}
        call_provider(state, callbacks)

      {:error, {:durable_commit_failed, _reason} = error} ->
        final_state = State.set_error(clear_pending_assistant_id(state), inspect(error))
        {:error, do_after_turn_cleanup(final_state, callbacks)}

      {:cancelled, _reason} ->
        do_after_turn(clear_pending_assistant_id(state), cancel_run(state, callbacks), callbacks)

      {:error, _compaction_reason} ->
        final_state =
          State.set_error(
            clear_pending_assistant_id(state),
            "Failed to get response: #{inspect(reason)}"
          )

        emit(
          callbacks,
          Event.new(:error, %{error: final_state.error, reason: reason})
        )

        {:error, do_after_turn_cleanup(final_state, callbacks)}
    end
  end

  defp recoverable_overflow?(%State{} = state, reason, callbacks) do
    LLM.context_window_exceeded?(reason) and overflow_retries_remaining?(state, callbacks)
  end

  defp overflow_retries_remaining?(%State{} = state, callbacks) do
    case Compaction.resolve(state, snapshot: snapshot(callbacks)) do
      {:ok, resolved, _info} -> state.overflow_retries < resolved.overflow_retry_limit
      {:error, _reason} -> false
    end
  end

  defp maybe_auto_compact(state, callbacks) do
    with true <- Compaction.enabled?(state),
         {:ok, resolved, info} <- Compaction.resolve(state, snapshot: snapshot(callbacks)),
         true <- resolved.usable?,
         %ContextUsage{tokens: tokens} <- ContextUsage.estimate(state, info),
         true <- Compaction.Policy.pressure?(resolved, tokens) do
      case Compaction.compact(state, :pressure, compaction_opts(state, callbacks)) do
        {:ok, state, _record} ->
          {:ok, state}

        {:error, {:durable_commit_failed, _reason} = error} ->
          {:error, error}

        {:cancelled, reason} ->
          {:cancelled, reason}

        {:error, _reason} ->
          # A summary/validation failure leaves the model surface unchanged; the
          # request proceeds and may still fit. Only durability failures are fatal.
          {:ok, state}
      end
    else
      _skip -> {:ok, state}
    end
  end

  defp compaction_opts(_state, callbacks) do
    [snapshot: snapshot(callbacks), event_callback: callbacks.event]
    |> maybe_put_cancellation_signal(callbacks.cancellation_signal)
  end

  defp call_llm(%State{} = state, callbacks) do
    snapshot = snapshot(callbacks)
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

    tool_definitions = provider_tool_definitions(tool_registry(callbacks))
    native_tools? = tool_definitions != []

    generate_opts =
      [
        model: snapshot.model,
        session_id: state.session_id,
        system: system_prompt,
        messages: structured_messages,
        temperature: 0.3,
        strict_schema: false,
        native_tools: native_tools?,
        tools: tool_definitions
      ]
      |> maybe_put_cancellation_signal(callbacks.cancellation_signal)
      |> Kernel.++(Policy.sanitize_llm_opts(snapshot.llm_opts))

    if callbacks.llm_stream? do
      pending_id = state.pending_assistant_id

      LLM.stream_with(
        snapshot.llm || snapshot.llm_adapter,
        response_schema,
        generate_opts,
        fn event ->
          event
          |> stamp_pending_id(pending_id)
          |> then(&emit(callbacks, &1))
        end
      )
    else
      LLM.generate_with(
        snapshot.llm || snapshot.llm_adapter,
        response_schema,
        generate_opts
      )
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

  defp handle_llm_response(state, response, callbacks, result) do
    thinking = get_string_field(response, "thinking")
    tool_calls = get_tool_calls(response)
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
        handle_tool_call_response(state, callbacks, tool_calls, message_opts)

      content && content != "" ->
        handle_content_response(state, callbacks, content, message_opts)

      has_tool_results_in_recent_messages?(State.model_messages(state)) &&
          not State.max_iterations_reached?(state) ->
        Logger.warning("LLM failed to provide content after tool results, retrying...")
        loop(state, callbacks)

      true ->
        handle_empty_response(state, callbacks, thinking)
    end
  end

  defp handle_tool_call_response(state, callbacks, tool_calls, message_opts) do
    # Assign ids to every tool call up front so the SAME id is stored on the
    # assistant message's tool_calls AND later threaded onto each tool result
    # (tool_call_id). This is the call->result linkage providers require; it is
    # what lets the next request carry a structured, correctly-paired history
    # instead of a flattened blob.
    tool_calls = Enum.map(tool_calls, &ensure_tool_call_id(&1, state))
    assistant_message = Message.assistant(Keyword.put(message_opts, :tool_calls, tool_calls))
    state = State.add_message(state, assistant_message)

    case emit_and_finalize_message(state, callbacks, assistant_message) do
      {:ok, state} ->
        state =
          state
          |> clear_pending_assistant_id()
          |> State.set_status(:acting)

        emit(callbacks, Event.new(:status_change, %{status: :acting}))

        case execute_tool_calls(state, tool_calls, callbacks) do
          {:ok, state} -> loop(state, callbacks)
          {:error, state} -> {:error, do_after_turn_cleanup(state, callbacks)}
          {:cancelled, state} -> do_after_turn(state, cancel_run(state, callbacks), callbacks)
        end

      {:error, state} ->
        {:error, do_after_turn_cleanup(clear_pending_assistant_id(state), callbacks)}
    end
  end

  defp handle_content_response(state, callbacks, content, message_opts) do
    assistant_message =
      message_opts
      |> Keyword.put(:content, content)
      |> Message.assistant()

    state =
      state
      |> State.add_message(assistant_message)
      |> State.set_status(:completed)

    finalize_completed_assistant_message(state, callbacks, assistant_message)
  end

  defp handle_empty_response(state, callbacks, thinking) do
    Logger.warning("LLM response had neither native tool_calls nor content")

    fallback_content =
      if thinking && thinking != "" do
        thinking
      else
        "I'm not sure how to help with that. Could you please clarify your question?"
      end

    assistant_message =
      Message.assistant(
        content: fallback_content,
        id: state.pending_assistant_id,
        id_generator: state.id_generator
      )

    state =
      state
      |> State.add_message(assistant_message)
      |> State.set_status(:completed)

    finalize_completed_assistant_message(state, callbacks, assistant_message)
  end

  defp finalize_completed_assistant_message(state, callbacks, assistant_message) do
    case emit_and_finalize_message(state, callbacks, assistant_message) do
      {:ok, state} ->
        state = clear_pending_assistant_id(state)
        continue_after_assistant(state, callbacks)

      {:error, state} ->
        {:error, do_after_turn_cleanup(clear_pending_assistant_id(state), callbacks)}
    end
  end

  defp continue_after_assistant(state, callbacks) do
    if cancelled?(callbacks) do
      do_after_turn(state, cancel_run(state, callbacks), callbacks)
    else
      case append_incoming_messages(state, callbacks) do
        {:ok, state, 0} ->
          emit(callbacks, Event.new(:status_change, %{status: :completed}))

          emit(
            callbacks,
            Event.new(:turn_end, %{session_id: state.session_id, status: :completed})
          )

          {:ok, do_after_turn_cleanup(state, callbacks)}

        {:ok, state, _count} ->
          continue_loop(state, callbacks)

        {:error, reason, state} ->
          final_state =
            State.set_error(state, "Could not receive queued messages: #{inspect(reason)}")

          {:error, do_after_turn_cleanup(final_state, callbacks)}
      end
    end
  end

  defp append_incoming_messages(state, %{take_incoming_messages: nil}),
    do: {:ok, state, 0}

  defp append_incoming_messages(state, callbacks) do
    case take_incoming_messages(callbacks) do
      {:ok, incoming} -> append_incoming_batch(state, callbacks, incoming)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp append_incoming_batch(state, callbacks, incoming) do
    Enum.reduce_while(incoming, {:ok, state, 0}, fn content, {:ok, state, count} ->
      message = Message.user(content, id_generator: state.id_generator)
      state = State.add_message(state, message)

      case emit_and_finalize_message(state, callbacks, message) do
        {:ok, state} -> {:cont, {:ok, state, count + 1}}
        {:error, state} -> {:halt, {:error, :message_hook_failed, state}}
      end
    end)
  end

  defp take_incoming_messages(%{take_incoming_messages: callback})
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

  defp has_tool_results_in_recent_messages?(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take(5)
    |> Enum.any?(fn msg -> msg.role == :tool end)
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

    raw_calls
    |> Enum.map(&normalize_tool_call/1)
    |> Enum.filter(fn %Call{name: name} -> name != nil end)
  end

  defp normalize_tool_call(call) do
    function = fetch_call(call, "function", :function, %{})

    %Call{
      id: fetch_call(call, "id", :id),
      name: fetch_call(call, "name", :name) || fetch_call(function, "name", :name),
      arguments:
        normalize_tool_arguments(
          fetch_call(call, "arguments", :arguments) ||
            fetch_call(function, "arguments", :arguments, %{})
        ),
      definition_id: fetch_call(call, "definition_id", :definition_id),
      raw: call
    }
  end

  defp fetch_call(map, string_key, atom_key, default \\ nil) do
    Map.get(map, string_key) || Map.get(map, atom_key, default)
  end

  defp normalize_tool_arguments(arguments) when is_map(arguments), do: arguments

  defp normalize_tool_arguments(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_tool_arguments(_arguments), do: %{}

  defp execute_tool_calls(%State{} = state, tool_calls, callbacks) do
    case state.tool_policy do
      %Policy{execution_mode: :concurrent} ->
        execute_tool_calls_concurrently(state, tool_calls, callbacks)

      %Policy{} ->
        execute_tool_calls_sequentially(state, tool_calls, callbacks)
    end
  end

  defp execute_tool_calls_sequentially(state, tool_calls, callbacks) do
    Enum.reduce_while(tool_calls, state, fn tool_call, acc_state ->
      execute_tool_call_until_cancelled(tool_call, acc_state, callbacks)
    end)
    |> settle_tool_batch()
  end

  # Concurrent execution keeps the loop process as the only writer of `State`:
  # every call in the batch is prepared and dispatched here, tools settle in
  # supervised tasks, and the results are committed back in the model's order.
  defp execute_tool_calls_concurrently(state, tool_calls, callbacks) do
    supervisor = callbacks.tool_supervisor

    cond do
      is_nil(supervisor) ->
        raise ArgumentError,
              "concurrent tool execution requires a :tool_supervisor option; " <>
                "pass a Task.Supervisor or use the sequential tool policy"

      cancelled?(callbacks) ->
        {:cancelled, cancel_state(state, callbacks)}

      true ->
        run_concurrent_batch(tool_calls, state, callbacks, supervisor)
    end
  end

  defp run_concurrent_batch(tool_calls, state, callbacks, supervisor) do
    case prepare_tool_batch(tool_calls, state, callbacks) do
      {:ok, jobs, state} ->
        {settlements, outcome} = run_tool_batch(jobs, supervisor, callbacks)
        state = commit_tool_batch(jobs, settlements, state, callbacks)

        case {state.status, outcome} do
          {:error, _status} -> {:error, state}
          {_status, :cancelled} -> {:cancelled, cancel_state(state, callbacks)}
          _other -> {:ok, state}
        end

      {:abort, state} ->
        {:error, state}
    end
  end

  defp settle_tool_batch(%State{status: :cancelled} = state), do: {:cancelled, state}
  defp settle_tool_batch(%State{status: :error} = state), do: {:error, state}
  defp settle_tool_batch(%State{} = state), do: {:ok, state}

  defp execute_tool_call_until_cancelled(tool_call, state, callbacks) do
    if cancelled?(callbacks) do
      {:halt, cancel_state(state, callbacks)}
    else
      tool_call
      |> execute_single_tool(state, callbacks)
      |> continue_or_cancel(callbacks)
    end
  end

  defp continue_or_cancel({:ok, %State{} = state}, callbacks) do
    if cancelled?(callbacks) do
      {:halt, cancel_state(state, callbacks)}
    else
      {:cont, state}
    end
  end

  defp continue_or_cancel({:abort, %State{} = state}, _callbacks) do
    {:halt, state}
  end

  defp ensure_tool_call_id(%Call{id: id} = call, _state) when is_binary(id) and id != "",
    do: call

  defp ensure_tool_call_id(%Call{} = call, state),
    do: %{call | id: generate_call_id(state)}

  defp execute_single_tool(%Call{arguments: _args} = tool_call, state, callbacks) do
    tool_call_id = tool_call.id || generate_call_id(state)
    tool_call = %{tool_call | id: tool_call_id}

    case invoke_before_tool_call(state, tool_call, callbacks) do
      {:ok, state} ->
        do_execute_single_tool(tool_call, state, callbacks)

      {:error, reason} ->
        {:abort, State.set_error(state, "Hook aborted before tool call: #{inspect(reason)}")}
    end
  end

  defp do_execute_single_tool(%Call{name: name, arguments: args} = tool_call, state, callbacks) do
    emit(
      callbacks,
      Event.new(:tool_start, %{tool_call_id: tool_call.id, name: name, arguments: args})
    )

    settlement = settle_tool_call(tool_call, state, callbacks)
    emit_tool_execution_end(settlement, callbacks)
    append_tool_settlement(settlement, state, callbacks)
  end

  # ── Concurrent batch ──────────────────────────────────────────────────

  @tool_poll_ms 100
  @tool_shutdown_ms 1_000

  # Runs every `before_tool_call` hook up front, emits each `tool_start`, and
  # captures one execution job per call. Hooks are gates, so an abort anywhere in
  # the batch stops the whole batch before any tool runs.
  defp prepare_tool_batch(tool_calls, state, callbacks) do
    Enum.reduce_while(Enum.with_index(tool_calls), {:ok, [], state}, fn {call, index},
                                                                        {:ok, jobs, acc_state} ->
      tool_call = %{call | id: call.id || generate_call_id(acc_state)}

      case invoke_before_tool_call(acc_state, tool_call, callbacks) do
        {:ok, acc_state} ->
          emit(
            callbacks,
            Event.new(:tool_start, %{
              tool_call_id: tool_call.id,
              name: tool_call.name,
              arguments: tool_call.arguments
            })
          )

          job = %{index: index, call: tool_call, state: acc_state}
          {:cont, {:ok, [job | jobs], acc_state}}

        {:error, reason} ->
          {:halt,
           {:abort,
            State.set_error(acc_state, "Hook aborted before tool call: #{inspect(reason)}")}}
      end
    end)
    |> case do
      {:ok, jobs, state} -> {:ok, Enum.reverse(jobs), state}
      {:abort, state} -> {:abort, state}
    end
  end

  defp run_tool_batch(jobs, supervisor, callbacks) do
    jobs
    |> Enum.map(&start_tool_task(&1, supervisor, callbacks))
    |> await_tool_batch(%{}, callbacks)
  end

  defp start_tool_task(%{index: index, call: call, state: state}, supervisor, callbacks) do
    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :proc_lib.set_label("tool:#{call.name}")
        settle_tool_call(call, state, callbacks)
      end)

    {index, call, task}
  end

  defp await_tool_batch([], settlements, _callbacks), do: {settlements, :ok}

  defp await_tool_batch(pending, settlements, callbacks) do
    {settlements, pending} = drain_tool_tasks(pending, settlements, callbacks)

    cond do
      pending == [] -> {settlements, :ok}
      cancelled?(callbacks) -> {shutdown_tool_tasks(pending, settlements, callbacks), :cancelled}
      true -> await_tool_batch(pending, settlements, callbacks)
    end
  end

  defp drain_tool_tasks(pending, settlements, callbacks) do
    by_ref = Map.new(pending, fn {index, call, task} -> {task.ref, {index, call}} end)

    settled =
      pending
      |> Enum.map(fn {_index, _call, task} -> task end)
      |> Task.yield_many(@tool_poll_ms)

    {settlements, done_refs} =
      Enum.reduce(settled, {settlements, MapSet.new()}, fn {task, result}, {acc, done} ->
        case result do
          nil ->
            {acc, done}

          {:ok, settlement} ->
            {index, _call} = Map.fetch!(by_ref, task.ref)
            emit_tool_execution_end(settlement, callbacks)
            {Map.put(acc, index, settlement), MapSet.put(done, task.ref)}

          {:exit, reason} ->
            {index, call} = Map.fetch!(by_ref, task.ref)
            Logger.error("Tool task for #{call.name} exited: #{inspect(reason)}")

            settlement = crashed_tool_settlement(call, reason)
            emit_tool_execution_end(settlement, callbacks)
            {Map.put(acc, index, settlement), MapSet.put(done, task.ref)}
        end
      end)

    pending =
      Enum.reject(pending, fn {_index, _call, task} ->
        MapSet.member?(done_refs, task.ref)
      end)

    {settlements, pending}
  end

  defp shutdown_tool_tasks(pending, settlements, callbacks) do
    Enum.reduce(pending, settlements, fn {index, _call, task}, acc ->
      case Task.shutdown(task, @tool_shutdown_ms) do
        {:ok, settlement} ->
          emit_tool_execution_end(settlement, callbacks)
          Map.put(acc, index, settlement)

        _other ->
          acc
      end
    end)
  end

  # Execution progress is transient and may arrive out of call order. Keep it
  # separate from tool_end/tool_error, which follow ordered message persistence.
  # Only the loop emits these events, never the worker tasks.
  defp emit_tool_execution_end({:ok, %ToolResult{} = result}, callbacks) do
    emit(
      callbacks,
      Event.new(:tool_execution_end, %{
        tool_call_id: result.tool_call_id,
        name: result.name,
        status: :completed,
        result: result.content
      })
    )
  end

  defp emit_tool_execution_end({:error, %ToolError{} = error}, callbacks) do
    emit(
      callbacks,
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
  defp commit_tool_batch(jobs, settlements, state, callbacks) do
    Enum.reduce_while(jobs, state, fn %{index: index}, acc_state ->
      case Map.fetch(settlements, index) do
        {:ok, settlement} -> commit_tool_settlement(settlement, acc_state, callbacks)
        :error -> {:cont, acc_state}
      end
    end)
  end

  defp commit_tool_settlement(settlement, acc_state, callbacks) do
    case append_tool_settlement(settlement, acc_state, callbacks) do
      {:ok, acc_state} -> {:cont, acc_state}
      {:abort, acc_state} -> {:halt, acc_state}
    end
  end

  defp crashed_tool_settlement(%Call{} = call, reason) do
    {:error,
     %ToolError{
       tool_call_id: call.id,
       name: call.name,
       reason: :execution_error,
       message: "Tool crashed: #{inspect(reason)}",
       content: "Error: The tool failed while completing the request.",
       details: reason,
       metadata: %{definition_id: call.definition_id}
     }}
  end

  # Runs one call's settle pipeline (resolve, execute, validate, telemetry).
  # Sequential execution calls this inline; concurrent execution calls it inside a
  # supervised task. It never touches agent state or emits agent events.
  defp settle_tool_call(%Call{name: name} = tool_call, state, callbacks) do
    telemetry_name = telemetry_tool_name(name, state)
    telemetry_ref = Telemetry.start([:tackle, :tool, :execution], %{tool_name: telemetry_name})
    started_at = System.monotonic_time()

    try do
      settlement =
        with_tool_telemetry_context(state, telemetry_ref, fn ->
          case Registry.resolve(tool_registry(callbacks), tool_call) do
            {:ok, %{module: tool_module}} ->
              Tool.settle(tool_module, tool_call, tool_context(state, callbacks, tool_call))

            {:error, reason} ->
              registry_error(tool_call, reason)
          end
        end)

      Telemetry.stop(
        [:tackle, :tool, :execution],
        telemetry_ref,
        %{duration: Telemetry.monotonic_duration(started_at), count: 1},
        %{tool_name: telemetry_name, outcome: tool_outcome(settlement)}
      )

      settlement
    rescue
      error ->
        Telemetry.exception(
          [:tackle, :tool, :execution],
          telemetry_ref,
          %{duration: Telemetry.monotonic_duration(started_at), count: 1},
          %{tool_name: telemetry_name, error_type: :error}
        )

        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        Telemetry.exception(
          [:tackle, :tool, :execution],
          telemetry_ref,
          %{duration: Telemetry.monotonic_duration(started_at), count: 1},
          %{tool_name: telemetry_name, error_type: exception_type(kind, reason)}
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp with_tool_telemetry_context(%State{context: context}, telemetry_ref, fun)
       when is_reference(telemetry_ref) and is_function(fun, 0) do
    case get_in(context, [:telemetry, :adapter]) do
      adapter when is_atom(adapter) and not is_nil(adapter) ->
        adapter.with_context(telemetry_ref, fun)

      _adapter ->
        fun.()
    end
  end

  defp telemetry_tool_name(name, %State{context: context}) when is_binary(name) do
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

  defp exception_type(kind, _reason) when kind in [:error, :exit, :throw], do: kind

  defp provider_tool_definitions(%Registry{} = registry) do
    Registry.definitions(registry)
  end

  defp append_tool_settlement({:ok, %ToolResult{} = result}, state, callbacks) do
    tool_message =
      Message.tool_result(result.tool_call_id, result.name, result.content,
        id_generator: state.id_generator,
        parts: result.parts
      )

    state = State.add_message(state, tool_message)

    case emit_and_finalize_message(state, callbacks, tool_message) do
      {:ok, state} ->
        emit(
          callbacks,
          Event.new(:tool_end, %{
            tool_call_id: result.tool_call_id,
            name: result.name,
            result: result.content,
            raw: result.raw,
            metadata: result.metadata
          })
        )

        case invoke_after_tool_call(state, result, callbacks) do
          {:ok, state} ->
            {:ok, state}

          {:error, reason} ->
            {:abort, State.set_error(state, "Hook aborted after tool call: #{inspect(reason)}")}
        end

      {:error, state} ->
        {:abort, state}
    end
  end

  defp append_tool_settlement({:error, %ToolError{} = error}, state, callbacks) do
    name = error.name || "unknown"

    tool_message =
      Message.tool_result(error.tool_call_id, name, error.content,
        id_generator: state.id_generator
      )

    state = State.add_message(state, tool_message)

    case emit_and_finalize_message(state, callbacks, tool_message) do
      {:ok, state} ->
        emit(
          callbacks,
          Event.new(:tool_error, %{
            tool_call_id: error.tool_call_id,
            name: name,
            error: error.message,
            reason: error.reason,
            details: error.details,
            metadata: error.metadata
          })
        )

        case invoke_after_tool_call(state, error, callbacks) do
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

  defp callbacks(opts) do
    %{
      event: Keyword.get(opts, :event_callback, fn _event -> :ok end),
      event_context: Keyword.get(opts, :event_context, %{}),
      llm_stream?: Keyword.get(opts, :llm_stream, false),
      cancellation_signal:
        Keyword.get(opts, :cancellation_signal) || Keyword.get(opts, :cancel_signal),
      tool_supervisor: Keyword.get(opts, :tool_supervisor),
      take_incoming_messages: Keyword.get(opts, :take_incoming_messages)
    }
  end

  defp maybe_put_cancellation_signal(opts, nil), do: opts

  defp maybe_put_cancellation_signal(opts, signal),
    do: Keyword.put(opts, :cancellation_signal, signal)

  defp tool_context(%State{} = state, callbacks, %Call{} = tool_call) do
    context =
      state.context
      |> Map.merge(callbacks.event_context)
      |> Map.put(:tool_call_id, tool_call.id)

    case callbacks.cancellation_signal do
      nil -> context
      signal -> Map.put(context, :cancellation_signal, signal)
    end
  end

  defp cancelled?(%{cancellation_signal: signal}), do: Cancellation.cancelled?(signal)

  defp cancel_run(%State{} = state, callbacks) do
    state = cancel_state(state, callbacks)

    emit(callbacks, Event.new(:status_change, %{status: :cancelled}))

    emit(
      callbacks,
      Event.new(:turn_cancelled, %{session_id: state.session_id, reason: state.error})
    )

    emit(callbacks, Event.new(:turn_end, %{session_id: state.session_id, status: :cancelled}))

    {:cancelled, state}
  end

  defp cancel_state(%State{} = state, callbacks) do
    reason = callbacks.cancellation_signal |> Cancellation.reason() |> cancellation_reason()
    State.set_cancelled(state, reason)
  end

  defp cancellation_reason(nil), do: "Cancelled"
  defp cancellation_reason(reason) when is_binary(reason), do: reason
  defp cancellation_reason(reason), do: inspect(reason)

  defp emit(callbacks, %Event{} = event) do
    callbacks.event.(event)
    :ok
  end

  defp emit_llm_settlement_events(callbacks, %State{} = state, result) do
    usage = Map.get(result, :usage)

    if usage do
      emit(callbacks, Event.usage(usage))
    end

    emit(
      callbacks,
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

  defp invoke_before_prompt(%State{} = state, callbacks) do
    hooks = snapshot_hooks(callbacks)

    case Hook.invoke(hooks, :before_prompt, [state], state.context) do
      {:ok, context} -> {:ok, %{state | context: context}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_after_prompt(%State{} = state, response, callbacks) do
    hooks = snapshot_hooks(callbacks)

    case Hook.invoke(hooks, :after_prompt, [state, response], state.context) do
      {:ok, context} -> {:ok, %{state | context: context}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_before_tool_call(%State{} = state, %Call{} = tool_call, callbacks) do
    hooks = snapshot_hooks(callbacks)

    case Hook.invoke(hooks, :before_tool_call, [state, tool_call], state.context) do
      {:ok, context} -> {:ok, %{state | context: context}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_after_tool_call(%State{} = state, tool_result, callbacks) do
    hooks = snapshot_hooks(callbacks)

    case Hook.invoke(hooks, :after_tool_call, [state, tool_result], state.context) do
      {:ok, context} -> {:ok, %{state | context: context}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_after_message(%State{} = state, %Message{} = message, callbacks) do
    hooks = snapshot_hooks(callbacks)

    case Hook.invoke(hooks, :after_message, [state, message], state.context) do
      {:ok, context} -> {:ok, %{state | context: context}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_and_finalize_message(%State{} = state, callbacks, %Message{} = message) do
    emit(callbacks, Event.message_end(message))

    case invoke_after_message(state, message, callbacks) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:error, State.set_error(state, "Hook aborted after message: #{inspect(reason)}")}
    end
  end

  defp clear_pending_assistant_id(%State{} = state) do
    %{state | pending_assistant_id: nil}
  end

  defp do_after_turn(_state, {:cancelled, final_state}, callbacks) do
    {:cancelled, do_after_turn_cleanup(final_state, callbacks)}
  end

  defp do_after_turn_cleanup(%State{} = state, callbacks) do
    hooks = snapshot_hooks(callbacks)

    case Hook.invoke(hooks, :after_turn, [state], state.context) do
      {:ok, context} -> %{state | context: context, snapshot: nil}
      _ -> %{state | snapshot: nil}
    end
  end

  # --- Snapshot helpers ---

  defp tool_registry(%{snapshot: %Snapshot{tool_registry: registry}}) when not is_nil(registry),
    do: registry

  defp tool_registry(_callbacks),
    do: raise("No snapshot available — tool_registry must be resolved from a snapshot")

  defp snapshot(%{snapshot: %Snapshot{} = snapshot}), do: snapshot

  defp snapshot(_callbacks),
    do: raise("No snapshot available — LLM configuration must be resolved from a snapshot")

  defp snapshot_hooks(%{snapshot: %Snapshot{hooks: hooks}}), do: hooks
  defp snapshot_hooks(_callbacks), do: []
end
