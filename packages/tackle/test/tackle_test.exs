defmodule TackleTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.RootBackend
  alias Tackle.Runtime.Scope
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Session
  alias Tackle.Session.Snapshot
  alias Tackle.Test.Adapter, as: TestAdapter

  defmodule ControlledAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "controlled"

    @impl true
    def models, do: ["test"]

    @impl true
    def model_info("test") do
      %{
        context_window: 1_000,
        max_output_tokens: 200,
        pricing: %{input: 2, output: 8, cache_read: 0.2, cache_write: 2.5}
      }
    end

    @impl true
    def generate(_schema, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      signal = Keyword.fetch!(opts, :cancellation_signal)
      send(test_pid, {:adapter_called, self(), Keyword.fetch!(opts, :model), signal})

      receive do
        {:respond, content} -> response(content)
        {:error, reason} -> {:error, reason}
        :crash -> TestAdapter.crash_turn_task()
      end
    end

    defp response(content) do
      {:ok,
       %{
         data: %{"content" => content, "tool_calls" => []},
         usage: %{input_tokens: 100, output_tokens: 10, cache_read_tokens: 50},
         model: "test",
         provider: adapter_id()
       }}
    end
  end

  defmodule TurnContextTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "turn_context"

    @impl true
    def description, do: "Reports the turn context it receives."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, context) do
      send(context.test_pid, {:tool_turn_id, context.runtime_turn_id})

      context.event_callback.(
        Event.new(:tool_progress, %{tool_call_id: context.tool_call_id, delta: "probing"})
      )

      {:ok, %{ok: true}}
    end
  end

  defmodule AdapterA do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "provider-a"

    @impl true
    def models, do: ["shared"]

    @impl true
    def generate(_schema, opts), do: response("a", opts)

    defp response(prefix, opts) do
      model = Keyword.fetch!(opts, :model)

      {:ok,
       %{
         data: %{"content" => "#{prefix}:#{model}", "tool_calls" => []},
         usage: nil,
         model: model,
         provider: adapter_id()
       }}
    end
  end

  defmodule CredentialAdapter do
    @behaviour Tackle.Lib.LLM

    alias Tackle.Lib.CredentialStore

    @impl true
    def adapter_id, do: "credential-refresh"

    @impl true
    def models, do: ["test"]

    @impl true
    def generate(_schema, opts) do
      handle = Keyword.fetch!(opts, :credential_store)

      {:ok, %{"access_token" => "initial-integration-token"}} =
        CredentialStore.fetch(handle, adapter_id())

      :ok =
        CredentialStore.put(handle, adapter_id(), %{
          "access_token" => "refreshed-integration-token"
        })

      {:ok,
       %{
         data: %{"content" => "credentials refreshed", "tool_calls" => []},
         usage: nil,
         model: Keyword.fetch!(opts, :model),
         provider: adapter_id()
       }}
    end
  end

  defmodule AdapterB do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "provider-b"

    @impl true
    def models, do: ["shared"]

    @impl true
    def generate(_schema, opts) do
      model = Keyword.fetch!(opts, :model)

      {:ok,
       %{
         data: %{"content" => "b:#{model}", "tool_calls" => []},
         usage: nil,
         model: model,
         provider: adapter_id()
       }}
    end
  end

  describe "public scoped facade" do
    test "starting a scope returns a PID-free handle" do
      scope = start_scope(providers: [AdapterA], model: "provider-a/shared")

      assert %Scope{scope_ref: %ScopeRef{}, root_agent_ref: %AgentRef{}} = scope
      refute inspect(scope) =~ "#PID"
      assert {:ok, _snapshot} = Tackle.scope_snapshot(scope.scope_ref)
    end

    test "stale references return explicit errors instead of exiting callers" do
      scope = start_scope(providers: [AdapterA], model: "provider-a/shared")
      agent_ref = scope.root_agent_ref

      assert :ok = Tackle.stop_scope(scope.scope_ref)

      assert :ok = eventually(fn -> Tackle.monitor_agent(agent_ref) == {:error, :not_found} end)

      assert {:error, :not_found} = Tackle.submit(agent_ref, "hello")
      assert {:error, :not_found} = Tackle.continue(agent_ref)
      assert {:error, :not_found} = Tackle.cancel(agent_ref)
      assert {:error, :not_found} = Tackle.subscribe(agent_ref)
      assert {:error, :not_found} = Tackle.unsubscribe(agent_ref)
      assert {:error, :not_found} = Tackle.snapshot(agent_ref)
      assert {:error, :not_found} = Tackle.monitor_agent(agent_ref)
      assert {:error, :not_found} = Tackle.stop_scope(scope.scope_ref)
    end

    test "rejects an invalid delegation grant explicitly" do
      {:ok, config} = Tackle.Config.new(providers: [AdapterA], model: "provider-a/shared")

      assert {:error, {:invalid_allow_delegation, :yes}} =
               AgentSpec.new(name: "root", config: config, allow_delegation: :yes)
    end
  end

  test "runs a supervised turn and delivers correlated events" do
    scope = start_controlled_scope()
    agent_ref = scope.root_agent_ref

    assert {:ok, %Snapshot{active_turn: nil, session_id: session_id}} =
             Tackle.subscribe(agent_ref)

    assert {:ok, turn_id} = Tackle.submit(agent_ref, "hello")
    assert_receive {:adapter_called, task_pid, "test", signal}
    send(task_pid, {:respond, "hello back"})

    assert {:finished, {:ok, final_state}, events} =
             await_terminal(session_id, turn_id)

    assert Tackle.Lib.last_answer(final_state) == "hello back"
    assert Enum.any?(events, &match?(%Event{type: :turn_start}, &1))
    assert Enum.any?(events, &match?(%Event{type: :turn_end}, &1))

    assert {:ok, %Snapshot{agent_state: ^final_state, active_turn: nil}} =
             Tackle.snapshot(agent_ref)

    usage = State.usage(final_state)
    assert usage.input_tokens == 100
    assert usage.output_tokens == 10
    assert usage.cache_read_tokens == 50

    assert Enum.any?(events, fn
             %Event{
               type: :usage,
               data: %{usage: usage, model_info: model_info, context_usage: context_usage}
             } ->
               usage.cost_estimated and model_info.context_window == 1_000 and
                 context_usage.tokens == 160 and context_usage.percent == 16.0

             _event ->
               false
           end)

    assert Cancellation.reason(signal) == nil
  end

  test "gives tools the harness turn id and the turn's event callback" do
    scope =
      start_scope(
        providers: [Tackle.Test.Adapter],
        model: "test/echo",
        tools: [TurnContextTool],
        context: %{test_pid: self()},
        llm_opts: [
          test_pid: self(),
          mode: :tool_then_answer,
          tool_call: %{"id" => "c1", "name" => "turn_context", "arguments" => %{}},
          content: "done"
        ]
      )

    agent_ref = scope.root_agent_ref
    assert {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(agent_ref)
    assert {:ok, turn_id} = Tackle.submit(agent_ref, "hello")
    assert_receive {:tool_turn_id, ^turn_id}
    assert {:finished, {:ok, _state}, events} = await_terminal(session_id, turn_id)

    assert Enum.any?(
             events,
             &match?(%Event{type: :tool_progress, data: %{tool_call_id: "c1"}}, &1)
           )
  end

  test "queues overlapping turns at the next provider boundary" do
    scope = start_controlled_scope()
    agent_ref = scope.root_agent_ref
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(agent_ref)

    assert {:ok, turn_id} = Tackle.submit(agent_ref, "first")
    assert_receive {:adapter_called, task_pid, "test", _signal}
    assert {:ok, :queued} = Tackle.submit(agent_ref, "second")
    assert {:error, :turn_in_progress} = Tackle.subscribe(agent_ref)

    send(task_pid, {:respond, "done"})
    assert_receive {:adapter_called, second_task, "test", _signal}
    send(second_task, {:respond, "done again"})
    assert {:finished, {:ok, state}, _events} = await_terminal(session_id, turn_id)

    assert Enum.any?(state.messages, &(&1.role == :user and &1.content == "second"))
  end

  test "withdraws only the newest matching queued message before delivery" do
    scope = start_controlled_scope()
    agent_ref = scope.root_agent_ref
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(agent_ref)

    assert {:ok, turn_id} = Tackle.submit(agent_ref, "first")
    assert_receive {:adapter_called, task_pid, "test", _signal}
    assert {:ok, :queued} = Tackle.submit(agent_ref, "second")
    assert {:ok, :queued} = Tackle.submit(agent_ref, "third")
    assert {:ok, :queued} = Tackle.submit(agent_ref, "second")
    assert :ok = Tackle.withdraw_queued(agent_ref, "second")
    assert {:error, :not_queued} = Tackle.withdraw_queued(agent_ref, "missing")
    assert :ok = Tackle.withdraw_queued(agent_ref, "third")

    send(task_pid, {:respond, "done"})
    assert_receive {:adapter_called, second_task, "test", _signal}
    send(second_task, {:respond, "done again"})
    assert {:finished, {:ok, state}, _events} = await_terminal(session_id, turn_id)
    assert Enum.count(state.messages, &(&1.role == :user and &1.content == "second")) == 1
    assert Enum.all?(state.messages, &(&1.content != "third"))
    assert {:error, :not_queued} = Tackle.withdraw_queued(agent_ref, "second")
  end

  test "reconfigures model and thinking while preserving settled history" do
    scope =
      start_scope(
        providers: [AdapterA, AdapterB],
        model: "provider-a/shared",
        llm_opts: [request_tag: "preserved"]
      )

    agent_ref = scope.root_agent_ref
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(agent_ref)

    assert {:ok, first_turn_id} = Tackle.submit(agent_ref, "first")

    assert {:finished, {:ok, first_state}, _events} =
             await_terminal(session_id, first_turn_id)

    assert Tackle.Lib.last_answer(first_state) == "a:shared"

    assert {:ok, %Snapshot{agent_state: agent_state} = snapshot} =
             Tackle.reconfigure(agent_ref, model: "provider-b/shared", thinking: "high")

    assert_receive {:tackle_session_reconfigured, ^session_id, ^snapshot}
    assert agent_state.messages == first_state.messages
    assert agent_state.llm.ref == "provider-b/shared"
    assert State.model(agent_state) == "shared"
    assert agent_state.llm_opts[:request_tag] == "preserved"
    assert agent_state.llm_opts[:reasoning_effort] == "high"
    refute Keyword.has_key?(agent_state.llm_opts, :reasoning_summary)
    assert agent_state.llm_opts[:credential_store] == Tackle.Auth.credential_store()

    assert {:ok, second_turn_id} = Tackle.submit(agent_ref, "second")

    assert {:finished, {:ok, final_state}, _events} =
             await_terminal(session_id, second_turn_id)

    assert Enum.map(final_state.messages, &{&1.role, &1.content}) == [
             {:user, "first"},
             {:assistant, "a:shared"},
             {:user, "second"},
             {:assistant, "b:shared"}
           ]
  end

  test "rejects reconfiguration during an active turn" do
    scope = start_controlled_scope()
    agent_ref = scope.root_agent_ref
    assert {:ok, _turn_id} = Tackle.submit(agent_ref, "first")
    assert_receive {:adapter_called, task_pid, "test", _signal}

    assert {:error, :turn_in_progress} =
             Tackle.reconfigure(agent_ref, thinking: "high")

    send(task_pid, {:respond, "done"})
  end

  test "reconfiguration changes only the model and thinking level" do
    scope = start_controlled_scope()

    assert {:error, {:unknown_reconfigure_options, [:context]}} =
             Tackle.reconfigure(scope.root_agent_ref, context: %{stage: :other})

    assert {:error, {:invalid_config, [1]}} = Tackle.reconfigure(scope.root_agent_ref, [1])
  end

  test "continues a failed turn without duplicating the user message" do
    scope = start_controlled_scope()
    agent_ref = scope.root_agent_ref
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(agent_ref)

    assert {:ok, first_turn_id} = Tackle.submit(agent_ref, "try this")
    assert_receive {:adapter_called, first_task, "test", _first_signal}
    send(first_task, {:error, :temporary})

    assert {:finished, {:error, failed_state}, _events} =
             await_terminal(session_id, first_turn_id)

    assert [%Message{role: :user, content: "try this"}] = failed_state.messages

    assert {:ok, retry_turn_id} = Tackle.continue(agent_ref)
    assert_receive {:adapter_called, retry_task, "test", _retry_signal}
    send(retry_task, {:respond, "recovered"})

    assert {:finished, {:ok, recovered_state}, _events} =
             await_terminal(session_id, retry_turn_id)

    assert Enum.count(recovered_state.messages, &(&1.role == :user)) == 1
    assert Tackle.Lib.last_answer(recovered_state) == "recovered"
  end

  test "owns cooperative cancellation" do
    scope = start_controlled_scope()
    agent_ref = scope.root_agent_ref
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(agent_ref)

    assert {:ok, turn_id} = Tackle.submit(agent_ref, "wait")
    assert_receive {:adapter_called, task_pid, "test", signal}

    assert :ok = Tackle.cancel(agent_ref)

    assert {:ok, %Snapshot{active_turn: %{cancellation_requested?: true}}} =
             Tackle.snapshot(agent_ref)

    send(task_pid, {:respond, "too late"})

    assert {:finished, {:cancelled, cancelled_state}, events} =
             await_terminal(session_id, turn_id)

    assert cancelled_state.status == :cancelled
    assert Enum.any?(events, &match?(%Event{type: :turn_cancelled}, &1))
    assert Cancellation.reason(signal) == nil
    refute_received {:tackle_input_returned, _session_id, _turn_id, _messages}
  end

  test "a cancel hands queued user messages back and starts no turn" do
    scope = start_controlled_scope()
    agent_ref = scope.root_agent_ref
    {:ok, session} = Runtime.session_pid(agent_ref)
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(agent_ref)

    assert {:ok, turn_id} = Tackle.submit(agent_ref, "first")
    assert_receive {:adapter_called, task_pid, "test", _signal}
    assert {:ok, :queued} = Tackle.submit(agent_ref, "second")
    {:ok, note} = Envelope.new(:message, agent_ref, "note")
    assert :ok = Session.deliver(session, note)
    assert {:ok, :queued} = Tackle.submit(agent_ref, "third")

    assert :ok = Tackle.cancel(agent_ref)
    send(task_pid, {:respond, "too late"})

    # The messages come back unsent, before the turn's terminal message.
    assert {:tackle_input_returned, ^session_id, ^turn_id, ["second", "third"]} =
             next_session_message(session_id)

    assert {:tackle_turn_finished, ^session_id, ^turn_id, {:cancelled, cancelled_state}} =
             next_session_message(session_id)

    assert Enum.map(cancelled_state.messages, & &1.content) == ["first"]

    # The agent message stays queued without waking the agent.
    refute_receive {:adapter_called, _task_pid, _model, _signal}, 100
    refute_received {:tackle_turn_started, _session_id, _turn_id, _reason}
    assert Session.inbox(session) == [note]

    # New input wakes it, and its turn takes the queued message too.
    {:ok, later} = Envelope.new(:message, agent_ref, "later")
    assert :ok = Session.deliver(session, later)
    assert_receive {:tackle_turn_started, ^session_id, next_turn, :queued_messages}
    assert_receive {:adapter_called, next_task, "test", _signal}
    send(next_task, {:respond, "done"})

    assert {:finished, {:ok, state}, _events} = await_terminal(session_id, next_turn)

    assert Enum.map(state.messages, & &1.content) == [
             "first",
             "Message from agent #{agent_ref.agent_id}:\n\nnote",
             "Message from agent #{agent_ref.agent_id}:\n\nlater",
             "done"
           ]
  end

  test "reports a task crash separately from an expected turn error" do
    scope = start_controlled_scope()
    agent_ref = scope.root_agent_ref
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(agent_ref)

    assert {:ok, turn_id} = Tackle.submit(agent_ref, "crash")
    assert_receive {:adapter_called, task_pid, "test", _signal}
    send(task_pid, :crash)

    assert {:failed, reason, _events} = await_terminal(session_id, turn_id)
    assert match?({%RuntimeError{message: "adapter crash"}, _stacktrace}, reason)

    assert {:ok, %Snapshot{active_turn: nil, agent_state: agent_state}} =
             Tackle.snapshot(agent_ref)

    assert agent_state.status == :idle
  end

  test "injects only a credential-store handle and never exposes credential values" do
    namespace = CredentialAdapter.adapter_id()
    :ok = Tackle.Auth.put(namespace, %{"access_token" => "initial-integration-token"})
    on_exit(fn -> Tackle.Auth.delete(namespace) end)

    scope = start_scope(providers: [CredentialAdapter], model: "credential-refresh/test")
    agent_ref = scope.root_agent_ref

    initial_snapshot = snapshot!(agent_ref)
    handle = Tackle.Auth.credential_store()
    assert initial_snapshot.agent_state.llm_opts == [credential_store: handle]
    refute inspect(initial_snapshot) =~ "initial-integration-token"

    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(agent_ref)
    {:ok, turn_id} = Tackle.submit(agent_ref, "refresh")

    assert {:finished, {:ok, final_state}, events} = await_terminal(session_id, turn_id)

    assert {:ok, %{"access_token" => "refreshed-integration-token"}} =
             Tackle.Auth.fetch(namespace)

    refute inspect(final_state) =~ "initial-integration-token"
    refute inspect(final_state) =~ "refreshed-integration-token"
    refute inspect(events) =~ "initial-integration-token"
    refute inspect(events) =~ "refreshed-integration-token"
  end

  test "Tackle.Auth.with_lock/2 runs a function under the namespace lock of auth.json" do
    namespace = "with-lock-#{System.unique_integer([:positive])}"
    on_exit(fn -> Tackle.Auth.delete(namespace) end)

    assert {:ok, %{"token" => "locked"}} =
             Tackle.Auth.with_lock(namespace, fn ->
               :ok = Tackle.Auth.put(namespace, %{"token" => "locked"})
               Tackle.Auth.fetch(namespace)
             end)

    assert {:error, {:credential_lock_failed, :invalid_credential_namespace}} =
             Tackle.Auth.with_lock("", fn -> flunk("ran unlocked") end)
  end

  test "different scopes select different adapters without global configuration" do
    scope_a = start_scope(providers: [AdapterA, AdapterB], model: "provider-a/shared")
    scope_b = start_scope(providers: [AdapterA, AdapterB], model: "provider-b/shared")

    assert {:ok, _turn_a} = Tackle.submit(scope_a.root_agent_ref, "hello")
    assert {:ok, _turn_b} = Tackle.submit(scope_b.root_agent_ref, "hello")

    eventually(fn ->
      snapshot!(scope_a.root_agent_ref).agent_state.status == :completed and
        snapshot!(scope_b.root_agent_ref).agent_state.status == :completed
    end)

    assert snapshot!(scope_a.root_agent_ref).agent_state |> Tackle.Lib.last_answer() ==
             "a:shared"

    assert snapshot!(scope_b.root_agent_ref).agent_state |> Tackle.Lib.last_answer() ==
             "b:shared"
  end

  defp start_controlled_scope do
    start_scope(
      providers: [ControlledAdapter],
      model: "controlled/test",
      llm_opts: [test_pid: self()]
    )
  end

  defp start_scope(config_opts) do
    {:ok, config} = Tackle.Config.new(config_opts)
    root_spec = AgentSpec.new!(name: "root", config: config)
    {:ok, scope} = Tackle.start_scope(ScopeSpec.new!(backend: RootBackend, root_spec: root_spec))
    on_exit(fn -> stop_scope(scope.scope_ref) end)
    scope
  end

  defp snapshot!(agent_ref) do
    {:ok, snapshot} = Tackle.snapshot(agent_ref)
    snapshot
  end

  defp stop_scope(scope_ref) do
    Tackle.stop_scope(scope_ref)
  catch
    :exit, _reason -> :ok
  end

  defp await_terminal(session_id, turn_id, events \\ []) do
    receive do
      {:tackle_event, ^session_id, ^turn_id, %Event{} = event} ->
        await_terminal(session_id, turn_id, [event | events])

      {:tackle_turn_finished, ^session_id, ^turn_id, result} ->
        {:finished, result, Enum.reverse(events)}

      {:tackle_turn_failed, ^session_id, ^turn_id, reason} ->
        {:failed, reason, Enum.reverse(events)}
    after
      1_000 -> flunk("timed out waiting for turn #{turn_id}")
    end
  end

  # The next session message other than a turn's library events.
  defp next_session_message(session_id) do
    receive do
      {:tackle_event, ^session_id, _turn_id, %Event{}} -> next_session_message(session_id)
      {tag, ^session_id, _, _} = message when tag != :tackle_event -> message
    after
      1_000 -> flunk("timed out waiting for a session message")
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")
end
