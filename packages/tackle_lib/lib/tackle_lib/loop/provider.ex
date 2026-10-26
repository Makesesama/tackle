defmodule Tackle.Lib.Loop.Provider do
  @moduledoc false

  # The provider call of one `Tackle.Lib.Loop` step, from the request to the
  # response the step keeps. `request/2` is the loop's only entry point.
  #
  # Every dispatch passes the run's `:before_provider_call` gate and a
  # cancellation check, then generates, or streams when the run asks for it.
  # A gate refusal is host policy and ends the request; it is never retried.
  # While streaming, the adapter's `:usage` events are dropped, since the
  # response's usage is reported once below, and stream events without an id
  # get the id of the assistant message the step generates (`run.assistant_id`).
  #
  # One recursive attempt loop settles each dispatch:
  #
  #   * cancellation ends the request;
  #   * a provider-confirmed context overflow is compacted (`:compaction_retry`)
  #     and the request is sent again, up to the compaction policy's
  #     `overflow_retry_limit` per turn (`run.overflow_retries`);
  #   * a transient `Tackle.Lib.LLM.Error` is retried under the snapshot's
  #     `Tackle.Lib.Retry` policy (`:retry_scheduled`, the backoff,
  #     `:retry_start`);
  #   * any other failure ends the request with the provider's reason;
  #   * a result is normalized into a `Tackle.Lib.LLM.Response`, whose usage is
  #     reported with a `:usage` event. A malformed result ends the request
  #     with `{:invalid_response, detail}`.
  #   * an empty response (neither content nor tool calls) is asked again once,
  #     as a retry of the same request with reason `:empty_response` that does
  #     not count against the retry policy; a second empty response in a row
  #     ends the request.
  #
  # A retried dispatch ends its retry with one `:retry_end` event. Only the
  # response the step keeps is returned, so the loop and its `after_prompt`
  # hooks never see a re-asked empty response. The result is
  # `{:ok, response, state, run}`, with the run's overflow recoveries counted,
  # `{:error, state}` with `state.error` and `state.error_reason` set, or
  # `{:cancelled, state}`. The state can change even without a response:
  # overflow compaction commits checkpoints.

  require Logger

  alias Tackle.Lib.Compaction
  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.Loop.Run
  alias Tackle.Lib.Messages
  alias Tackle.Lib.ProviderGate
  alias Tackle.Lib.Retry
  alias Tackle.Lib.State
  alias Tackle.Lib.SystemPrompt
  alias Tackle.Lib.Tool.Registry
  alias Tackle.Lib.Usage

  @type result ::
          {:ok, Response.t(), State.t(), Run.t()} | {:error, State.t()} | {:cancelled, State.t()}

  @doc """
  Requests the step's response from the snapshot's provider, with retries,
  overflow recovery, and one re-ask of an empty response.
  """
  @spec request(State.t(), Run.t()) :: result()
  def request(%State{} = state, %Run{} = run),
    do: attempt(state, run, %{retries: 0, reasked?: false, open: nil})

  # `tries` tracks one request's attempts:
  #
  #   * `retries` - the transient retries used, counted against the retry
  #     policy. Overflow recovery starts it again; the re-ask does not touch it.
  #   * `reasked?` - true once the step asked again after an empty response;
  #     it survives retries and overflow recovery of the re-ask.
  #   * `open` - the attempt number of the retry (or re-ask) in progress, which
  #     the next settlement ends with one `:retry_end`, or `nil`.
  defp attempt(state, run, tries) do
    state
    |> dispatch(run)
    |> settle(state, run, tries)
  end

  defp settle({:ok, result}, state, run, tries) do
    tries = end_retry(run, tries, true, nil)

    if Run.cancelled?(run),
      do: cancel(state, run),
      else: accept(result, state, run, tries)
  end

  # The host's `before_provider_call` gate refused the dispatch. That is host
  # policy, not a provider failure, so it is never retried.
  defp settle({:gate_error, reason}, state, run, tries) do
    end_retry(run, tries, false, reason)

    if Run.cancelled?(run),
      do: cancel(state, run),
      else: fail_request(state, reason)
  end

  defp settle({:error, reason}, state, run, tries) do
    cond do
      Run.cancelled?(run) ->
        end_retry(run, tries, false, reason)
        cancel(state, run)

      recoverable_overflow?(state, reason, run) ->
        end_retry(run, tries, false, reason)
        recover_overflow(state, reason, run, tries)

      Retry.available?(run.snapshot.retry, tries.retries) and Retry.retryable?(reason) ->
        schedule_retry(state, run, reason, tries)

      true ->
        end_retry(run, tries, false, reason)
        Logger.error("LLM call failed: #{inspect(reason)}")
        fail_request(state, reason)
    end
  end

  defp accept(result, state, run, tries) do
    case Response.from_result(result) do
      {:ok, response} ->
        emit_usage(run, response.usage)

        cond do
          not Response.empty?(response) ->
            {:ok, response, state, run}

          tries.reasked? ->
            fail(state, "The model returned an empty response", :empty_response)

          true ->
            reask(state, run, tries)
        end

      {:error, {:invalid_response, detail} = reason} ->
        # The provider still spent the tokens of a response it got wrong.
        emit_usage(run, result_usage(result))
        Logger.error("LLM returned an invalid response: #{inspect(detail)}")
        fail(state, invalid_response_message(detail), reason)
    end
  end

  # A response with neither content nor tool calls (a content filter, a
  # reasoning-only reply, or a server returning an empty message) is asked again
  # once, as a retry of the same request: the retry events let hosts discard any
  # text streamed for it. It is numbered on its own (attempt 1 of 1) and leaves
  # the transient retry budget alone. A second empty response in a row ends the
  # request rather than inventing an answer or spending provider calls without
  # bound.
  defp reask(state, run, tries) do
    Logger.warning("LLM response had neither tool calls nor content; asking again")

    Run.emit(run, Event.retry_scheduled(1, 1, 0, :empty_response, id: run.assistant_id))
    Run.emit(run, Event.retry_start(1, id: run.assistant_id))
    attempt(state, run, %{tries | reasked?: true, open: 1})
  end

  defp schedule_retry(state, run, reason, tries) do
    policy = run.snapshot.retry
    retry = tries.retries + 1
    delay_ms = Retry.delay(policy, retry, reason)

    Run.emit(
      run,
      Event.retry_scheduled(retry, policy.max_retries, delay_ms, reason, id: run.assistant_id)
    )

    with :ok <- Retry.wait(delay_ms, run.cancellation_signal),
         false <- Run.cancelled?(run) do
      Run.emit(run, Event.retry_start(retry, id: run.assistant_id))
      attempt(state, run, %{tries | retries: retry, open: retry})
    else
      _cancelled ->
        end_retry(run, %{tries | open: retry}, false, reason)
        cancel(state, run)
    end
  end

  defp end_retry(_run, %{open: nil} = tries, _success?, _reason), do: tries

  defp end_retry(run, %{open: attempt} = tries, success?, reason) do
    Run.emit(run, Event.retry_end(attempt, success?, reason, id: run.assistant_id))
    %{tries | open: nil}
  end

  # Provider-confirmed context overflow is distinct from proactive pressure. The
  # turn may compact and reissue the same request up to the policy's
  # `overflow_retry_limit`, bypassing the normal threshold. If a compaction
  # pass was committed before a later pass failed, the smaller context is
  # still worth a retry; any other compaction failure keeps the original
  # provider error.
  defp recover_overflow(state, reason, run, tries) do
    Logger.warning("Provider reported context overflow; compacting and retrying")

    Run.emit(run, Event.compaction_retry(:overflow, reason))

    case Compaction.compact(state, :overflow, Run.compaction_opts(run)) do
      {:ok, state, _record} ->
        retry_after_overflow(state, run, tries)

      {:error, {:durable_commit_failed, _reason} = error} ->
        fail(state, inspect(error), error)

      {:error, {:durable_commit_failed, _reason} = error, committed_state} ->
        fail(committed_state, inspect(error), error)

      {:cancelled, _reason} ->
        cancel(state, run)

      {:cancelled, _reason, committed_state} ->
        cancel(committed_state, run)

      {:error, _compaction_reason, committed_state} ->
        retry_after_overflow(committed_state, run, tries)

      {:error, _compaction_reason} ->
        fail_request(state, reason)
    end
  end

  defp retry_after_overflow(state, run, tries) do
    run = %{run | overflow_retries: run.overflow_retries + 1}
    attempt(state, run, %{tries | retries: 0, open: nil})
  end

  defp recoverable_overflow?(%State{} = state, reason, run) do
    LLM.context_window_exceeded?(reason) and Compaction.enabled?(state) and
      overflow_retries_remaining?(state, run)
  end

  defp overflow_retries_remaining?(%State{} = state, run) do
    case Compaction.resolve(state, snapshot: run.snapshot) do
      {:ok, resolved, _info} -> run.overflow_retries < resolved.overflow_retry_limit
      {:error, _reason} -> false
    end
  end

  # ── Dispatch ──────────────────────────────────────────────────────────

  defp dispatch(%State{} = state, run) do
    with :ok <- ProviderGate.await(run.before_provider_call),
         false <- Run.cancelled?(run) do
      {schema, opts} = request_args(state, run)
      adapter = run.snapshot.llm || run.snapshot.llm_adapter

      if run.llm_stream? do
        LLM.stream_with(adapter, schema, opts, stream_callback(run))
      else
        LLM.generate_with(adapter, schema, opts)
      end
    else
      {:error, reason} -> {:gate_error, reason}
      true -> {:error, :cancelled}
    end
  end

  defp request_args(state, run) do
    snapshot = run.snapshot

    schema =
      SystemPrompt.response_schema(
        prompt_renderer: snapshot.prompt_renderer,
        prompt_renderer_opts: snapshot.prompt_renderer_opts
      )

    tools = Registry.definitions(snapshot.tool_registry)

    # Each persisted turn is its own role-tagged map. Assistant tool calls and
    # tool results are linked by tool_call_id, and subsequent requests extend
    # this array without injecting or replacing synthetic messages. Compaction
    # may have replaced the array with a checkpoint plus a recent tail.
    request =
      [
        model: snapshot.model,
        session_id: state.session_id,
        system: snapshot.system_prompt,
        messages: Messages.to_provider(State.model_messages(state)),
        native_tools: tools != [],
        tools: tools
      ]
      |> put_cancellation_signal(run.cancellation_signal)

    opts =
      LLM.request_opts(
        request,
        [temperature: 0.3, strict_schema: false],
        snapshot.llm_opts
      )

    {schema, opts}
  end

  defp put_cancellation_signal(opts, nil), do: opts
  defp put_cancellation_signal(opts, signal), do: Keyword.put(opts, :cancellation_signal, signal)

  # The response's usage is reported once, when the response settles. Streaming
  # adapters and the non-streaming fallback also report it, which would make
  # hosts that sum usage events count every response twice.
  defp stream_callback(run) do
    pending_id = run.assistant_id

    fn
      %Event{type: :usage} -> :ok
      event -> Run.emit(run, stamp_pending_id(event, pending_id))
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

  # ── Outcomes ──────────────────────────────────────────────────────────

  defp emit_usage(run, %Usage{} = usage), do: Run.emit(run, Event.usage(usage))
  defp emit_usage(_run, _usage), do: :ok

  defp result_usage(%{usage: usage}), do: usage
  defp result_usage(_result), do: nil

  defp invalid_response_message({:tool_calls, reason}),
    do: "Invalid provider tool calls: #{inspect(reason)}"

  defp invalid_response_message(detail), do: "Invalid provider response: #{inspect(detail)}"

  defp cancel(state, run), do: {:cancelled, Run.mark_cancelled(state, run)}

  defp fail_request(state, reason),
    do: fail(state, "Failed to get response: #{describe_reason(reason)}", reason)

  defp describe_reason(%LLM.Error{} = error), do: Exception.message(error)
  defp describe_reason(reason), do: inspect(reason)

  defp fail(state, message, reason), do: {:error, State.set_error(state, message, reason)}
end
