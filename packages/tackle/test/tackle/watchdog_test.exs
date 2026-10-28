defmodule Tackle.WatchdogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Tackle.Test.Runtime

  alias Tackle.Config.Watchdog, as: Settings
  alias Tackle.Lib.Decision.{Answer, Result}
  alias Tackle.Lib.Event
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Registry
  alias Tackle.Watchdog
  alias Tackle.Watchdog.Digest

  @judge :tackle_watchdog_test_judge

  defmodule Judge do
    @moduledoc false
    # Decision adapter driven by the test process registered as the judge.
    @behaviour Tackle.Lib.LLM
    @behaviour Tackle.Lib.Decision

    @impl Tackle.Lib.LLM
    def adapter_id, do: "judge"

    @impl Tackle.Lib.LLM
    def models, do: []

    @impl Tackle.Lib.LLM
    def generate(_schema, _opts), do: {:error, :not_a_chat_model}

    @impl Tackle.Lib.Decision
    def decision_models, do: ["fake"]

    @impl Tackle.Lib.Decision
    def decide(request, _opts) do
      send(:tackle_watchdog_test_judge, {:judge_called, self(), request, now()})

      receive do
        {:judge_reply, reply} when is_function(reply, 0) -> reply.()
        {:judge_reply, reply} -> reply
      after
        5_000 -> {:error, :no_reply}
      end
    end

    # Crashes with a FunctionClauseError, whose stacktrace keeps the request.
    def crash(request), do: apply(__MODULE__, :only_nothing, [request])

    def only_nothing(:nothing), do: :ok

    defp now, do: System.monotonic_time(:millisecond)
  end

  defmodule SlowBash do
    @moduledoc false
    # Stands in for `bash`: runs until released and reports its per-call
    # cancellation reason the way the real tool does.
    @behaviour Tackle.Lib.Tool

    alias Tackle.Lib.{Cancellation, Event}

    @impl true
    def name, do: "bash"

    @impl true
    def description, do: "Fake slow command."

    @impl true
    def parameters_schema,
      do: [command: [type: :string, required: true], timeout: [type: :float]]

    @impl true
    def execute(%{"command" => command}, context) do
      send(Map.fetch!(context, :test_pid), {:bash_started, command, self()})
      emit(context, "line 1\n")
      await(Map.get(context, :cancellation_signal), context)
    end

    defp await(signal, context) do
      receive do
        :release ->
          {:ok, "done"}
      after
        10 ->
          case Cancellation.reason(signal) do
            nil -> await(signal, context)
            reason when is_binary(reason) -> {:error, reason}
            reason -> {:error, inspect(reason)}
          end
      end
    end

    defp emit(context, delta) do
      callback = Map.fetch!(context, :event_callback)

      callback.(
        Event.new(:tool_progress, %{
          tool_call_id: Map.get(context, :tool_call_id),
          name: "bash",
          delta: delta
        })
      )
    end
  end

  setup do
    Process.register(self(), @judge)
    :ok
  end

  test "stops a call when a stop verdict reaches the threshold" do
    scope = start_watched_scope()
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")

    assert_receive {:bash_started, "yes", _tool}, 5_000
    assert_receive {:judge_called, judge, request, _at}, 2_000
    assert request.state["command"] == "yes"
    assert request.state["output_tail"] =~ "line 1"
    assert [%{name: "verdict", type: :choice}] = request.questions

    send(judge, {:judge_reply, verdict("infinite_loop", 0.93)})

    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000
    content = tool_content(state, "w1")
    assert content =~ "Command stopped by watchdog after 0s: likely infinite loop (p=0.93)."
    assert content =~ "re-run it with an explicit timeout"
  end

  test "backs off while the command is progressing and never stops it" do
    scope = start_watched_scope()
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")

    assert_receive {:bash_started, "yes", tool}, 5_000

    times =
      for _check <- 1..3 do
        assert_receive {:judge_called, judge, _request, at}, 2_000
        send(judge, {:judge_reply, verdict("progressing", 0.99)})
        at
      end

    [first, second, third] = times
    assert second - first >= 90
    assert third - second >= 180

    send(tool, :release)
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000
    assert tool_content(state, "w1") == "done"
  end

  test "its status shows neither commands nor their output" do
    scope = start_watched_scope(arguments: %{"command" => "echo secret-token"})
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")

    assert_receive {:bash_started, "echo secret-token", tool}, 5_000
    assert_receive {:judge_called, judge, _request, _at}, 2_000

    status =
      scope.root_agent_ref
      |> watchdog_pid()
      |> :sys.get_status()
      |> inspect(limit: :infinity, printable_limit: :infinity)

    refute status =~ "secret-token"
    refute status =~ "line 1"
    assert status =~ "w1"

    send(judge, {:judge_reply, verdict("progressing", 0.99)})
    send(tool, :release)
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
  end

  test "an uncertain stop verdict does not stop the call" do
    scope = start_watched_scope()
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")

    assert_receive {:bash_started, "yes", tool}, 5_000
    assert_receive {:judge_called, judge, _request, _at}, 2_000
    send(judge, {:judge_reply, verdict("stalled", 0.6)})

    # Re-checked at the same interval rather than backed off.
    assert_receive {:judge_called, judge, _request, _at}, 2_000
    send(judge, {:judge_reply, verdict("progressing", 0.9)})

    send(tool, :release)
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000
    assert tool_content(state, "w1") == "done"
  end

  test "skips calls with an explicit timeout" do
    scope = start_watched_scope(arguments: %{"command" => "make", "timeout" => 30})
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")

    assert_receive {:bash_started, "make", tool}, 5_000
    refute_receive {:judge_called, _judge, _request, _at}, 300

    send(tool, :release)
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
  end

  test "a failing decision model stops nothing, warns once, and keeps watching" do
    scope = start_watched_scope()
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id

    log =
      capture_log(fn ->
        {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")
        assert_receive {:bash_started, "yes", tool}, 5_000

        for _check <- 1..2 do
          assert_receive {:judge_called, judge, _request, _at}, 2_000
          send(judge, {:judge_reply, {:error, :unreachable}})
        end

        assert_receive {:judge_called, judge, _request, _at}, 2_000
        send(judge, {:judge_reply, {:ok, %{not: :a_result}}})

        send(tool, :release)
        assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000
        assert tool_content(state, "w1") == "done"
      end)

    # Exactly one warning: splitting on it yields the text before and after.
    assert [_before, _after] = String.split(log, "watchdog decision model judge/fake failed")
  end

  test "junk answers and crashing adapters stop nothing and never crash the watchdog" do
    scope = start_watched_scope()
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    watchdog = watchdog_pid(scope.root_agent_ref)

    # Each failure backs off, doubling the delay, so the list stays short;
    # `Tackle.Lib.DecisionTest` covers the other kinds of junk.
    junk = [
      {:ok, %Result{answers: nil}},
      # A string probability passes a term-order threshold check.
      verdict("stalled", "0.99"),
      fn -> raise "judge exploded" end,
      fn -> exit(:judge_exited) end
    ]

    log =
      capture_log(fn ->
        {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")
        assert_receive {:bash_started, "yes", tool}, 5_000

        for reply <- junk do
          assert_receive {:judge_called, judge, _request, _at}, 5_000
          send(judge, {:judge_reply, reply})
        end

        assert watchdog_pid(scope.root_agent_ref) == watchdog
        send(tool, :release)
        assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000
        assert tool_content(state, "w1") == "done"
      end)

    assert watchdog_pid(scope.root_agent_ref) == watchdog
    assert log =~ "invalid_response error"
    refute log =~ "watchdog stopped"
  end

  test "logs neither commands nor their output, also when the adapter crashes" do
    command = "curl -H 'Authorization: Bearer s3cr3t-token' https://example.test"
    scope = start_watched_scope(arguments: %{"command" => command})
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id

    log =
      capture_log(fn ->
        {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")
        assert_receive {:bash_started, ^command, _tool}, 5_000

        assert_receive {:judge_called, judge, request, _at}, 2_000
        assert request.state["command"] == command
        send(judge, {:judge_reply, fn -> Judge.crash(request) end})

        assert_receive {:judge_called, judge, _request, _at}, 2_000
        send(judge, {:judge_reply, verdict("infinite_loop", 0.93)})
        assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
      end)

    assert log =~ "watchdog decision model judge/fake failed"
    assert log =~ "FunctionClauseError"
    assert log =~ "watchdog stopped tool call w1"
    refute log =~ "s3cr3t"
    refute log =~ "line 1"
  end

  test "reaps a decision that outlives its timeout and keeps watching" do
    scope = start_scope()
    {:ok, settings} = Settings.new([model: "judge/fake", after_seconds: 0.05], [Judge])
    task_supervisor = start_supervised!(Task.Supervisor)

    watchdog =
      start_supervised!(
        {Watchdog,
         agent_ref: scope.root_agent_ref,
         task_supervisor: task_supervisor,
         settings: settings,
         request_timeout: 50}
      )

    log =
      capture_log(fn ->
        start =
          Event.new(:tool_start, %{
            tool_call_id: "w1",
            name: "bash",
            arguments: %{"command" => "yes"}
          })

        send(watchdog, {:tackle_event, "session", "turn", start})

        # The judge never answers; the watchdog kills it once the timeout and
        # its grace have passed, then asks again after backing off.
        assert_receive {:judge_called, stuck, _request, asked_at}, 2_000
        assert_receive {:judge_called, judge, _request, again_at}, 2_000
        refute Process.alive?(stuck)
        assert again_at - asked_at >= 100

        send(judge, {:judge_reply, verdict("progressing", 0.99)})
        assert eventually(fn -> :sys.get_state(watchdog).inflight == nil end) == :ok
      end)

    assert log =~ "watchdog decision model judge/fake failed: :timeout"
    assert Map.keys(:sys.get_state(watchdog).calls) == ["w1"]
  end

  test "retries its subscription after a restart in the middle of a turn" do
    scope = start_watched_scope(arguments: %{"command" => "make", "timeout" => 30})
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    watchdog = watchdog_pid(scope.root_agent_ref)
    assert subscribed?(scope.root_agent_ref, watchdog)

    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")
    assert_receive {:bash_started, "make", tool}, 5_000

    Process.exit(watchdog, :kill)

    restarted =
      wait_for(fn ->
        case watchdog_pid(scope.root_agent_ref) do
          pid when is_pid(pid) and pid != watchdog -> pid
          _other -> nil
        end
      end)

    refute subscribed?(scope.root_agent_ref, restarted)

    send(tool, :release)
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000

    assert wait_for(fn -> subscribed?(scope.root_agent_ref, restarted) end, 3_000)
    assert {:ok, _session} = Tackle.Runtime.session_pid(scope.root_agent_ref)
  end

  test "agents without a watchdog config run no services" do
    scope = start_scope()
    assert Registry.service_task_supervisor(scope.root_agent_ref) == {:error, :not_found}
    refute Watchdog.running?(scope.root_agent_ref)
  end

  test "running?/1 follows the watchdog process" do
    scope = start_watched_scope()
    assert Watchdog.running?(scope.root_agent_ref)

    Tackle.Runtime.stop_scope(scope.scope_ref)
    refute Watchdog.running?(scope.root_agent_ref)
  end

  test "watches?/2 selects bash calls without an explicit timeout" do
    assert Watchdog.watches?("bash", %{"command" => "make"})
    assert Watchdog.watches?("bash", %{command: "make"})
    assert Watchdog.watches?("bash", %{"command" => "make", "timeout" => nil})
    refute Watchdog.watches?("bash", %{"command" => "make", "timeout" => 30})
    refute Watchdog.watches?("bash", %{})
    refute Watchdog.watches?("bash", "{\"command\": \"make\"}")
    refute Watchdog.watches?("read", %{"command" => "make"})
  end

  test "stopped?/1 recognizes the stop message as the last line of an error" do
    digest = Digest.new("yes", 0)
    message = Watchdog.stop_message(digest, "infinite_loop", 0.93, 61_000)

    assert message =~ "after 1m01s: likely infinite loop (p=0.93)"
    assert Watchdog.stopped?("Error: y\ny\n" <> message <> "\n")
    refute Watchdog.stopped?(message <> "\nmore output")
    refute Watchdog.stopped?("Error: Command aborted")
    refute Watchdog.stopped?(nil)
  end

  test "delegated children get their own watchdog" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{
          "child" =>
            agent_spec("child",
              providers: [Tackle.Test.Adapter, Judge],
              tools: [SlowBash],
              context: %{test_pid: self()},
              mode: :tools_then_answer,
              llm_opts: [
                tool_calls: [
                  %{"id" => "c1", "name" => "bash", "arguments" => %{"command" => "yes"}}
                ]
              ],
              content: "child done",
              watchdog: [model: "judge/fake", after_seconds: 0.05, threshold: 0.85]
            )
        }
      )

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "child", "work")

    assert wait_for(fn ->
             match?({:ok, _pid}, Registry.service_task_supervisor(run_ref.agent_ref))
           end)

    assert is_pid(watchdog_pid(run_ref.agent_ref))
    assert Registry.service_task_supervisor(scope.root_agent_ref) == {:error, :not_found}

    # The child's watchdog stops the child's own stuck command.
    assert_receive {:bash_started, "yes", _tool}, 5_000
    assert_receive {:judge_called, judge, request, _at}, 2_000
    assert request.state["command"] == "yes"
    send(judge, {:judge_reply, verdict("stalled", 0.95)})

    assert %Outcome{status: :ok, agent_state: state} = Tackle.Runtime.await(run_ref, 5_000)
    assert tool_content(state, "c1") =~ "Command stopped by watchdog after"
    assert tool_content(state, "c1") =~ "likely stalled (p=0.95)"
  end

  defp start_watched_scope(opts \\ []) do
    arguments = Keyword.get(opts, :arguments, %{"command" => "yes"})

    start_scope(
      root: [
        providers: [Tackle.Test.Adapter, Judge],
        tools: [SlowBash],
        context: %{test_pid: self()},
        mode: :tools_then_answer,
        llm_opts: [
          tool_calls: [%{"id" => "w1", "name" => "bash", "arguments" => arguments}],
          content: "finished"
        ],
        watchdog: [model: "judge/fake", after_seconds: 0.05, threshold: 0.85]
      ]
    )
  end

  # A session monitors its subscribers.
  defp subscribed?(agent_ref, pid) do
    {:ok, session} = Tackle.Runtime.session_pid(agent_ref)
    {:monitored_by, monitors} = Process.info(pid, :monitored_by)
    session in monitors
  end

  defp verdict(choice, probability) do
    {:ok,
     %Result{
       model: "fake",
       answers: verdict_answers(choice, probability),
       usage: %{input_tokens: 10, output_tokens: 1}
     }}
  end

  defp verdict_answers(choice, probability),
    do: %{
      "verdict" => %Answer{
        type: :choice,
        choice: choice,
        probabilities: %{choice => probability}
      }
    }

  defp tool_content(state, call_id) do
    state.messages
    |> Enum.find(&(&1.role == :tool and &1.tool_call_id == call_id))
    |> Map.fetch!(:content)
  end

  defp watchdog_pid(agent_ref) do
    case Registry.service(agent_ref, Watchdog) do
      {:ok, pid} -> pid
      {:error, :not_found} -> nil
    end
  end

  defp wait_for(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _falsy ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_for(fun, deadline)
        else
          nil
        end
    end
  end
end
