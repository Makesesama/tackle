defmodule Tackle.Lib.Loop do
  @moduledoc """
  ReAct-style agent loop.

  Implements a Reasoning + Acting loop where the agent:
  1. Receives a user query
  2. Thinks about how to respond
  3. Optionally calls tools to gather information
  4. Repeats until it has a final answer

  ## Provider-agnostic

  The loop never talks to an LLM directly — it calls the `Tackle.Lib.LLM`
  adapter of the state's selection (`Tackle.Lib.LLM.select/2`, passed to
  `Tackle.Lib.State.new/1` as `:llm`). `run/3` and `continue/2` raise
  `ArgumentError` for a state without one.

  ## Host-supplied system prompt

  The loop uses `state.system_prompt` as-is. The host composes it (typically
  with `Tackle.Lib.SystemPrompt` helpers for the tool block and response guidance).
  Tool execution always uses provider-native tool calls. If a prompt renderer
  returns a response schema, it is used only for structured non-tool responses.

  ## Provider call gate

  `run/3` and `continue/2` accept a `:before_provider_call` zero-arity callback.
  It runs immediately before every adapter `generate/2` or `stream/3` dispatch,
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

  ## Responses

  Each step keeps one provider response, a `Tackle.Lib.LLM.Response` as
  `Tackle.Lib.LLM.generate_with/3` returns it, which the `after_prompt` hooks
  see. Transient
  provider failures are retried under the state's `Tackle.Lib.Retry` policy,
  and a provider-confirmed context overflow is compacted and sent again when
  compaction is enabled. A response with neither content nor tool calls is
  asked again once, as a retry with reason `:empty_response`; a second empty
  response in a row ends the turn with an error. A malformed adapter result,
  or an adapter that crashes, ends the turn with the `Tackle.Lib.LLM.Error`
  the library returns for it (kind `:invalid_response` or `:unknown`). Every
  response reports its usage with a `:usage` event, and the step ends with one
  `:step_end` event for the response it keeps.

  ## Errors

  A turn that ends in an error sets `state.error` to a human-readable message
  and `state.error_reason` to the structured reason, which the `:error` event
  also carries as `:reason` (see `Tackle.Lib.State`).

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
  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.Loop.Provider
  alias Tackle.Lib.Loop.Run
  alias Tackle.Lib.Loop.Tools
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Call

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
    state = State.reset_turn(state)

    Run.emit(run, Event.turn_start(state.session_id))

    if Run.cancelled?(run) do
      cancel(state, run)
    else
      state = Tools.settle_interrupted(state, run, :interrupted)
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
    state = State.reset_turn(state)

    Run.emit(run, Event.turn_start(state.session_id))

    state
    |> Tools.settle_interrupted(run, :interrupted)
    |> loop(run)
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

  # Each step mints the id of the assistant message it generates up front, so
  # streamed deltas, retries, and the settled message share it.
  defp iterate(state, run) do
    state = %{state | current_iteration: state.current_iteration + 1, status: :thinking}

    Run.emit(run, Event.status_change(:thinking))

    run = %{run | assistant_id: state.id_generator.()}
    Run.emit(run, Event.message_start(id: run.assistant_id, role: :assistant))

    Run.emit(run, Event.step_start(state.current_iteration))

    case maybe_auto_compact(state, run) do
      {:ok, state} ->
        before_prompt(state, run)

      {:error, reason, committed_state} ->
        fail(committed_state, run, "Compaction failed: #{inspect(reason)}", reason)

      {:cancelled, _reason, committed_state} ->
        cancel(committed_state, run)
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
    case Compaction.compact(state, trigger, Run.compaction_opts(run)) do
      {status, reason} when status in [:error, :cancelled] -> {status, reason, state}
      result -> result
    end
  end

  defp before_prompt(state, run) do
    case Run.invoke_hook(state, run, :before_prompt, [state]) do
      {:ok, state} ->
        request(state, run)

      {:error, reason} ->
        fail(state, run, "Hook aborted before prompt: #{inspect(reason)}", reason)
    end
  end

  defp request(state, run) do
    case Provider.request(state, run) do
      {:ok, response, state, run} -> after_prompt(state, run, response)
      {:error, state} -> finish(:error, state, run)
      {:cancelled, state} -> cancel(state, run)
    end
  end

  # The step ends with the response it keeps: a re-asked empty response is
  # never seen here.
  defp after_prompt(state, run, %Response{} = response) do
    Run.emit(run, Event.step_end(state.current_iteration, response))

    case Run.invoke_hook(state, run, :after_prompt, [state, response]) do
      {:ok, state} ->
        respond(state, run, response)

      {:error, reason} ->
        fail(state, run, "Hook aborted after prompt: #{inspect(reason)}", reason)
    end
  end

  # A response with tool calls runs them; any other response has content (the
  # provider never returns an empty one) and is the final answer.
  defp respond(state, run, %Response{tool_calls: [_ | _]} = response) do
    # Assign ids to every tool call up front so the SAME id is stored on the
    # assistant message's tool_calls AND later threaded onto each tool result
    # (tool_call_id). This is the call->result linkage providers require; it is
    # what lets the next request carry a structured, correctly-paired history
    # instead of a flattened blob.
    tool_calls = Enum.map(response.tool_calls, &ensure_tool_call_id(&1, state))
    assistant_message = assistant_message(state, run, response, tool_calls)
    state = State.add_message(state, assistant_message)

    case Run.finalize_message(state, run, assistant_message) do
      {:ok, state} ->
        state = %{state | status: :acting}

        Run.emit(run, Event.status_change(:acting))

        case Tools.execute(state, tool_calls, run) do
          {:ok, state} -> loop(state, run)
          {:error, state} -> finish(:error, state, run)
          {:cancelled, state} -> cancel(state, run)
        end

      {:error, state} ->
        finish(:error, state, run)
    end
  end

  defp respond(state, run, %Response{} = response) do
    assistant_message = assistant_message(state, run, response, nil)
    state = %{State.add_message(state, assistant_message) | status: :completed}

    finalize_completed_assistant_message(state, run, assistant_message)
  end

  # The assistant message takes the id minted at the step's `message_start`.
  defp assistant_message(state, run, %Response{} = response, tool_calls) do
    Message.assistant(
      content: response.content,
      thinking: response.thinking,
      tool_calls: tool_calls,
      token_usage: response.usage,
      model: response.model,
      provider_state: response.provider_state,
      id: run.assistant_id,
      id_generator: state.id_generator
    )
  end

  defp finalize_completed_assistant_message(state, run, assistant_message) do
    case Run.finalize_message(state, run, assistant_message) do
      {:ok, state} ->
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
        {:error,
         State.set_error(state, "Could not receive queued messages: #{inspect(reason)}", reason)}
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

  defp ensure_tool_call_id(%Call{id: id} = call, _state) when is_binary(id) and id != "",
    do: call

  defp ensure_tool_call_id(%Call{} = call, state),
    do: %{call | id: generate_call_id(state)}

  defp generate_call_id(%State{id_generator: id_generator}), do: id_generator.()

  # --- Turn end ---

  defp cancel(%State{} = state, run),
    do: finish(:cancelled, Run.mark_cancelled(state, run), run)

  defp fail(%State{} = state, run, message, reason),
    do: finish(:error, State.set_error(state, message, reason), run)

  # Every turn ends here, whatever the outcome: tool calls left without
  # results are settled, the outcome's events are emitted (an error outcome
  # reports `state.error` with `state.error_reason` as its `reason`, when there
  # is one), and the `after_turn` hooks run last.
  defp finish(outcome, %State{} = state, run) when outcome in [:ok, :error, :cancelled] do
    state =
      if outcome == :ok,
        do: state,
        else: Tools.settle_interrupted(state, run, interrupted_as(outcome))

    emit_turn_end(outcome, state, run)

    state =
      case Hook.invoke(run.snapshot.hooks, :after_turn, [state], state.context) do
        {:ok, context} -> %{state | context: context}
        _ -> state
      end

    {outcome, state}
  end

  defp interrupted_as(:error), do: :aborted
  defp interrupted_as(:cancelled), do: :cancelled

  defp emit_turn_end(:ok, state, run) do
    Run.emit(run, Event.status_change(:completed))
    Run.emit(run, Event.turn_end(state.session_id, :completed))
  end

  defp emit_turn_end(:cancelled, state, run) do
    Run.emit(run, Event.status_change(:cancelled))
    Run.emit(run, Event.turn_cancelled(state.session_id, state.error))
    Run.emit(run, Event.turn_end(state.session_id, :cancelled))
  end

  defp emit_turn_end(:error, state, run) do
    Run.emit(run, Event.error(state.error, state.error_reason))
    Run.emit(run, Event.status_change(:error))
    Run.emit(run, Event.turn_end(state.session_id, :error))
  end
end
