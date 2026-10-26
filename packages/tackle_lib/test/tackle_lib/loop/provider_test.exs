defmodule Tackle.Lib.Loop.ProviderTest do
  # The provider call of a loop step (`Tackle.Lib.Loop.Provider`), driven
  # through `Tackle.Lib.Loop.run/3`: retries, the provider gate, streaming,
  # response normalization, and the empty-response re-ask. Overflow recovery
  # is covered by the "loop integration" tests in compaction_test.exs.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.Loop
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Usage

  defmodule FirstTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "first"

    @impl true
    def description, do: "First ordered test tool."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, %{test_pid: test_pid}) do
      send(test_pid, {:tool_execute, :first})
      {:ok, %{ok: true}}
    end
  end

  defmodule TestAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      {:ok,
       %{
         data: %{"content" => "done"},
         usage: %{prompt_tokens: 5, completion_tokens: 4},
         model: "test/model"
       }}
    end

    @impl true
    def stream(schema, opts, event_callback) do
      event_callback.(%{type: :text_delta, text: "do"})
      event_callback.(%{type: :text_delta, text: "ne"})
      generate(schema, opts)
    end
  end

  defmodule NoCallAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :llm_called)
      {:ok, %{data: %{"content" => "should not happen"}, usage: nil, model: "test/model"}}
    end
  end

  defmodule PermanentFailureAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :retry_call)
      {:error, {:http_error, 401, "unauthorized"}}
    end
  end

  # Returns the results in :script in order, then the last one again.
  defmodule ScriptedAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :llm_call)

      case Process.get(:script) do
        [result] ->
          result

        [result | rest] ->
          Process.put(:script, rest)
          result
      end
    end
  end

  defmodule AfterPromptHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def after_prompt(_state, response, context) do
      send(context.test_pid, {:after_prompt, response})
      :ok
    end
  end

  defmodule RetryThenSuccessAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      call_count = Process.get(:retry_call_count, 0)
      Process.put(:retry_call_count, call_count + 1)
      send(Process.get(:test_pid), {:retry_messages, Keyword.fetch!(opts, :messages)})

      if call_count == 0 do
        {:error, {:request_failed, :timeout}}
      else
        {:ok, %{data: %{"content" => "retried"}, usage: nil, model: "test/model"}}
      end
    end
  end

  defmodule AlwaysTransientAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :retry_call)
      {:error, {:http_error, 503, "unavailable"}}
    end
  end

  defmodule CancelDuringRetryAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      signal = Keyword.fetch!(opts, :cancellation_signal)
      send(Process.get(:test_pid), :retry_call)

      spawn(fn ->
        Process.sleep(20)
        Cancellation.cancel(signal, "cancelled in backoff")
      end)

      {:error, {:request_failed, :timeout}}
    end
  end

  setup do
    previous_llm = Application.get_env(:tackle_lib, :llm)
    Application.put_env(:tackle_lib, :llm, TestAdapter)
    Process.put(:test_pid, self())

    on_exit(fn ->
      if previous_llm do
        Application.put_env(:tackle_lib, :llm, previous_llm)
      else
        Application.delete_env(:tackle_lib, :llm)
      end
    end)
  end

  test "retries a transient provider failure without duplicating the turn" do
    Application.put_env(:tackle_lib, :llm, RetryThenSuccessAdapter)
    Process.put(:test_pid, self())
    Process.put(:retry_call_count, 0)

    state = State.new(model: "test/model", retry: [base_delay_ms: 0])

    assert {:ok, state} =
             Loop.run(state, "hello",
               event_callback: fn event -> send(self(), {:event, event}) end
             )

    assert state.current_iteration == 1
    assert Enum.map(state.messages, & &1.role) == [:user, :assistant]
    assert List.last(state.messages).content == "retried"
    assert_receive {:retry_messages, [%{role: :user, content: "hello"}]}
    assert_receive {:retry_messages, [%{role: :user, content: "hello"}]}

    assert_receive {:event,
                    %Event{
                      type: :retry_scheduled,
                      data: %{
                        attempt: 1,
                        max_retries: 3,
                        delay_ms: 0,
                        reason: {:request_failed, :timeout}
                      }
                    }}

    assert_receive {:event, %Event{type: :retry_start, data: %{attempt: 1}}}
    assert_receive {:event, %Event{type: :retry_end, data: %{attempt: 1, success?: true}}}
  end

  test "emits one retry end and returns the last error after exhausting retries" do
    Application.put_env(:tackle_lib, :llm, AlwaysTransientAdapter)
    Process.put(:test_pid, self())

    state = State.new(model: "test/model", retry: [max_retries: 2, base_delay_ms: 0])

    assert {:error, state} =
             Loop.run(state, "hello",
               event_callback: fn event -> send(self(), {:event, event}) end
             )

    assert state.current_iteration == 1
    assert Enum.map(state.messages, & &1.role) == [:user]
    assert state.error =~ "503"
    assert_receive :retry_call
    assert_receive :retry_call
    assert_receive :retry_call
    refute_receive :retry_call

    events = collect_events([])

    retry_types =
      events
      |> Enum.filter(&(&1.type in [:retry_scheduled, :retry_start, :retry_end]))
      |> Enum.map(& &1.type)

    assert retry_types == [
             :retry_scheduled,
             :retry_start,
             :retry_scheduled,
             :retry_start,
             :retry_end
           ]

    assert [%Event{data: %{attempt: 2, success?: false}}] =
             Enum.filter(events, &(&1.type == :retry_end))
  end

  test "does not retry a permanent provider failure" do
    Application.put_env(:tackle_lib, :llm, PermanentFailureAdapter)
    Process.put(:test_pid, self())

    assert {:error, _state} = Loop.run(State.new(model: "test/model"), "hello")
    assert_receive :retry_call
    refute_receive :retry_call
  end

  test "cancels cooperatively during provider retry backoff" do
    Application.put_env(:tackle_lib, :llm, CancelDuringRetryAdapter)
    Process.put(:test_pid, self())
    signal = Cancellation.new_signal()

    assert {:cancelled, state} =
             Loop.run(State.new(model: "test/model", retry: [base_delay_ms: 5_000]), "hello",
               cancellation_signal: signal,
               event_callback: fn event -> send(self(), {:event, event}) end
             )

    assert state.status == :cancelled
    assert state.error == "cancelled in backoff"
    assert state.current_iteration == 1
    assert_receive :retry_call
    refute_receive :retry_call
    assert_receive {:event, %Event{type: :retry_scheduled}}
    assert_receive {:event, %Event{type: :retry_end, data: %{success?: false}}}
    assert_receive {:event, %Event{type: :turn_cancelled}}
  end

  test "provider callback gates every automatic retry and can reject dispatch" do
    Application.put_env(:tackle_lib, :llm, AlwaysTransientAdapter)
    Process.put(:test_pid, self())
    Process.put(:gate_count, 0)

    gate = fn ->
      count = Process.get(:gate_count, 0)
      Process.put(:gate_count, count + 1)
      send(self(), {:provider_gate, count + 1})
      :ok
    end

    assert {:error, _state} =
             Loop.run(
               State.new(model: "test/model", retry: [max_retries: 2, base_delay_ms: 0]),
               "hello",
               before_provider_call: gate
             )

    assert_receive {:provider_gate, 1}
    assert_receive {:provider_gate, 2}
    assert_receive {:provider_gate, 3}
    assert Process.get(:gate_count) == 3
    assert_receive :retry_call
    assert_receive :retry_call
    assert_receive :retry_call

    Process.put(:gate_count, 0)

    assert {:error, state} =
             Loop.run(State.new(model: "test/model"), "hello",
               before_provider_call: fn ->
                 send(self(), :provider_rejected)
                 {:error, :storage_paused}
               end
             )

    assert state.error =~ "storage_paused"
    assert_receive :provider_rejected
    refute_receive :retry_call
  end

  test "cancellation while provider gate blocks prevents provider dispatch" do
    Application.put_env(:tackle_lib, :llm, NoCallAdapter)
    Process.put(:test_pid, self())
    signal = Cancellation.new_signal()
    test_pid = self()

    on_exit(fn -> Cancellation.delete(signal) end)

    task =
      Task.async(fn ->
        Process.put(:test_pid, test_pid)

        Loop.run(State.new(model: "test/model"), "hello",
          cancellation_signal: signal,
          before_provider_call: fn ->
            send(test_pid, :provider_gate_entered)
            receive do: (:release_provider_gate -> :ok)
          end
        )
      end)

    assert_receive :provider_gate_entered
    Cancellation.cancel(signal, "cancelled at gate")
    send(task.pid, :release_provider_gate)
    assert {:cancelled, state} = Task.await(task, 2_000)
    assert state.error == "cancelled at gate"
    refute_receive :llm_called
  end

  test "can route provider streaming through Tackle.Lib event deltas" do
    test_pid = self()
    state = State.new(model: "test/model")

    assert {:ok, _state} =
             Loop.run(state, "hello",
               llm_stream: true,
               event_callback: fn event -> send(test_pid, {:event, event}) end
             )

    assert_receive {:event, %Event{type: :message_delta, data: %{delta: "do"}}}
    assert_receive {:event, %Event{type: :message_delta, data: %{delta: "ne"}}}
  end

  defmodule UsageStreamingAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      {:ok,
       %{
         data: %{"content" => "done"},
         usage: %{prompt_tokens: 5, completion_tokens: 4},
         model: "test/model"
       }}
    end

    @impl true
    def stream(schema, opts, event_callback) do
      event_callback.(%{type: :text_delta, text: "done"})
      event_callback.(%{type: :usage, usage: %{prompt_tokens: 5, completion_tokens: 4}})
      generate(schema, opts)
    end
  end

  defmodule GenerateOnlyUsageAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      {:ok,
       %{
         data: %{"content" => "done"},
         usage: %{prompt_tokens: 5, completion_tokens: 4},
         model: "test/model"
       }}
    end
  end

  test "streaming reports each response's usage once" do
    for adapter <- [UsageStreamingAdapter, GenerateOnlyUsageAdapter] do
      Application.put_env(:tackle_lib, :llm, adapter)
      test_pid = self()

      assert {:ok, _state} =
               Loop.run(State.new(model: "test/model"), "hello",
                 llm_stream: true,
                 event_callback: fn event -> send(test_pid, {:event, event}) end
               )

      assert_receive {:event, %Event{type: :turn_end}}

      usages =
        for {:event, %Event{type: :usage, data: %{usage: usage}}} <- drain_messages(),
            do: usage

      assert [%Usage{input_tokens: 5, output_tokens: 4}] = usages, inspect(adapter)
    end
  end

  defp drain_messages(acc \\ []) do
    receive do
      message -> drain_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defmodule EmptyResponseAdapter do
    @behaviour Tackle.Lib.LLM

    # Replies from the script in :empty_script, then with empty responses.
    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :llm_call)

      case Process.get(:empty_script, []) do
        [data | rest] ->
          Process.put(:empty_script, rest)
          {:ok, %{data: data, usage: nil, model: "test/model"}}

        [] ->
          {:ok, %{data: %{"thinking" => "hmm"}, usage: nil, model: "test/model"}}
      end
    end
  end

  describe "empty responses" do
    setup do
      Application.put_env(:tackle_lib, :llm, EmptyResponseAdapter)
      Process.put(:test_pid, self())
      :ok
    end

    test "are asked again once as a retry of the same request" do
      Process.put(:empty_script, [%{"thinking" => "hmm"}, %{"content" => "answer"}])
      test_pid = self()

      assert {:ok, state} =
               Loop.run(State.new(model: "test/model"), "hello",
                 event_callback: fn event -> send(test_pid, {:event, event}) end
               )

      assert Enum.map(state.messages, &{&1.role, &1.content}) ==
               [user: "hello", assistant: "answer"]

      assert_receive {:event, %Event{type: :message_start, id: pending_id}}

      assert_receive {:event,
                      %Event{
                        type: :retry_scheduled,
                        id: ^pending_id,
                        data: %{reason: :empty_response}
                      }}

      assert_receive {:event, %Event{type: :retry_end, data: %{success?: true}}}
      assert List.last(state.messages).id == pending_id
      assert_received :llm_call
      assert_received :llm_call
      refute_received :llm_call
    end

    test "end the turn with an error when the model stays empty" do
      assert {:error, state} = Loop.run(State.new(model: "test/model"), "hello")

      assert state.error == "The model returned an empty response"
      assert state.pending_assistant_id == nil
      assert Enum.map(state.messages, & &1.role) == [:user]
      assert_received :llm_call
      assert_received :llm_call
      refute_received :llm_call
    end

    test "after a tool result are bounded too" do
      Process.put(:empty_script, [
        %{"tool_calls" => [%{"id" => "c1", "name" => "first", "arguments" => %{}}]}
      ])

      state = State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()})

      assert {:error, state} = Loop.run(state, "use the tool")
      assert state.error == "The model returned an empty response"
      assert Enum.map(state.messages, & &1.role) == [:user, :assistant, :tool]
      assert_received {:tool_execute, :first}

      for _call <- 1..3, do: assert_received(:llm_call)
      refute_received :llm_call
    end

    test "a non-empty response gives a later empty response its own re-ask" do
      Process.put(:empty_script, [
        %{},
        %{"tool_calls" => [%{"id" => "c1", "name" => "first", "arguments" => %{}}]},
        %{},
        %{"content" => "answer"}
      ])

      state = State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()})

      assert {:ok, state} = Loop.run(state, "use the tool")
      assert List.last(state.messages).content == "answer"
    end

    test "end the step with one step_end and one after_prompt for the kept response" do
      {{:ok, state}, events} =
        run_scripted([
          ok(%{"thinking" => "hmm"}, %{input_tokens: 1}),
          ok(%{"content" => "answer"}, %{input_tokens: 2})
        ])

      assert Tackle.Lib.last_answer(state) == "answer"

      assert [
               %Event{type: :step_start, data: %{iteration: 1}},
               %Event{type: :usage, data: %{usage: %Usage{input_tokens: 1}}},
               %Event{type: :retry_scheduled, data: %{reason: :empty_response}},
               %Event{type: :retry_start, data: %{attempt: 1}},
               %Event{type: :retry_end, data: %{attempt: 1, success?: true}},
               %Event{type: :usage, data: %{usage: %Usage{input_tokens: 2}}},
               %Event{type: :step_end, data: %{iteration: 1, usage: %Usage{input_tokens: 2}}}
             ] =
               Enum.filter(
                 events,
                 &(&1.type in [
                     :step_start,
                     :usage,
                     :retry_scheduled,
                     :retry_start,
                     :retry_end,
                     :step_end
                   ])
               )

      assert_received {:after_prompt, %Response{content: "answer"}}
      refute_received {:after_prompt, _response}
    end

    test "a second empty response reports :empty_response without a step_end" do
      {{:error, state}, events} = run_scripted([ok(%{"thinking" => "hmm"})])

      assert state.error_reason == :empty_response
      refute Enum.any?(events, &(&1.type == :step_end))
      refute_received {:after_prompt, _response}

      assert %Event{
               data: %{error: "The model returned an empty response", reason: :empty_response}
             } =
               Enum.find(events, &(&1.type == :error))
    end

    test "a transient failure of the re-ask is retried under the retry policy" do
      {{:ok, state}, events} =
        run_scripted(
          [
            ok(%{}),
            {:error, {:http_error, 503, "unavailable"}},
            ok(%{"content" => "answer"})
          ],
          retry: [base_delay_ms: 0]
        )

      assert Tackle.Lib.last_answer(state) == "answer"

      assert [
               {:retry_scheduled, %{attempt: 1, reason: :empty_response}},
               {:retry_start, %{attempt: 1}},
               {:retry_scheduled, %{attempt: 2, reason: {:http_error, 503, "unavailable"}}},
               {:retry_start, %{attempt: 2}},
               {:retry_end, %{attempt: 2, success?: true}}
             ] =
               for(
                 %Event{type: type, data: data} <- events,
                 type in [:retry_scheduled, :retry_start, :retry_end],
                 do: {type, data}
               )
    end
  end

  defp ok(data, usage \\ nil),
    do: {:ok, %{data: data, usage: usage, model: "test/model", provider: "test"}}

  defp run_scripted(script, state_opts \\ [], run_opts \\ []) do
    Application.put_env(:tackle_lib, :llm, ScriptedAdapter)
    Process.put(:script, script)
    test_pid = self()

    state =
      State.new(
        Keyword.merge(
          [model: "test/model", hooks: [AfterPromptHook], context: %{test_pid: test_pid}],
          state_opts
        )
      )

    result =
      Loop.run(
        state,
        "hello",
        Keyword.put(run_opts, :event_callback, &send(test_pid, {:event, &1}))
      )

    {result, collect_events([])}
  end

  defp collect_events(events) do
    receive do
      {:event, %Event{} = event} -> collect_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  describe "responses" do
    test "the after_prompt hooks receive the normalized response" do
      tool_call = %{"id" => "c1", "name" => "first", "arguments" => ~s({"q":"x"})}

      {{:ok, state}, _events} =
        run_scripted(
          [
            ok(%{"thinking" => "plan", "tool_calls" => [tool_call]}, %{input_tokens: 3}),
            ok(%{"content" => "answer"})
          ],
          tools: [FirstTool]
        )

      assert_received {:after_prompt,
                       %Response{
                         content: nil,
                         thinking: "plan",
                         tool_calls: [%Call{id: "c1", name: "first", arguments: %{"q" => "x"}}],
                         usage: %Usage{input_tokens: 3},
                         model: "test/model",
                         provider: "test"
                       }}

      assert_received {:after_prompt, %Response{content: "answer", tool_calls: []}}
      assert Tackle.Lib.last_answer(state) == "answer"
    end

    test "a malformed adapter result ends the turn with an invalid response error" do
      for {result, detail} <- [
            {{:ok, %{}}, {:data, nil}},
            {{:ok, %{data: nil, usage: nil}}, {:data, nil}},
            {{:ok, %{data: "text", usage: nil}}, {:data, "text"}},
            {ok(%{"content" => 42}), {:content, 42}},
            {ok(%{"content" => "hi", "thinking" => [:a]}), {:thinking, [:a]}},
            {ok(%{"tool_calls" => "first"}), {:tool_calls, :not_a_list}},
            {{:ok, %{data: %{"content" => "hi"}, usage: nil, provider_state: "opaque"}},
             {:provider_state, "opaque"}}
          ] do
        {{:error, state}, events} = run_scripted([result])

        assert state.status == :error
        assert state.error_reason == {:invalid_response, detail}
        assert state.error =~ "Invalid provider"
        assert state.pending_assistant_id == nil
        assert Enum.map(state.messages, & &1.role) == [:user]

        assert %Event{data: %{reason: {:invalid_response, ^detail}}} =
                 Enum.find(events, &(&1.type == :error))

        refute Enum.any?(events, &(&1.type == :step_end))
        refute_received {:after_prompt, _response}
        assert_received :llm_call
        refute_received :llm_call
      end
    end

    test "the usage of an invalid response is still reported" do
      {{:error, _state}, events} = run_scripted([ok(%{"content" => 42}, %{input_tokens: 7})])

      assert [%Event{data: %{usage: %Usage{input_tokens: 7}}}] =
               Enum.filter(events, &(&1.type == :usage))
    end
  end

  describe "error reasons" do
    test "a provider failure keeps the provider's reason" do
      {{:error, state}, events} = run_scripted([{:error, {:http_error, 401, "unauthorized"}}])

      assert state.error_reason == {:http_error, 401, "unauthorized"}
      assert state.error == ~s(Failed to get response: {:http_error, 401, "unauthorized"})

      assert %Event{data: %{reason: {:http_error, 401, "unauthorized"}}} =
               Enum.find(events, &(&1.type == :error))
    end

    test "the iteration limit is :max_iterations" do
      tool_call = %{"id" => "c1", "name" => "first", "arguments" => %{}}

      {{:error, state}, _events} =
        run_scripted([ok(%{"tool_calls" => [tool_call]})],
          tools: [FirstTool],
          max_iterations: 1
        )

      assert state.error_reason == :max_iterations
    end

    test "a failing incoming-messages callback keeps the callback's reason" do
      {{:error, state}, _events} =
        run_scripted([ok(%{"content" => "answer"})], [],
          take_incoming_messages: fn -> {:error, :queue_down} end
        )

      assert state.error_reason == :queue_down
      assert state.error == "Could not receive queued messages: :queue_down"
    end

    test "the next turn clears the previous turn's error reason" do
      {{:error, state}, _events} = run_scripted([{:error, {:http_error, 401, "unauthorized"}}])
      assert state.error_reason

      Process.put(:script, [ok(%{"content" => "answer"})])
      assert {:ok, state} = Loop.continue(state)
      assert state.error == nil
      assert state.error_reason == nil
    end

    test "a cancelled turn has no error reason" do
      signal = Cancellation.new_signal()
      Cancellation.cancel(signal, "stop")

      {{:cancelled, state}, _events} =
        run_scripted([ok(%{"content" => "answer"})], [], cancellation_signal: signal)

      assert state.error == "stop"
      assert state.error_reason == nil
    end
  end
end
