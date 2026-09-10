defmodule Tackle.Session.DurabilityTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Session.Catalog
  alias Tackle.Session.Journal
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage

  setup do
    home = Tackle.Test.Runtime.tmp_home()
    {:ok, home: home}
  end

  test "persists a completed turn and replays it", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "hello back"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")

    assert_receive {:tackle_turn_finished, session_id, ^turn_id, {:ok, _state}}, 5_000
    assert session_id == snapshot.session_id

    assert {:ok, result} = Tackle.inspect_session(session_id, home: ctx.home)
    assert result.status == :clean
    assert result.uncertain_tools == []

    assert [
             %{"role" => "user", "content" => "hello"},
             %{"role" => "assistant", "content" => "hello back"}
           ] = result.messages

    {:ok, replay} = Reader.read(session_id, home: ctx.home)

    assert [:session_created, :turn_started, :user, :assistant, :turn_completed] =
             Enum.map(replay.commits, &commit_kind/1)
  end

  test "persists tool intent before execution and the result before the next request", ctx do
    path = Path.join(ctx.home, "tool-input.txt")
    File.write!(path, "tool output")

    tool_call = %{
      "id" => "call_1",
      "name" => "read",
      "arguments" => %{"path" => path}
    }

    scope =
      start_durable_scope(
        home: ctx.home,
        root: [
          tools: [Tackle.Tools.Read],
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "done"]
        ]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "read the file")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    {:ok, replay} = Reader.read(snapshot.session_id, home: ctx.home)
    kinds = Enum.map(replay.commits, &commit_kind/1)

    intent_index = Enum.find_index(kinds, &(&1 == :tool_started))
    result_index = Enum.find_index(kinds, &(&1 == :tool_result))

    assert is_integer(intent_index)
    assert is_integer(result_index)
    assert intent_index < result_index
    assert List.last(kinds) == :turn_completed
  end

  test "resumes a session with stable ids and history", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "first answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    session_id = snapshot.session_id
    stop_scope(scope.scope_ref)

    resumed =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [content: "second answer"]
      )

    assert {:ok, resumed_snapshot} = Tackle.snapshot(resumed.root_agent_ref)
    assert resumed_snapshot.session_id == session_id

    assert Enum.map(resumed_snapshot.agent_state.messages, & &1.content) == [
             "first",
             "first answer"
           ]

    {:ok, _snapshot} = Tackle.subscribe(resumed.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(resumed.root_agent_ref, "second")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000

    assert Enum.map(state.messages, & &1.content) == [
             "first",
             "first answer",
             "second",
             "second answer"
           ]
  end

  test "requires explicit recovery for an interrupted turn", ctx do
    session_id = Tackle.Runtime.ID.generate()

    {:ok, journal} = Journal.start_link(session_id: session_id, home: ctx.home)
    {:ok, _turn_id} = Journal.begin_turn(journal, :run, "interrupted")
    :ok = GenServer.stop(journal)

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [content: "recovered answer"]
      )

    assert {:error, {:recovery_required, info}} = Tackle.submit(scope.root_agent_ref, "next")
    assert info.turn_id
    assert info.operation == "run"

    assert :ok = Tackle.abandon_turn(scope.root_agent_ref)
    assert {:ok, _turn_id} = Tackle.submit(scope.root_agent_ref, "next")
  end

  test "records a durable configuration change when the model is overridden on resume", ctx do
    scope =
      start_durable_scope(home: ctx.home, root: [model: "test/echo", content: "answer"])

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    session_id = snapshot.session_id
    stop_scope(scope.scope_ref)

    _resumed =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id, override_config: true],
        root: [model: "test/child", content: "answer"]
      )

    {:ok, replay} = Reader.read(session_id, home: ctx.home)

    assert Enum.any?(replay.commits, fn commit ->
             Enum.any?(commit["events"], fn event ->
               event["type"] == "session.configuration_changed" and
                 event["data"]["model_ref"] == "test/child"
             end)
           end)
  end

  test "adopts the recorded model when resuming without an override", ctx do
    scope =
      start_durable_scope(home: ctx.home, root: [model: "test/child", content: "answer"])

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    session_id = snapshot.session_id
    stop_scope(scope.scope_ref)

    resumed =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [model: "test/echo", content: "answer"]
      )

    assert {:ok, resumed_snapshot} = Tackle.snapshot(resumed.root_agent_ref)
    assert resumed_snapshot.agent_state.llm.ref == "test/child"
  end

  test "returns a configuration-required error for an unresolvable recorded model", ctx do
    session = session_spec(home: ctx.home, model_ref: "missing/model")

    assert {:error, reason} =
             Tackle.start_scope(ScopeSpec.new!(root_spec: agent_spec("root"), session: session))

    assert inspect(reason) =~ "configuration_required"
  end

  test "ephemeral scopes do not create or read a journal", ctx do
    scope = start_scope(root: [content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)

    assert Tackle.Session.Journal.whereis(snapshot.session_id) == {:error, :not_found}
    assert {:error, _reason} = Reader.read(snapshot.session_id, home: ctx.home)
  end

  test "starting and stopping a durable scope without a prompt creates no session", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id

    {:ok, dir} = Storage.session_dir(session_id, home: ctx.home)
    refute File.exists?(dir)
    assert {:error, :not_found} = Catalog.get(session_id)

    stop_scope(scope.scope_ref)

    refute File.exists?(dir)
    assert {:error, _reason} = Tackle.inspect_session(session_id, home: ctx.home)
    assert {:error, :not_found} = Catalog.get(session_id)
  end

  test "records pre-prompt reconfiguration in session.created without creating early", ctx do
    scope = start_durable_scope(home: ctx.home, root: [model: "test/echo", content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id

    {:ok, dir} = Storage.session_dir(session_id, home: ctx.home)

    assert {:ok, _snapshot} = Tackle.reconfigure(scope.root_agent_ref, model: "test/child")
    refute File.exists?(dir)

    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000

    {:ok, replay} = Reader.read(session_id, home: ctx.home)
    created = Enum.find(replay.commits, &(&1["seq"] == 1))

    assert [%{"type" => "session.created", "data" => %{"model_ref" => "test/child"}}] =
             created["events"]
  end

  test "journal owner failure terminates the durable scope", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, journal} = Journal.whereis(snapshot.session_id)

    Process.exit(journal, :kill)

    assert eventually(fn ->
             Tackle.Runtime.scope_snapshot(scope.scope_ref) == {:error, :scope_not_found}
           end) ==
             :ok

    assert Tackle.Session.Journal.whereis(snapshot.session_id) == {:error, :not_found}
  end

  defp commit_kind(%{"events" => [event | _rest]}) do
    case event["type"] do
      "session.created" ->
        :session_created

      "turn.started" ->
        :turn_started

      "turn.completed" ->
        :turn_completed

      "tool.execution_started" ->
        :tool_started

      "message.appended" ->
        case event["data"]["message"] do
          %{"role" => "user"} -> :user
          %{"role" => "assistant"} -> :assistant
          %{"role" => "tool"} -> :tool_result
        end

      other ->
        other
    end
  end
end
