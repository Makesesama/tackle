defmodule Tackle.Runtime.CancelToolCallTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.{Cancellation, Event}
  alias Tackle.Runtime.CancellationStore

  defmodule PollingTool do
    @moduledoc false
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "polling"

    @impl true
    def description, do: "Runs until released or its call is cancelled."

    @impl true
    def parameters_schema, do: [name: [type: :string, required: true]]

    @impl true
    def execute(%{"name" => name}, context) do
      send(Map.fetch!(context, :test_pid), {:tool_entered, name, self()})
      await(name, Map.get(context, :cancellation_signal))
    end

    defp await(name, signal) do
      receive do
        {:release, ^name} -> {:ok, %{name: name}}
      after
        10 ->
          case Cancellation.reason(signal) do
            nil -> await(name, signal)
            reason -> {:error, "stopped: #{reason}"}
          end
      end
    end
  end

  test "cancelling one call stops only that call and the turn continues" do
    scope = start_polling_scope()

    assert {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")

    assert_receive {:tool_entered, _name, _task}, 5_000
    assert_receive {:tool_entered, _name, _task}, 5_000

    assert :ok =
             Tackle.Runtime.cancel_tool_call(
               scope.root_agent_ref,
               "ctc-1",
               "watchdog says stalled"
             )

    assert_receive {:tackle_event, ^session_id, ^turn_id,
                    %Event{type: :tool_execution_end, data: %{tool_call_id: "ctc-1"}}},
                   2_000

    refute_receive {:tackle_event, ^session_id, ^turn_id,
                    %Event{type: :tool_execution_end, data: %{tool_call_id: "ctc-2"}}},
                   50

    send_release("two")

    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000

    tool_contents =
      state.messages
      |> Enum.filter(&(&1.role == :tool))
      |> Map.new(&{&1.tool_call_id, &1.content})

    assert tool_contents["ctc-1"] =~ "stopped: watchdog says stalled"
    refute tool_contents["ctc-2"] =~ "stopped"
  end

  test "per-call records are deleted when the turn settles, even for finished calls" do
    scope = start_polling_scope()

    assert {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")

    assert_receive {:tool_entered, _name, _task}, 5_000
    assert_receive {:tool_entered, _name, _task}, 5_000

    send_release("two")

    assert_receive {:tackle_event, ^session_id, ^turn_id,
                    %Event{type: :tool_execution_end, data: %{tool_call_id: "ctc-2"}}},
                   2_000

    # The call has already settled: cancelling it is accepted but has no effect.
    assert :ok = Tackle.Runtime.cancel_tool_call(scope.root_agent_ref, "ctc-2", "late")
    assert [_record] = per_call_records("ctc-2")

    send_release("one")

    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
    assert per_call_records("ctc-1") == []
    assert per_call_records("ctc-2") == []
  end

  test "an idle session reports that no turn is active" do
    scope = start_polling_scope()

    assert {:error, :no_active_turn} =
             Tackle.Runtime.cancel_tool_call(scope.root_agent_ref, "ctc-1", "stop")
  end

  defp per_call_records(call_id),
    do: :ets.match_object(CancellationStore, {{:_, call_id}, :_})

  defp send_release(name), do: send(Process.get(:relay), {:release, name})

  defp start_polling_scope do
    test_pid = self()
    relay = spawn_link(fn -> relay(test_pid, []) end)

    start_scope(
      root: [
        tools: [PollingTool],
        context: %{test_pid: relay},
        mode: :tools_then_answer,
        llm_opts: [
          tool_calls: [
            %{"id" => "ctc-1", "name" => "polling", "arguments" => %{"name" => "one"}},
            %{"id" => "ctc-2", "name" => "polling", "arguments" => %{"name" => "two"}}
          ],
          content: "done"
        ]
      ]
    )
    |> tap(fn _scope -> Process.put(:relay, relay) end)
  end

  # Forwards tool announcements to the test and remembers tool pids so the
  # test can release a tool by name without tracking which arrived first.
  defp relay(test_pid, pids) do
    receive do
      {:tool_entered, name, pid} = message ->
        send(test_pid, message)
        relay(test_pid, [{name, pid} | pids])

      {:release, name} ->
        for {^name, pid} <- pids, do: send(pid, {:release, name})
        relay(test_pid, pids)
    end
  end
end
