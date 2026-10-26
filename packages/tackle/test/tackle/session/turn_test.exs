defmodule Tackle.Session.TurnTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Lib.Tool.Call
  alias Tackle.Runtime.Task, as: TurnTask
  alias Tackle.Session.Turn

  defp state_with(messages),
    do: Enum.reduce(messages, AgentState.new(), &AgentState.add_message(&2, &1))

  defp new_turn(operation \\ :run, input \\ "hello", agent_state \\ AgentState.new()) do
    turn = Turn.new("turn-1", operation, input, agent_state)
    on_exit(fn -> Turn.delete_signal(turn) end)
    turn
  end

  defp interrupted(call_id),
    do: Event.new(:tool_error, %{reason: :interrupted, tool_call_id: call_id})

  test "a new turn starts from the given state with the user's input" do
    earlier = Message.user("earlier", id: "m-1")
    turn = new_turn(:run, "hello", state_with([earlier]))

    assert %Turn{
             id: "turn-1",
             operation: :run,
             status: :starting,
             task: nil,
             user_inputs: ["hello"],
             cancellation_requested?: false
           } = turn

    assert turn.initial_message_ids == MapSet.new(["m-1"])
    assert turn.interrupted_tool_calls == MapSet.new()
    refute Cancellation.cancelled?(turn.signal)
    assert new_turn(:continue, nil).user_inputs == []
  end

  test "cancelling records the request and cancels the signal until the turn settles" do
    turn = new_turn() |> Turn.cancel(:user_cancelled) |> Turn.cancel(:session_closed)

    assert turn.cancellation_requested?
    assert Cancellation.reason(turn.signal) == :user_cancelled

    settling = new_turn() |> Turn.settling()
    assert settling.status == :settling
    cancelled = Turn.cancel(settling, :user_cancelled)
    assert cancelled.cancellation_requested?
    refute Cancellation.cancelled?(settling.signal)
  end

  test "settling deletes the signal with its per-call records" do
    turn = new_turn()
    call_signal = Cancellation.for_call(turn.signal, "call-1")
    assert :ok = Turn.cancel_tool_call(turn, "call-1", "stop")
    assert Cancellation.reason(call_signal) == "stop"
    refute Cancellation.cancelled?(turn.signal)

    settling = Turn.settling(turn)
    refute Cancellation.cancelled?(call_signal)
    assert :ok = Turn.cancel_tool_call(settling, "call-1", "again")
    refute Cancellation.cancelled?(call_signal)
  end

  test "a running turn keeps its task" do
    task = %TurnTask{pid: self(), ref: make_ref(), monitor: make_ref()}
    assert %Turn{status: :running, task: ^task} = Turn.running(new_turn(), task)
  end

  test "records queued user input and recognizes only what the user wrote" do
    turn = Turn.record_user_inputs(new_turn(), ["queued"])

    assert turn.user_inputs == ["hello", "queued"]
    assert Turn.user_authored?(turn, Message.user("queued"))
    refute Turn.user_authored?(turn, Message.user("Message from agent a:\n\nqueued"))
    refute Turn.user_authored?(turn, Message.assistant(content: "hello"))
    refute Turn.user_authored?(nil, Message.user("hello"))
  end

  test "reports the tool calls whose results the turn added, except interrupted ones" do
    earlier = Message.tool_result("old", "old-call", "done", id: "m-old")
    turn = new_turn(:run, "go", state_with([earlier]))

    turn =
      turn
      |> Turn.record_event(interrupted("cut-off"))
      |> Turn.record_event(Event.new(:tool_error, %{reason: :failed, tool_call_id: "failed"}))

    calls = [
      %Call{id: "reported", name: "t", arguments: %{}},
      %Call{id: "cut-off", name: "t", arguments: %{}}
    ]

    agent_state =
      state_with([
        earlier,
        Message.assistant(tool_calls: calls),
        Message.tool_result("reported", "t", "ok"),
        Message.tool_result("cut-off", "t", "interrupted"),
        Message.tool_result("failed", "t", "error")
      ])

    assert turn.interrupted_tool_calls == MapSet.new(["cut-off"])
    assert Turn.reported_tool_calls(turn, agent_state) == MapSet.new(["reported", "failed"])
  end

  test "a snapshot shows only the turn's identity and cancellation request" do
    turn = Turn.cancel(new_turn(), :user_cancelled)

    assert Turn.summary(turn) == %{
             id: "turn-1",
             operation: :run,
             cancellation_requested?: true
           }
  end
end
