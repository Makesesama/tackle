defmodule Tackle.Loop do
  @moduledoc """
  ReAct-style agent loop.

  Implements a Reasoning + Acting loop where the agent:
  1. Receives a user query
  2. Thinks about how to respond
  3. Optionally calls tools to gather information
  4. Repeats until it has a final answer

  ## Provider-agnostic

  The loop never talks to an LLM directly — it calls the configured
  `Tackle.LLM` adapter. Configure it with:

      config :tackle, llm: MyApp.AI.TackleAdapter

  ## Host-supplied system prompt

  The loop uses `state.system_prompt` as-is. The host composes it (typically
  with `Tackle.SystemPrompt` helpers for the tool block and response guidance).
  Tool execution always uses provider-native tool calls. If a prompt renderer
  returns a response schema, it is used only for structured non-tool responses.

  ## Instruction prompt

  The short instruction appended after the conversation can be configured with
  `:instruction` under either `:tackle` or the in-tree host fallback:

      config :tackle,
        instruction: [
          without_tool_results: "Decide whether to call tools or answer.",
          with_tool_results: "Use the tool results to answer."
        ]

      config :my_app, Tackle,
        instruction: fn has_tool_results ->
          if has_tool_results, do: "Answer from the tool results.", else: "Continue."
        end

  A single string applies to both cases. A keyword list or map may provide
  `:without_tool_results` and/or `:with_tool_results`; omitted keys fall back to
  Tackle's defaults.

  """

  require Logger

  @default_instruction_with_tool_results """
  Based on the conversation and tool results above, provide your final answer to the user.
  You now have the information you need - summarize and respond clearly.
  Only call more tools if the results were insufficient or you need additional data.
  """

  @default_instruction_without_tool_results """
  Based on the conversation above, decide your next action.
  If you need information, call the appropriate tools.
  If you already have enough information, answer the user directly.
  """

  alias Tackle.Cancellation
  alias Tackle.Event
  alias Tackle.Hook
  alias Tackle.LLM
  alias Tackle.Message
  alias Tackle.Snapshot
  alias Tackle.State
  alias Tackle.SystemPrompt
  alias Tackle.Telemetry
  alias Tackle.Tool
  alias Tackle.Tool.Call
  alias Tackle.Tool.Error, as: ToolError
  alias Tackle.Tool.Policy
  alias Tackle.Tool.Registry
  alias Tackle.Tool.Result, as: ToolResult

  @doc """
  Runs the agent loop for a user query.

  ## Options
    * `:event_callback` - Function called with `%Tackle.Event{}` structs.
    * `:llm_stream` - When true, use `Tackle.LLM.stream/4` if the adapter supports it.
    * `:cancellation_signal` - Optional `Tackle.Cancellation.Signal` checked between loop steps.
  """
  @spec run(State.t(), String.t(), keyword()) ::
          {:ok, State.t()} | {:error, State.t()} | {:cancelled, State.t()}
  def run(%State{} = state, user_input, opts \\ []) do
    callbacks = callbacks(opts)
    snapshot = Snapshot.capture(state)
    callbacks = Map.put(callbacks, :snapshot, snapshot)
    state = %{state | pending_assistant_id: nil, snapshot: snapshot}

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
    snapshot = state.snapshot || Snapshot.capture(state)
    callbacks = Map.put(callbacks, :snapshot, snapshot)

    state = %{
      state
      | current_iteration: 0,
        status: :idle,
        error: nil,
        pending_assistant_id: nil,
        snapshot: snapshot
    }

    loop(state, callbacks)
  end

  defp loop(%State{} = state, callbacks) do
    cond do
      cancelled?(callbacks) ->
        do_after_turn(state, cancel_run(state, callbacks), callbacks)

      State.max_iterations_reached?(state) ->
        Logger.warning("Agent reached max iterations (#{state.max_iterations})")
        final_state = State.set_error(state, "Reached maximum iterations without completing")
        {:error, do_after_turn_cleanup(final_state, callbacks)}

      true ->
        state = State.increment_iteration(state)
        state = State.set_status(state, :thinking)

        emit(callbacks, Event.new(:status_change, %{status: :thinking}))

        assistant_id = state.id_generator.()
        state = %{state | pending_assistant_id: assistant_id}
        emit(callbacks, Event.message_start(id: assistant_id, role: :assistant))

        emit(callbacks, Event.new(:step_start, %{iteration: state.current_iteration}))

        case invoke_before_prompt(state, callbacks) do
          {:ok, state} ->
            state
            |> call_llm(callbacks)
            |> handle_llm_call_result(state, callbacks)

          {:error, reason} ->
            final_state = State.set_error(state, "Hook aborted before prompt: #{inspect(reason)}")
            {:error, do_after_turn_cleanup(final_state, callbacks)}
        end
    end
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
    if cancelled?(callbacks) do
      do_after_turn(clear_pending_assistant_id(state), cancel_run(state, callbacks), callbacks)
    else
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

  defp call_llm(%State{} = state, callbacks) do
    snapshot = snapshot(callbacks)
    system_prompt = snapshot.system_prompt

    last_message = List.last(state.messages)
    has_tool_results = last_message && last_message.role == :tool

    instruction = instruction(has_tool_results)

    # Structured message array (mature-harness shape): each turn is its own
    # role-tagged map, assistant tool calls and tool results are linked by
    # tool_call_id. The per-turn instruction rides as a trailing user message.
    # This is the SOLE conversation transport — the loop never flattens history.
    structured_messages =
      Tackle.Messages.to_provider(state.messages) ++
        [%{role: :user, content: instruction}]

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
        snapshot.llm_adapter,
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
        snapshot.llm_adapter,
        response_schema,
        generate_opts
      )
    end
  end

  # Streaming delta events from the adapter carry no message id (the provider
  # doesn't know the id Tackle minted in :message_start). Stamp the pending
  # assistant id onto them so subscribers can route deltas to the correct
  # in-flight message bubble. Events that already carry an id are left as-is.
  defp stamp_pending_id(%Event{id: id} = event, _pending_id) when is_binary(id) and id != "",
    do: event

  defp stamp_pending_id(%Event{} = event, pending_id) when is_binary(pending_id),
    do: %{event | id: pending_id}

  defp stamp_pending_id(event, _pending_id), do: event

  defp instruction(has_tool_results) do
    configured_instruction()
    |> resolve_instruction(has_tool_results)
    |> ensure_instruction!()
  end

  defp configured_instruction do
    Application.get_env(:tackle, :instruction) ||
      get_in(Application.get_env(:my_app, Tackle, []), [:instruction])
  end

  defp resolve_instruction(nil, true), do: @default_instruction_with_tool_results
  defp resolve_instruction(nil, false), do: @default_instruction_without_tool_results

  defp resolve_instruction(instruction, _has_tool_results) when is_binary(instruction) do
    instruction
  end

  defp resolve_instruction(instruction, has_tool_results) when is_function(instruction, 1) do
    instruction.(has_tool_results)
  end

  defp resolve_instruction(instructions, has_tool_results)
       when is_list(instructions) or is_map(instructions) do
    key = if has_tool_results, do: :with_tool_results, else: :without_tool_results
    default = resolve_instruction(nil, has_tool_results)

    get_instruction(instructions, key) || default
  end

  defp resolve_instruction(other, _has_tool_results), do: other

  defp get_instruction(instructions, key) when is_list(instructions) do
    Keyword.get(instructions, key)
  end

  defp get_instruction(instructions, key) when is_map(instructions) do
    Map.get(instructions, key) || Map.get(instructions, Atom.to_string(key))
  end

  defp ensure_instruction!(instruction) when is_binary(instruction), do: instruction

  defp ensure_instruction!(instruction) do
    raise ArgumentError,
          "Tackle instruction config must resolve to a string, got: #{inspect(instruction)}"
  end

  defp handle_llm_response(state, response, callbacks, result) do
    thinking = get_string_field(response, "thinking")
    tool_calls = get_tool_calls(response)
    content = get_string_field(response, "content")

    message_opts = [
      thinking: thinking,
      token_usage: Map.get(result, :usage),
      model: Map.get(result, :model),
      id: state.pending_assistant_id,
      id_generator: state.id_generator
    ]

    cond do
      tool_calls != [] ->
        handle_tool_call_response(state, callbacks, tool_calls, message_opts)

      content && content != "" ->
        handle_content_response(state, callbacks, content, message_opts)

      has_tool_results_in_recent_messages?(state.messages) &&
          state.current_iteration < state.max_iterations ->
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
        emit(callbacks, Event.new(:status_change, %{status: :completed}))

        emit(
          callbacks,
          Event.new(:turn_end, %{session_id: state.session_id, status: :completed})
        )

        {:ok, do_after_turn_cleanup(state, callbacks)}

      {:error, state} ->
        {:error, do_after_turn_cleanup(clear_pending_assistant_id(state), callbacks)}
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
    function = call["function"] || Map.get(call, :function, %{})

    name =
      call["name"] || Map.get(call, :name) || function["name"] || Map.get(function, :name)

    arguments =
      call["arguments"] || Map.get(call, :arguments) || function["arguments"] ||
        Map.get(function, :arguments, %{})

    %Call{
      id: call["id"] || Map.get(call, :id),
      name: name,
      arguments: normalize_tool_arguments(arguments),
      definition_id: call["definition_id"] || Map.get(call, :definition_id),
      raw: call
    }
  end

  defp normalize_tool_arguments(arguments) when is_map(arguments), do: arguments

  defp normalize_tool_arguments(arguments) when is_binary(arguments) do
    case Tackle.JSON.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_tool_arguments(_arguments), do: %{}

  defp execute_tool_calls(
         %State{tool_policy: %Policy{execution_mode: :sequential}} = state,
         tool_calls,
         callbacks
       ) do
    Enum.reduce_while(tool_calls, state, fn tool_call, acc_state ->
      execute_tool_call_until_cancelled(tool_call, acc_state, callbacks)
    end)
    |> case do
      %State{status: :cancelled} = state -> {:cancelled, state}
      %State{status: :error} = state -> {:error, state}
      %State{} = state -> {:ok, state}
    end
  end

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

    telemetry_name = telemetry_tool_name(name, state)
    telemetry_ref = Telemetry.start([:tackle, :tool, :execution], %{tool_name: telemetry_name})
    started_at = System.monotonic_time()

    try do
      settlement =
        with_tool_telemetry_context(state, telemetry_ref, fn ->
          case Registry.resolve(tool_registry(callbacks), tool_call) do
            {:ok, %{module: tool_module}} ->
              Tool.settle(tool_module, tool_call, tool_context(state, callbacks))

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

      append_tool_settlement(settlement, state, callbacks)
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
  defp exception_type(_kind, _reason), do: :unknown

  defp provider_tool_definitions(%Registry{} = registry) do
    Registry.definitions(registry)
  end

  defp append_tool_settlement({:ok, %ToolResult{} = result}, state, callbacks) do
    tool_message =
      Message.tool_result(result.tool_call_id, result.name, result.content,
        id_generator: state.id_generator
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
      llm_stream?: Keyword.get(opts, :llm_stream, false),
      cancellation_signal:
        Keyword.get(opts, :cancellation_signal) || Keyword.get(opts, :cancel_signal)
    }
  end

  defp maybe_put_cancellation_signal(opts, nil), do: opts

  defp maybe_put_cancellation_signal(opts, signal),
    do: Keyword.put(opts, :cancellation_signal, signal)

  defp tool_context(%State{} = state, %{cancellation_signal: nil}), do: state.context

  defp tool_context(%State{} = state, %{cancellation_signal: signal}) do
    Map.put(state.context, :cancellation_signal, signal)
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
