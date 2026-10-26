defmodule Tackle.Lib.CompactionTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Compaction
  alias Tackle.Lib.Compaction.Config, as: CompactionConfig
  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Compaction.Summary
  alias Tackle.Lib.LLM
  alias Tackle.Lib.Message
  alias Tackle.Lib.ModelInfo
  alias Tackle.Lib.State
  alias Tackle.Lib.Usage

  defmodule TestSummarizer do
    @behaviour Tackle.Lib.Compaction.Summarizer

    @impl true
    def summarize(request, opts) do
      Process.put(:last_request, request)
      Process.put(:last_summarizer_opts, opts)

      case Process.get(:summarize_result, {:ok, default_summary()}) do
        fun when is_function(fun, 1) -> fun.(request)
        result -> result
      end
    end

    def default_summary, do: %Summary{content: "checkpoint summary", usage: nil, model: "test/m"}
  end

  defmodule TestCommitter do
    @behaviour Tackle.Lib.Compaction.Committer

    @impl true
    def commit(record, context) do
      Process.put(:last_record, record)
      Process.put(:last_commit_context, context)
      Process.put(:commit_count, Process.get(:commit_count, 0) + 1)
      Process.get(:commit_result, :ok)
    end
  end

  defmodule FailingCommitter do
    @behaviour Tackle.Lib.Compaction.Committer

    @impl true
    def commit(_record, _context), do: {:error, :disk_full}
  end

  defmodule OverflowAdapter do
    @behaviour Tackle.Lib.LLM

    alias Tackle.Lib.Usage

    @impl true
    def adapter_id, do: "test"

    @impl true
    def models, do: ["large"]

    @impl true
    def model_info(_model), do: %{context_window: 100_000, max_output_tokens: 1_000}

    @impl true
    def generate(_schema, opts) do
      calls = Process.get(:adapter_calls, 0) + 1
      Process.put(:adapter_calls, calls)

      if always_overflow?() or calls in Process.get(:overflow_calls, [1]) do
        {:error, :context_window_exceeded}
      else
        {:ok,
         %{
           data: %{"content" => "answer", "tool_calls" => []},
           usage: Usage.normalize(%{"total_tokens" => 10}),
           model: Keyword.get(opts, :model, "large"),
           provider: "test"
         }}
      end
    end

    defp always_overflow?, do: Process.get(:always_overflow, false)
  end

  setup do
    for key <- [
          :last_request,
          :last_summarizer_opts,
          :last_record,
          :last_commit_context,
          :summarize_result,
          :commit_result,
          :commit_count,
          :adapter_calls,
          :always_overflow,
          :overflow_calls,
          :incoming_polls,
          :summarize_calls
        ] do
      Process.delete(key)
    end

    :ok
  end

  describe "compact/3" do
    test "replaces the model projection with a checkpoint and a verbatim tail" do
      state = state([user(700), assistant(700)])

      assert {:ok, compacted, %Record{} = record} = Compaction.compact(state, :pressure, [])

      # The canonical transcript is untouched.
      assert Enum.map(compacted.messages, & &1.id) == Enum.map(state.messages, & &1.id)

      assert [checkpoint, retained] = compacted.model_messages
      assert Compaction.checkpoint?(checkpoint)
      assert checkpoint.id == record.compaction_id
      assert retained.id == List.last(state.messages).id

      assert record.trigger == :pressure
      assert record.shadowed_message_ids == [hd(state.messages).id]
      assert record.first_retained_message_id == retained.id
      assert record.tokens_before > 0
      assert record.estimated_tokens_after > 0

      assert Process.get(:last_record) == record
      assert Process.get(:last_commit_context).session_id == state.session_id
    end

    test "does nothing below the pressure threshold" do
      state = state([user(10), assistant(10)])

      assert {:error, :nothing_to_compact} = Compaction.compact(state, :pressure, [])
      refute Process.get(:last_record)
    end

    test "manual compaction bypasses the pressure threshold" do
      state = state([user(10), assistant(10)])

      assert {:ok, compacted, record} = Compaction.compact(state, :manual, [])
      assert record.trigger == :manual
      assert Compaction.checkpoint?(hd(compacted.model_messages))
    end

    test "forwards state LLM options and applies per-call overrides" do
      credential_store = {TestCredentialStore, make_ref()}

      state =
        state([user(10), assistant(10)],
          llm_opts: [credential_store: credential_store, receive_timeout: 1_000]
        )

      assert {:ok, _compacted, _record} =
               Compaction.compact(state, :manual,
                 llm_opts: [receive_timeout: 2_000, request_tag: "summary"]
               )

      assert Process.get(:last_summarizer_opts) ==
               [
                 llm_opts: [
                   credential_store: credential_store,
                   receive_timeout: 2_000,
                   request_tag: "summary"
                 ],
                 cancellation_signal: nil
               ]
    end

    test "disables automatic pressure compaction without a usable window" do
      state = state([user(700), assistant(700)], policy: [safety_reserve: 5_000])

      assert {:error, :nothing_to_compact} = Compaction.compact(state, :pressure, [])
    end

    test "reports no_context_window when the adapter declares no window" do
      state = %{state([user(700), assistant(700)]) | llm: nil}

      assert {:error, :no_context_window} = Compaction.resolve(state)
      assert {:error, :no_context_window} = Compaction.compact(state, :pressure, [])
    end

    test "resets retained usage and provider state without changing the transcript" do
      usage = Usage.normalize(%{"total_tokens" => 5_000})
      provider_state = %{"provider" => "test", "opaque" => text(10_000)}
      retained = %{assistant(700) | token_usage: usage, provider_state: provider_state}
      state = state([user(700), retained])

      assert {:ok, compacted, record} = Compaction.compact(state, :manual, [])

      assert record.tokens_before == 5_000
      compacted_retained = List.last(compacted.model_messages)
      canonical_retained = List.last(compacted.messages)

      assert compacted_retained.token_usage == nil
      assert compacted_retained.provider_state == nil
      assert canonical_retained.token_usage == usage
      assert canonical_retained.provider_state == provider_state
    end

    test "a summary failure changes neither the model surface nor the journal" do
      state = state([user(700), assistant(700)])
      Process.put(:summarize_result, {:error, :provider_unavailable})

      assert {:error, :provider_unavailable} = Compaction.compact(state, :pressure, [])
      assert state.model_messages == nil
      refute Process.get(:last_record)
    end

    test "rejects an empty summary" do
      state = state([user(700), assistant(700)])
      Process.put(:summarize_result, {:ok, %Summary{content: ""}})

      assert {:error, :empty_summary} = Compaction.compact(state, :pressure, [])
      refute Process.get(:last_record)
    end

    test "rejects a non-shrinking summary" do
      state =
        state([user(700), assistant(700)],
          policy: [summary_max_tokens: 10_000, max_summary_tokens: 10_000]
        )

      Process.put(:summarize_result, {:ok, %Summary{content: text(700)}})

      assert {:error, :summary_not_smaller} = Compaction.compact(state, :pressure, [])
      refute Process.get(:last_record)
    end

    test "rejects a summary that reached the output cap" do
      state = state([user(700), assistant(700)])

      Process.put(
        :summarize_result,
        {:ok,
         %Summary{
           content: text(600),
           usage: Usage.normalize(%{"output_tokens" => 500})
         }}
      )

      assert {:error, :truncated_summary} = Compaction.compact(state, :pressure, [])
    end

    test "a durable commit failure is reported and leaves the surface unchanged" do
      state = state([user(700), assistant(700)])
      Process.put(:commit_result, {:error, :disk_full})

      assert {:error, {:durable_commit_failed, :disk_full}} =
               Compaction.compact(state, :pressure, [])

      assert state.model_messages == nil
    end

    test "a cancelled signal aborts before any commit" do
      state = state([user(700), assistant(700)])
      signal = Cancellation.new_signal()
      :ok = Cancellation.cancel(signal, :user_cancelled)

      assert {:cancelled, :user_cancelled} =
               Compaction.compact(state, :pressure, cancellation_signal: signal)

      refute Process.get(:last_record)
    end

    test "the provider gate is checked before every tightening pass" do
      state =
        state([user(3_000), assistant(3_000)],
          config_opts: [max_passes: 2],
          policy: [summary_max_tokens: 100, max_summary_tokens: 100]
        )

      gate = fn ->
        Process.put(:gate_count, Process.get(:gate_count, 0) + 1)
        :ok
      end

      assert {:ok, _, _} = Compaction.compact(state, :pressure, before_provider_call: gate)
      assert Process.get(:gate_count) == 2
      assert Process.get(:commit_count) == 2
    end

    test "a rejected provider gate prevents summarization and checkpoint commit" do
      state = state([user(700), assistant(700)])

      assert {:error, :storage_unavailable} =
               Compaction.compact(state, :pressure,
                 before_provider_call: fn -> {:error, :storage_unavailable} end
               )

      refute Process.get(:last_request)
      refute Process.get(:last_record)
    end

    test "cancellation during the provider gate prevents summarizer dispatch" do
      state = state([user(700), assistant(700)])
      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)

      assert {:cancelled, :user_cancelled} =
               Compaction.compact(state, :pressure,
                 cancellation_signal: signal,
                 before_provider_call: fn -> Cancellation.cancel(signal, :user_cancelled) end
               )

      refute Process.get(:last_request)
      refute Process.get(:last_record)
    end

    test "cancellation during a failing gate takes precedence over gate errors" do
      Enum.each([:error, :raise], fn mode ->
        state = state([user(700), assistant(700)])
        signal = Cancellation.new_signal()
        on_exit(fn -> Cancellation.delete(signal) end)

        assert {:cancelled, :user_cancelled} =
                 Compaction.compact(state, :pressure,
                   cancellation_signal: signal,
                   before_provider_call: fn ->
                     Cancellation.cancel(signal, :user_cancelled)
                     if mode == :error, do: {:error, :unavailable}, else: raise("unavailable")
                   end
                 )

        refute Process.get(:last_request)
        refute Process.get(:last_record)
      end)
    end

    test "a cancelled second-pass gate preserves the previously committed checkpoint" do
      state =
        state([user(3_000), assistant(3_000)],
          config_opts: [max_passes: 2],
          policy: [summary_max_tokens: 100, max_summary_tokens: 100]
        )

      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)

      assert {:cancelled, :user_cancelled, committed} =
               Compaction.compact(state, :pressure,
                 cancellation_signal: signal,
                 before_provider_call: fn ->
                   if Process.get(:commit_count, 0) == 0 do
                     :ok
                   else
                     Cancellation.cancel(signal, :user_cancelled)
                     {:error, :unavailable}
                   end
                 end
               )

      assert Process.get(:commit_count) == 1
      assert [checkpoint | _] = committed.model_messages
      assert checkpoint.id == Process.get(:last_record).compaction_id
      assert committed.messages == state.messages
    end

    test "cancellation during summarization does not commit a checkpoint" do
      state = state([user(700), assistant(700)])
      signal = Cancellation.new_signal()

      Process.put(:summarize_result, fn _request ->
        :ok = Cancellation.cancel(signal, :user_cancelled)
        {:ok, TestSummarizer.default_summary()}
      end)

      assert {:cancelled, :user_cancelled} =
               Compaction.compact(state, :pressure, cancellation_signal: signal)

      assert Process.get(:last_summarizer_opts)[:cancellation_signal] == signal
      refute Process.get(:last_record)
    end

    test "a cancelled summarizer error is reported as cancellation" do
      state = state([user(700), assistant(700)])
      signal = Cancellation.new_signal()

      Process.put(:summarize_result, fn _request ->
        :ok = Cancellation.cancel(signal, :user_cancelled)
        {:error, :provider_stopped}
      end)

      assert {:cancelled, :user_cancelled} =
               Compaction.compact(state, :pressure, cancellation_signal: signal)

      refute Process.get(:last_record)
    end

    test "merges a prior checkpoint instead of growing a chain" do
      state = state([user(700), assistant(700)])

      assert {:ok, once, _record} = Compaction.compact(state, :manual, [])
      assert {:ok, twice, _record} = Compaction.compact(once, :manual, [])

      checkpoints = Enum.filter(twice.model_messages, &Compaction.checkpoint?/1)
      assert [_checkpoint] = checkpoints

      request = Process.get(:last_request)
      assert request.prior_summary == "checkpoint summary"
    end

    test "runs a second tightening pass when pressure remains" do
      state =
        state([user(3_000), assistant(3_000)],
          config_opts: [max_passes: 2],
          policy: [summary_max_tokens: 100, max_summary_tokens: 100]
        )

      assert {:ok, compacted, _record} = Compaction.compact(state, :pressure, [])
      assert Process.get(:commit_count) == 2
      assert Enum.count(compacted.model_messages, &Compaction.checkpoint?/1) == 1
    end

    test "a failed second pass returns the checkpoint already durably committed" do
      state =
        state([user(3_000), assistant(3_000)],
          config_opts: [max_passes: 2],
          policy: [summary_max_tokens: 100, max_summary_tokens: 100]
        )

      Process.put(:summarize_result, fn _request ->
        if Process.get(:commit_count, 0) == 0 do
          {:ok, TestSummarizer.default_summary()}
        else
          {:error, :second_pass_failed}
        end
      end)

      assert {:error, :second_pass_failed, committed} =
               Compaction.compact(state, :pressure, [])

      assert Process.get(:commit_count) == 1
      assert [checkpoint | _] = committed.model_messages
      assert checkpoint.id == Process.get(:last_record).compaction_id
      assert committed.messages == state.messages
    end

    test "emits lifecycle events without raw summary content" do
      state = state([user(700), assistant(700)])
      events = collect_events(state)

      assert Enum.map(events, & &1.type) == [:compaction_start, :compaction_end]

      [start, finish] = events
      assert start.data.trigger == :pressure
      assert finish.data.status == :completed
      assert finish.data.shadowed_count == 1
      assert finish.data.summary_model == "test/m"
      refute inspect(events) =~ "checkpoint summary"
    end
  end

  describe "loop integration" do
    test "recovers from one provider context overflow by compacting and retrying" do
      state = loop_state([user(100), assistant(100)])

      assert {:ok, final} = Tackle.Lib.run(state, "next")
      assert Process.get(:adapter_calls) == 2
      assert Tackle.Lib.last_answer(final) == "answer"
      assert Enum.any?(final.model_messages, &Compaction.checkpoint?/1)
    end

    test "does not retry overflow more than once" do
      Process.put(:always_overflow, true)
      state = loop_state([user(100), assistant(100)])

      assert {:error, final} = Tackle.Lib.run(state, "next")
      assert Process.get(:adapter_calls) == 2
      assert final.error =~ "context_window_exceeded"
    end

    test "spends the overflow retry limit per turn, not per step" do
      Process.put(:overflow_calls, [1, 3])
      state = loop_state([user(100), assistant(100)])

      # The second poll comes after the first answer and continues the turn
      # with another step, whose request overflows again.
      take_incoming_messages = fn ->
        polls = Process.get(:incoming_polls, 0) + 1
        Process.put(:incoming_polls, polls)
        if polls == 2, do: {:ok, ["follow up"]}, else: {:ok, []}
      end

      assert {:error, final} =
               Tackle.Lib.run(state, "next", take_incoming_messages: take_incoming_messages)

      assert Process.get(:adapter_calls) == 3
      assert final.error =~ "context_window_exceeded"

      # The next turn has its own budget.
      Process.put(:overflow_calls, [4])
      assert {:ok, final} = Tackle.Lib.continue(final)
      assert Process.get(:adapter_calls) == 5
      assert Tackle.Lib.last_answer(final) == "answer"
    end

    test "continues after a pressure summary failure without changing the model surface" do
      state = state([user(700), assistant(700)])
      Process.put(:adapter_calls, 1)
      Process.put(:summarize_result, {:error, :summary_unavailable})

      assert {:ok, final} = Tackle.Lib.run(state, "next")
      assert final.model_messages == nil
      assert Tackle.Lib.last_answer(final) == "answer"
      refute Process.get(:last_record)
    end

    test "keeps the provider error when overflow compaction fails" do
      state = loop_state([user(100), assistant(100)])
      Process.put(:summarize_result, {:error, :summary_unavailable})

      assert {:error, final} = Tackle.Lib.run(state, "next")
      assert final.error =~ "context_window_exceeded"
      assert Process.get(:adapter_calls) == 1
      assert final.model_messages == nil
    end

    test "continues from a committed checkpoint when a later pressure pass fails" do
      state =
        state([user(3_000), assistant(3_000)],
          config_opts: [max_passes: 2],
          policy: [summary_max_tokens: 100, max_summary_tokens: 100]
        )

      Process.put(:adapter_calls, 1)

      Process.put(:summarize_result, fn _request ->
        if Process.get(:commit_count, 0) == 0 do
          {:ok, TestSummarizer.default_summary()}
        else
          {:error, :second_pass_failed}
        end
      end)

      assert {:ok, final} = Tackle.Lib.run(state, "next")
      assert Process.get(:commit_count) == 1
      assert [checkpoint | _] = final.model_messages
      assert checkpoint.id == Process.get(:last_record).compaction_id
      assert Tackle.Lib.last_answer(final) == "answer"
    end

    test "retries an overflow with a committed pass when a later pass fails" do
      state =
        state([user(3_000), assistant(3_000)],
          config_opts: [max_passes: 2],
          policy: [summary_max_tokens: 100, max_summary_tokens: 100]
        )

      # Summaries alternate success and failure: each compaction commits its
      # first pass and fails its second, before and after the overflow.
      Process.put(:summarize_result, fn _request ->
        calls = Process.get(:summarize_calls, 0) + 1
        Process.put(:summarize_calls, calls)

        if rem(calls, 2) == 1,
          do: {:ok, TestSummarizer.default_summary()},
          else: {:error, :later_pass_failed}
      end)

      assert {:ok, final} = Tackle.Lib.run(state, "next")
      assert Process.get(:summarize_calls) == 4
      assert Process.get(:commit_count) == 2
      assert Process.get(:adapter_calls) == 2
      assert Tackle.Lib.last_answer(final) == "answer"
    end

    test "does not attempt overflow recovery when compaction is disabled" do
      state = state([user(100), assistant(100)], config_opts: [enabled?: false])
      test_pid = self()

      assert {:error, final} =
               Tackle.Lib.run(state, "next", event_callback: &send(test_pid, {:event, &1.type}))

      assert final.error =~ "context_window_exceeded"
      assert Process.get(:adapter_calls) == 1
      refute_received {:event, :compaction_retry}
    end

    test "fails an overflow recovery when the durable commit fails" do
      state = loop_state([user(100), assistant(100)])
      state = %{state | compaction: %{state.compaction | committer: FailingCommitter}}

      assert {:error, final} = Tackle.Lib.run(state, "next")
      assert final.error =~ "durable_commit_failed"
      assert Process.get(:adapter_calls) == 1
      assert final.model_messages == nil
    end

    test "fails the turn before the provider call when the durable commit fails" do
      state = state([user(700), assistant(700)], committer: FailingCommitter)

      assert {:error, final} = Tackle.Lib.run(state, "next")
      assert final.status == :error
      assert Process.get(:adapter_calls, 0) == 0
      assert state.model_messages == nil
    end
  end

  # --- helpers ---

  defp collect_events(state) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {:ok, _compacted, _record} =
      Compaction.compact(state, :pressure,
        event_callback: fn event -> Agent.update(agent, &List.insert_at(&1, -1, event)) end
      )

    Agent.get(agent, & &1)
  end

  defp loop_state(messages) do
    messages
    |> state(
      policy: [
        response_reserve: 100,
        safety_reserve: 0,
        attention_ratio: 0.9,
        retain_tokens: 50,
        summary_max_tokens: 1_000,
        max_summary_tokens: 1_000
      ]
    )
    |> Map.put(:system_prompt, "system")
    |> Map.put(:max_iterations, 5)
  end

  defp state(messages, opts \\ []) do
    config =
      CompactionConfig.new!(
        policy:
          Keyword.merge(
            [
              response_reserve: 10,
              safety_reserve: 0,
              attention_ratio: 0.5,
              retain_tokens: 100,
              summary_max_tokens: 500,
              max_summary_tokens: 500
            ],
            Keyword.get(opts, :policy, [])
          ),
        summarizer: TestSummarizer,
        committer: Keyword.get(opts, :committer, TestCommitter)
      )
      |> then(fn config -> struct(config, Keyword.get(opts, :config_opts, [])) end)

    State.new(
      llm: selection(),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      compaction: config
    )
    |> then(fn state -> Enum.reduce(messages, state, &State.add_message(&2, &1)) end)
  end

  defp selection do
    %LLM.Selection{
      adapter: OverflowAdapter,
      provider_id: "test",
      model: "large",
      ref: "test/large",
      model_info: %ModelInfo{model: "large", context_window: 2_000, max_output_tokens: 100}
    }
  end

  defp user(size), do: Message.user(text(size))

  defp assistant(size) do
    Message.assistant(content: text(size))
  end

  defp text(size), do: String.duplicate("x", size * 4)
end
