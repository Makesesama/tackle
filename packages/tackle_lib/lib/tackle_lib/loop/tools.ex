defmodule Tackle.Lib.Loop.Tools do
  @moduledoc false

  # Tool execution for one `Tackle.Lib.Loop` step. Every call goes through the
  # same pipeline:
  #
  #   * accept: the `before_tool_call` hooks;
  #   * gate: the run's `:before_tool_execution` callback, skipped when every
  #     call it covers is read-only or cannot be resolved;
  #   * start: the `tool_start` event and the call's execution job;
  #   * run: the job settles (`settle/1`), then `tool_execution_end`;
  #   * commit: the tool result message, its `message_end` and `after_message`
  #     hooks, `tool_end` or `tool_error`, then the `after_tool_call` hooks.
  #
  # The policies differ in how calls are grouped. The sequential policy takes
  # one call at a time through the whole pipeline, inline in the loop process.
  # The concurrent policy accepts and starts each call in turn, passes the gate
  # once for the batch, runs the jobs in supervised tasks
  # (`Tackle.Lib.Tool.Batch`), and commits them in call order; its `tool_start`
  # events therefore come before the gate. Cancellation is checked before the
  # step's first call is accepted and again before anything starts or runs.
  #
  # The loop process stays the only writer of `State`: a job carries only what
  # its tool needs, never the transcript. Every step returns `{:ok, state}`,
  # `{:error, state}` with `state.error` set, or `{:cancelled, state}`.

  require Logger

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Loop.Run
  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages
  alias Tackle.Lib.ProviderGate
  alias Tackle.Lib.State
  alias Tackle.Lib.Telemetry
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Batch
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error, as: ToolError
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Tool.Registry
  alias Tackle.Lib.Tool.Result, as: ToolResult

  @type result :: {:ok | :error | :cancelled, State.t()}

  @telemetry_event [:tackle, :tool, :execution]

  @doc """
  Executes the tool calls of one assistant message under the state's tool
  policy and appends their results to `state`. The calls already carry ids.
  """
  @spec execute(State.t(), [Call.t()], Run.t()) :: result()
  def execute(%State{tool_policy: %Policy{execution_mode: :concurrent}} = state, calls, run),
    do: execute_batch(calls, state, run)

  def execute(%State{} = state, calls, run), do: execute_each(calls, state, run)

  @doc """
  Settles the tool calls in `state.messages` that have no result with
  synthetic error results, saying the call was `outcome` ("interrupted",
  "aborted", or "cancelled") before it completed.

  A turn that ends while tool calls are unresolved leaves an assistant
  message whose calls have no results, which providers reject on the next
  request. The results go through the normal message finalization path, so
  durable sessions persist them like any other tool result. A failing
  finalization hook does not replace the outcome being settled: the state's
  status and error are kept.
  """
  @spec settle_interrupted(State.t(), Run.t(), String.t()) :: State.t()
  def settle_interrupted(%State{} = state, %Run{} = run, outcome) when is_binary(outcome) do
    settled =
      state.messages
      |> Messages.unresolved_tool_calls()
      |> Enum.reduce(state, &settle_interrupted_call(&1, &2, run, outcome))

    %{settled | status: state.status, error: state.error}
  end

  defp settle_interrupted_call(%{id: id, name: name}, %State{} = state, run, outcome) do
    content = "Error: Tool execution was #{outcome} before this call completed."
    message = Message.tool_result(id, name, content, id_generator: state.id_generator)
    state = State.add_message(state, message)

    case Run.finalize_message(state, run, message) do
      {:ok, state} ->
        Run.emit(
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

  # ── Policies ──────────────────────────────────────────────────────────

  defp execute_each(calls, state, run),
    do: each_ok(calls, state, &execute_one(&1, &2, run))

  # A sequential call is announced with `tool_start` only once the gate has
  # let it through.
  defp execute_one(call, state, run) do
    with {:ok, state} <- checkpoint(state, run),
         {:ok, state} <- accept(call, state, run),
         {:ok, state} <- pass_gate([call], state, run) do
      call
      |> start(state, run)
      |> run_inline(run)
      |> commit(state, run)
    end
  end

  # Hooks may update the context between calls, so each call is started right
  # after its own hooks accepted it, before the next call's hooks run.
  defp execute_batch(calls, state, run) do
    with {:ok, state} <- checkpoint(state, run),
         {:ok, jobs, state} <- prepare_batch(calls, [], state, run) do
      case pass_gate(Enum.map(jobs, & &1.call), state, run) do
        {:ok, state} ->
          run_batch(jobs, state, run)

        halted ->
          discard(jobs)
          halted
      end
    end
  end

  defp prepare_batch([], jobs, state, _run), do: {:ok, Enum.reverse(jobs), state}

  defp prepare_batch([call | calls], jobs, state, run) do
    with {:ok, state} <- accept(call, state, run),
         {:ok, state} <- checkpoint(state, run) do
      prepare_batch(calls, [start(call, state, run) | jobs], state, run)
    else
      halted ->
        discard(jobs)
        halted
    end
  end

  # A cancelled batch can lack settlements for tools that never finished; those
  # calls are skipped so a tool that did run still records its result. A
  # failing commit takes precedence over the cancellation.
  defp run_batch(jobs, state, run) do
    {settlements, outcome} =
      Batch.run(
        jobs,
        run.tool_supervisor,
        &settle/1,
        &emit_execution_end(&1, run),
        fn -> Run.cancelled?(run) end
      )

    settlements
    |> Enum.sort_by(fn {index, _settlement} -> index end)
    |> each_ok(state, fn {_index, settlement}, state -> commit(settlement, state, run) end)
    |> case do
      {:ok, state} when outcome == :cancelled -> {:cancelled, Run.mark_cancelled(state, run)}
      result -> result
    end
  end

  # Threads `state` through `step` for each item while every step returns
  # `{:ok, state}`, and returns the first other result.
  defp each_ok(items, state, step) do
    Enum.reduce_while(items, {:ok, state}, fn item, {:ok, state} ->
      case step.(item, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        halted -> {:halt, halted}
      end
    end)
  end

  # No job that was started but will not run is settled, so nothing else
  # deletes its per-call cancellation record.
  defp discard(jobs), do: Enum.each(jobs, &Cancellation.delete(&1.call_signal))

  # ── Steps ─────────────────────────────────────────────────────────────

  defp checkpoint(state, run) do
    if Run.cancelled?(run),
      do: {:cancelled, Run.mark_cancelled(state, run)},
      else: {:ok, state}
  end

  defp accept(%Call{} = call, state, run) do
    case Run.invoke_hook(state, run, :before_tool_call, [state, call]) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:error, State.set_error(state, "Hook aborted before tool call: #{inspect(reason)}")}
    end
  end

  # Cancellation is checked again after the gate, which may have blocked.
  defp pass_gate(calls, state, run) do
    if Enum.any?(calls, &external_effect?(&1, run)) do
      case ProviderGate.await(run.before_tool_execution, :before_tool_execution) do
        :ok ->
          checkpoint(state, run)

        {:error, reason} ->
          {:error, State.set_error(state, "Tool execution gate failed: #{inspect(reason)}")}
      end
    else
      checkpoint(state, run)
    end
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

  # Emits `tool_start` and builds the call's job: the resolved call, its
  # execution context, and telemetry inputs. A failure while preparing the
  # call (for example, an invalid host execution context) is kept in the job,
  # so it settles as a crash with the job's telemetry like any other.
  defp start(%Call{} = call, state, run) do
    Run.emit(
      run,
      Event.new(:tool_start, %{tool_call_id: call.id, name: call.name, arguments: call.arguments})
    )

    call_signal = Cancellation.for_call(run.cancellation_signal, call.id)

    execution =
      try do
        case Registry.resolve(run.snapshot.tool_registry, call) do
          {:ok, %{module: module}} -> {:ok, module, tool_context(state, run, call, call_signal)}
          {:error, :unknown_tool} -> {:error, ToolError.unknown_tool(call)}
          {:error, :stale_tool_definition} -> {:error, ToolError.stale_definition(call)}
        end
      catch
        kind, reason -> {:raise, kind, reason, __STACKTRACE__}
      end

    %{
      call: call,
      call_signal: call_signal,
      execution: execution,
      telemetry_name: telemetry_tool_name(call.name, state.context)
    }
  end

  # Tools see the state's context with the run's `:tool_context` merged over
  # it, and the loop's own keys on top: the run's event callback, so a tool can
  # report progress through the same path as the loop, and the call's id.
  # Tools receive their call's child signal: it observes turn cancellation and
  # can also be cancelled on its own to stop just this call. The loop's boundary
  # checks keep using the turn signal.
  defp tool_context(%State{} = state, %Run{} = run, %Call{} = call, call_signal) do
    context =
      state.context
      |> Map.merge(run.tool_context)
      |> Map.put(:event_callback, run.event_callback)
      |> Map.put(:tool_call_id, call.id)

    case call_signal do
      nil -> context
      signal -> Map.put(context, :cancellation_signal, signal)
    end
  end

  defp run_inline(job, run) do
    settlement = settle(job)
    emit_execution_end(settlement, run)
    settlement
  end

  # Settles one job: executes the tool through `Tool.settle/3` inside the
  # `[:tackle, :tool, :execution]` telemetry span. It runs inline under the
  # sequential policy and inside a supervised task under the concurrent one,
  # so it never touches agent state or emits agent events. Once the call
  # settles, its per-call cancellation record (if a host cancelled it) is no
  # longer observed by anyone, so it is deleted.
  defp settle(%{call: call, execution: execution, telemetry_name: name} = job) do
    telemetry_ref = Telemetry.start(@telemetry_event, %{tool_name: name})
    started_at = System.monotonic_time()

    try do
      settlement =
        case execution do
          {:ok, module, context} -> Tool.settle(module, call, context)
          {:error, %ToolError{} = error} -> {:error, error}
          {:raise, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
        end

      Telemetry.stop(
        @telemetry_event,
        telemetry_ref,
        %{duration: Telemetry.monotonic_duration(started_at), count: 1},
        %{tool_name: name, outcome: tool_outcome(settlement)}
      )

      settlement
    catch
      # Tool.settle/3 turns a tool's own failures into error results. What is
      # left (preparing the call failed, or settlement itself raised) settles
      # the call as crashed, so one call cannot take down the loop and leave
      # its batch unresolved.
      kind, reason ->
        stacktrace = __STACKTRACE__

        Telemetry.exception(
          @telemetry_event,
          telemetry_ref,
          %{duration: Telemetry.monotonic_duration(started_at), count: 1},
          %{tool_name: name, error_type: kind}
        )

        Logger.error(fn ->
          [
            "Tool call ",
            inspect(call.name),
            " crashed: ",
            Exception.format(kind, reason, stacktrace)
          ]
        end)

        {:error, ToolError.crashed(call, kind, reason)}
    end
  after
    Cancellation.delete(job.call_signal)
  end

  defp telemetry_tool_name(name, context) when is_binary(name) do
    allowed_names = get_in(context, [:telemetry, :tool_names]) || []
    if name in allowed_names, do: name, else: "other"
  end

  defp telemetry_tool_name(_name, _context), do: "other"

  defp tool_outcome({:ok, %ToolResult{}}), do: :success
  defp tool_outcome({:error, %ToolError{reason: reason}}), do: bounded_tool_error(reason)

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

  # Execution progress is transient and may arrive out of call order. Keep it
  # separate from tool_end/tool_error, which follow ordered message persistence.
  # Only the loop process emits these events, never the worker tasks.
  defp emit_execution_end({:ok, %ToolResult{} = result}, run) do
    Run.emit(
      run,
      Event.new(:tool_execution_end, %{
        tool_call_id: result.tool_call_id,
        name: result.name,
        status: :completed,
        result: result.content
      })
    )
  end

  defp emit_execution_end({:error, %ToolError{} = error}, run) do
    Run.emit(
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

  defp commit({:ok, %ToolResult{} = result}, state, run) do
    message =
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

    commit_settlement(state, run, message, event, result)
  end

  defp commit({:error, %ToolError{} = error}, state, run) do
    name = error.name || "unknown"

    message =
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

    commit_settlement(state, run, message, event, error)
  end

  defp commit_settlement(state, run, message, event, settlement) do
    state = State.add_message(state, message)

    with {:ok, state} <- Run.finalize_message(state, run, message) do
      Run.emit(run, event)

      case Run.invoke_hook(state, run, :after_tool_call, [state, settlement]) do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          {:error, State.set_error(state, "Hook aborted after tool call: #{inspect(reason)}")}
      end
    end
  end
end
