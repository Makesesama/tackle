defmodule Tackle.Session.PublishEventTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Event
  alias Tackle.Session
  alias Tackle.Session.Reader

  setup do
    {:ok, home: tmp_home()}
  end

  test "broadcasts auxiliary events outside any turn while idle", ctx do
    scope = start_durable_scope(home: ctx.home)
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id

    event = narration("run-1", "reading the tests")
    assert :ok = Tackle.Runtime.publish_event(scope.root_agent_ref, event)
    assert_receive {:tackle_event, ^session_id, nil, ^event}, 1_000
  end

  test "broadcasts mid-turn with a nil turn id and never reaches the journal", ctx do
    scope = start_durable_scope(home: ctx.home, root: [mode: :manual, content: "done"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id

    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")
    assert_receive {:adapter_called, adapter, _model, _opts}, 5_000

    event = narration("run-1", "editing session.ex")
    assert :ok = Tackle.Runtime.publish_event(scope.root_agent_ref, event)
    assert_receive {:tackle_event, ^session_id, nil, ^event}, 1_000

    send(adapter, {:respond, "done"})
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000

    assert Tackle.Lib.last_answer(state) == "done"
    refute inspect(state.messages) =~ "editing session.ex"

    {:ok, replay} = Reader.read(session_id, home: ctx.home)
    refute inspect(replay.commits) =~ "editing session.ex"
    refute inspect(replay.commits) =~ "narration"
    assert replay.commits != []
  end

  test "refuses events that are not auxiliary" do
    scope = start_scope()
    {:ok, session} = Tackle.Runtime.session_pid(scope.root_agent_ref)
    {:ok, _snapshot} = Session.subscribe(session)

    plain = Event.new(:narration, %{run_id: "run-1", text: "reading"})
    assert {:error, {:invalid_event, ^plain}} = Session.publish_event(session, plain)
    assert {:error, {:invalid_event, :nope}} = Session.publish_event(session, :nope)

    assert {:error, {:invalid_event, ^plain}} =
             Tackle.Runtime.publish_event(scope.root_agent_ref, plain)

    refute_receive {:tackle_event, _session_id, _turn_id, _event}, 50
  end

  defp narration(run_id, text),
    do: Event.new(:narration, %{run_id: run_id, tool_call_id: nil, text: text, auxiliary: true})
end
