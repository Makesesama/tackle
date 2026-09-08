defmodule TackleTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Session.Snapshot

  defmodule ControlledAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "controlled"

    @impl true
    def models, do: ["test"]

    @impl true
    def generate(_schema, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      signal = Keyword.fetch!(opts, :cancellation_signal)
      send(test_pid, {:adapter_called, self(), Keyword.fetch!(opts, :model), signal})

      receive do
        {:respond, content} -> response(content)
        {:error, reason} -> {:error, reason}
        :crash -> raise "adapter crash"
      end
    end

    defp response(content) do
      {:ok,
       %{
         data: %{"content" => content, "tool_calls" => []},
         usage: nil,
         model: "test",
         provider: adapter_id()
       }}
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

  test "runs a supervised turn and delivers correlated events" do
    session = start_controlled_session()

    assert {:ok, %Snapshot{active_turn: nil, session_id: session_id}} =
             Tackle.subscribe(session)

    assert {:ok, turn_id} = Tackle.submit(session, "hello")
    assert_receive {:adapter_called, task_pid, "test", signal}
    send(task_pid, {:respond, "hello back"})

    assert {:finished, {:ok, final_state}, events} =
             await_terminal(session_id, turn_id)

    assert Tackle.Lib.last_answer(final_state) == "hello back"
    assert Enum.any?(events, &match?(%Event{type: :turn_start}, &1))
    assert Enum.any?(events, &match?(%Event{type: :turn_end}, &1))

    assert %Snapshot{agent_state: ^final_state, active_turn: nil} = Tackle.snapshot(session)
    assert Cancellation.reason(signal) == nil
  end

  test "rejects overlapping turns" do
    session = start_controlled_session()
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(session)

    assert {:ok, turn_id} = Tackle.submit(session, "first")
    assert_receive {:adapter_called, task_pid, "test", _signal}
    assert {:error, :turn_in_progress} = Tackle.submit(session, "second")
    assert {:error, :turn_in_progress} = Tackle.subscribe(session)

    send(task_pid, {:respond, "done"})
    assert {:finished, {:ok, _state}, _events} = await_terminal(session_id, turn_id)
  end

  test "reconfigures model and thinking while preserving settled history" do
    {:ok, session} =
      Tackle.start_session(
        adapters: [AdapterA, AdapterB],
        model: "provider-a/shared",
        llm_opts: [request_tag: "preserved"]
      )

    on_exit(fn -> close_session(session) end)
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(session)

    assert {:ok, first_turn_id} = Tackle.submit(session, "first")

    assert {:finished, {:ok, first_state}, _events} =
             await_terminal(session_id, first_turn_id)

    assert Tackle.Lib.last_answer(first_state) == "a:shared"

    assert {:ok, %Snapshot{agent_state: agent_state} = snapshot} =
             Tackle.reconfigure(session, model: "provider-b/shared", thinking: "high")

    assert_receive {:tackle_session_reconfigured, ^session_id, ^snapshot}
    assert agent_state.messages == first_state.messages
    assert agent_state.llm.ref == "provider-b/shared"
    assert agent_state.model == "shared"
    assert agent_state.llm_opts[:request_tag] == "preserved"
    assert agent_state.llm_opts[:reasoning_effort] == "high"
    assert agent_state.llm_opts[:reasoning_summary] == "auto"
    assert agent_state.llm_opts[:credential_store] == Tackle.Auth.credential_store()

    assert {:ok, second_turn_id} = Tackle.submit(session, "second")

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
    session = start_controlled_session()
    assert {:ok, _turn_id} = Tackle.submit(session, "first")
    assert_receive {:adapter_called, task_pid, "test", _signal}

    assert {:error, :turn_in_progress} =
             Tackle.reconfigure(session, thinking: "high")

    send(task_pid, {:respond, "done"})
  end

  test "continues a failed turn without duplicating the user message" do
    session = start_controlled_session()
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(session)

    assert {:ok, first_turn_id} = Tackle.submit(session, "try this")
    assert_receive {:adapter_called, first_task, "test", _first_signal}
    send(first_task, {:error, :temporary})

    assert {:finished, {:error, failed_state}, _events} =
             await_terminal(session_id, first_turn_id)

    assert [%Message{role: :user, content: "try this"}] = failed_state.messages

    assert {:ok, retry_turn_id} = Tackle.continue(session)
    assert_receive {:adapter_called, retry_task, "test", _retry_signal}
    send(retry_task, {:respond, "recovered"})

    assert {:finished, {:ok, recovered_state}, _events} =
             await_terminal(session_id, retry_turn_id)

    assert Enum.count(recovered_state.messages, &(&1.role == :user)) == 1
    assert Tackle.Lib.last_answer(recovered_state) == "recovered"
  end

  test "owns cooperative cancellation" do
    session = start_controlled_session()
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(session)

    assert {:ok, turn_id} = Tackle.submit(session, "wait")
    assert_receive {:adapter_called, task_pid, "test", signal}

    assert :ok = Tackle.cancel(session)
    assert %Snapshot{active_turn: %{cancellation_requested?: true}} = Tackle.snapshot(session)

    send(task_pid, {:respond, "too late"})

    assert {:finished, {:cancelled, cancelled_state}, events} =
             await_terminal(session_id, turn_id)

    assert cancelled_state.status == :cancelled
    assert Enum.any?(events, &match?(%Event{type: :turn_cancelled}, &1))
    assert Cancellation.reason(signal) == nil
  end

  test "reports a task crash separately from an expected turn error" do
    session = start_controlled_session()
    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(session)

    assert {:ok, turn_id} = Tackle.submit(session, "crash")
    assert_receive {:adapter_called, task_pid, "test", _signal}
    send(task_pid, :crash)

    assert {:failed, reason, _events} = await_terminal(session_id, turn_id)
    assert match?({%RuntimeError{message: "adapter crash"}, _stacktrace}, reason)

    assert %Snapshot{active_turn: nil, agent_state: agent_state} = Tackle.snapshot(session)
    assert agent_state.status == :idle
  end

  test "injects only a credential-store handle and never exposes credential values" do
    namespace = CredentialAdapter.adapter_id()
    :ok = Tackle.Auth.put(namespace, %{"access_token" => "initial-integration-token"})
    on_exit(fn -> Tackle.Auth.delete(namespace) end)

    {:ok, session} =
      Tackle.start_session(adapters: [CredentialAdapter], model: "credential-refresh/test")

    on_exit(fn -> close_session(session) end)

    initial_snapshot = Tackle.snapshot(session)
    handle = Tackle.Auth.credential_store()
    assert initial_snapshot.agent_state.llm_opts == [credential_store: handle]
    refute inspect(initial_snapshot) =~ "initial-integration-token"

    {:ok, %Snapshot{session_id: session_id}} = Tackle.subscribe(session)
    {:ok, turn_id} = Tackle.submit(session, "refresh")

    assert {:finished, {:ok, final_state}, events} = await_terminal(session_id, turn_id)

    assert {:ok, %{"access_token" => "refreshed-integration-token"}} =
             Tackle.Auth.fetch(namespace)

    refute inspect(final_state) =~ "initial-integration-token"
    refute inspect(final_state) =~ "refreshed-integration-token"
    refute inspect(events) =~ "initial-integration-token"
    refute inspect(events) =~ "refreshed-integration-token"
  end

  test "different sessions select different adapters without global configuration" do
    {:ok, session_a} =
      Tackle.start_session(adapters: [AdapterA, AdapterB], model: "provider-a/shared")

    {:ok, session_b} =
      Tackle.start_session(adapters: [AdapterA, AdapterB], model: "provider-b/shared")

    on_exit(fn -> close_session(session_a) end)
    on_exit(fn -> close_session(session_b) end)

    assert {:ok, _turn_a} = Tackle.submit(session_a, "hello")
    assert {:ok, _turn_b} = Tackle.submit(session_b, "hello")

    eventually(fn ->
      Tackle.snapshot(session_a).agent_state.status == :completed and
        Tackle.snapshot(session_b).agent_state.status == :completed
    end)

    assert Tackle.snapshot(session_a).agent_state |> Tackle.Lib.last_answer() == "a:shared"
    assert Tackle.snapshot(session_b).agent_state |> Tackle.Lib.last_answer() == "b:shared"
  end

  defp start_controlled_session do
    {:ok, session} =
      Tackle.start_session(
        adapters: [ControlledAdapter],
        model: "controlled/test",
        llm_opts: [test_pid: self()]
      )

    on_exit(fn -> close_session(session) end)
    session
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

  defp close_session(session) do
    if Process.alive?(session) do
      Tackle.close(session)
    end
  catch
    :exit, _reason -> :ok
  end
end
