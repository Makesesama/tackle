defmodule Tackle.Session.DurabilityTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Message
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Session.Catalog
  alias Tackle.Session.Journal
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage

  setup do
    home = tmp_home()
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

    {:ok, replay} = read_journal(session_id, home: ctx.home)

    assert [:session_created, :turn_started, :user, :assistant, :turn_completed] =
             Enum.map(replay.commits, &commit_kind/1)
  end

  test "an answer-only turn never syncs, and inspect_session still sees it", ctx do
    scope = start_durable_scope(home: ctx.home, root: [content: "hello back"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, journal} = Journal.whereis(snapshot.session_id)
    {:ok, first} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:tackle_turn_finished, _session_id, ^first, {:ok, _state}}, 5_000

    :ok = trace_syncs(journal)
    {:ok, second} = Tackle.submit(scope.root_agent_ref, "second")
    assert_receive {:tackle_turn_finished, _session_id, ^second, {:ok, _state}}, 5_000
    assert collect_syncs(journal) == 0

    # Reading a live session flushes its write-behind tail first.
    assert {:ok, result} = Tackle.inspect_session(snapshot.session_id, home: ctx.home)
    assert result.status == :clean

    assert Enum.map(result.messages, & &1["content"]) == [
             "first",
             "hello back",
             "second",
             "hello back"
           ]
  end

  test "persists a read-only tool's intent and result in order without a tool sync", ctx do
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
    {:ok, journal} = Journal.whereis(snapshot.session_id)
    :ok = trace_syncs(journal)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "read the file")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    # Only session.created syncs. turn.started and turn.completed are
    # write-behind, `read` is read-only (no tool gate sync), and provider calls
    # never sync.
    assert collect_syncs(journal) == 1

    {:ok, replay} = read_journal(snapshot.session_id, home: ctx.home)
    kinds = Enum.map(replay.commits, &commit_kind/1)

    intent_index = Enum.find_index(kinds, &(&1 == :tool_started))
    result_index = Enum.find_index(kinds, &(&1 == :tool_result))

    assert is_integer(intent_index)
    assert is_integer(result_index)
    assert intent_index < result_index
    assert List.last(kinds) == :turn_completed
  end

  test "an external tool batch's intent is on disk before any tool runs, with one sync", ctx do
    tool_calls =
      for name <- ["one", "two", "three"],
          do: %{"id" => "call-#{name}", "name" => "blocking", "arguments" => %{"name" => name}}

    scope =
      start_durable_scope(
        home: ctx.home,
        root: [
          tools: [Tackle.Test.BlockingTool],
          context: %{test_pid: self()},
          mode: :tools_then_answer,
          llm_opts: [tool_calls: tool_calls, content: "done"]
        ]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, journal} = Journal.whereis(snapshot.session_id)
    :ok = trace_syncs(journal)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "use the tools")

    entered =
      for _call <- tool_calls do
        assert_receive {:tool_entered, name, pid}, 5_000
        {name, pid}
      end

    # Read the file through a separate handle while the tools are running.
    {:ok, replay} = Reader.read(snapshot.session_id, home: ctx.home)
    kinds = Enum.map(replay.commits, &commit_kind/1)
    assert Enum.count(kinds, &(&1 == :tool_started)) == 3
    assert :assistant in kinds

    for {name, pid} <- entered, do: send(pid, {:release, name})

    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    # Materialization (session.created) and the tool gate. turn.started and
    # turn.completed are write-behind and provider calls never sync. Originally
    # every one of the 12 commits synced, plus a sync before each provider call.
    assert collect_syncs(journal) == 2

    {:ok, replay} = read_journal(snapshot.session_id, home: ctx.home)

    assert [
             :session_created,
             :turn_started,
             :user,
             :assistant,
             :tool_started,
             :tool_started,
             :tool_started,
             :tool_result,
             :tool_result,
             :tool_result,
             :assistant,
             :turn_completed
           ] = Enum.map(replay.commits, &commit_kind/1)
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

  test "an interrupted turn whose tool results are durable reports no uncertain tools", ctx do
    session_id = ID.generate()

    {:ok, journal} = Journal.start_link(session_id: session_id, home: ctx.home)
    {:ok, turn_id} = Journal.begin_turn(journal, :run, "interrupted", ID.generate())
    assert :ok = Journal.tool_started(journal, %{id: "call-1", name: "bash", arguments: %{}})
    assert :ok = Journal.append_message(journal, Message.tool_result("call-1", "bash", "output"))
    :ok = GenServer.stop(journal)

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [content: "recovered answer"]
      )

    assert {:ok, snapshot} = Tackle.snapshot(scope.root_agent_ref)

    assert snapshot.recovery == %{turn_id: turn_id, operation: "run", uncertain_tools: []}
  end

  test "requires explicit recovery for an interrupted turn", ctx do
    session_id = ID.generate()

    {:ok, journal} = Journal.start_link(session_id: session_id, home: ctx.home)
    {:ok, _turn_id} = Journal.begin_turn(journal, :run, "interrupted", ID.generate())
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

  test "abandoning an interrupted turn settles unresolved tool calls", ctx do
    session_id = ID.generate()

    {:ok, journal} = Journal.start_link(session_id: session_id, home: ctx.home)
    {:ok, _turn_id} = Journal.begin_turn(journal, :run, "interrupted", ID.generate())

    assert :ok = Journal.append_message(journal, Message.user("interrupted"))

    assert :ok =
             Journal.append_message(
               journal,
               Message.assistant(
                 content: nil,
                 tool_calls: [%{id: "call-1", name: "bash", arguments: %{}}]
               )
             )

    assert :ok = Journal.tool_started(journal, %{id: "call-1", name: "bash", arguments: %{}})
    :ok = GenServer.stop(journal)

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [content: "recovered answer"]
      )

    assert {:error, {:recovery_required, info}} = Tackle.submit(scope.root_agent_ref, "next")
    assert info.uncertain_tools != []

    assert :ok = Tackle.abandon_turn(scope.root_agent_ref)

    assert {:ok, snapshot} = Tackle.snapshot(scope.root_agent_ref)

    assert [%Message{role: :tool, tool_call_id: "call-1", tool_name: "bash"} = settled] =
             Enum.filter(snapshot.agent_state.messages, &(&1.role == :tool))

    assert settled.content ==
             "Error: Tool execution was interrupted before a result was recorded; " <>
               "the outcome is unknown."

    {:ok, replay} = read_journal(session_id, home: ctx.home)
    assert Enum.any?(Enum.map(replay.commits, &commit_kind/1), &(&1 == :tool_result))

    assert {:ok, _turn_id} = Tackle.submit(scope.root_agent_ref, "next")
  end

  test "resumes a settled turn with unresolved tool calls by repairing the transcript", ctx do
    session_id = ID.generate()

    {:ok, journal} = Journal.start_link(session_id: session_id, home: ctx.home)
    {:ok, turn_id} = Journal.begin_turn(journal, :run, "run tools", ID.generate())

    assert :ok = Journal.append_message(journal, Message.user("run tools"))

    assert :ok =
             Journal.append_message(
               journal,
               Message.assistant(
                 content: nil,
                 tool_calls: [%{id: "call-1", name: "bash", arguments: %{}}]
               )
             )

    assert :ok = Journal.tool_started(journal, %{id: "call-1", name: "bash", arguments: %{}})

    assert :ok =
             Journal.settle_turn(journal, "turn.cancelled", %{
               "turn_id" => turn_id,
               "reason" => "stopped by user"
             })

    :ok = GenServer.stop(journal)

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [content: "recovered answer"]
      )

    # The turn was already settled, so no recovery decision is required; the
    # unresolved call is repaired with a synthetic result on load.
    assert {:ok, snapshot} = Tackle.snapshot(scope.root_agent_ref)
    assert snapshot.recovery == nil

    assert [%Message{role: :tool, tool_call_id: "call-1", tool_name: "bash"} = settled] =
             Enum.filter(snapshot.agent_state.messages, &(&1.role == :tool))

    assert settled.content ==
             "Error: Tool execution was interrupted before a result was recorded; " <>
               "the outcome is unknown."

    {:ok, replay} = read_journal(session_id, home: ctx.home)
    assert Enum.any?(Enum.map(replay.commits, &commit_kind/1), &(&1 == :tool_result))

    {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "next")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000

    assert Enum.map(state.messages, & &1.role) == [
             :user,
             :assistant,
             :tool,
             :user,
             :assistant
           ]
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

    {:ok, replay} = read_journal(session_id, home: ctx.home)

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

  test "resumes after a model switch without a thinking level and reconfigures from it", ctx do
    scope = start_durable_scope(home: ctx.home, root: [model: "test/echo", content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
    assert {:ok, _snapshot} = Tackle.reconfigure(scope.root_agent_ref, model: "test/child")
    stop_scope(scope.scope_ref)

    resumed =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [model: "test/echo", content: "answer"]
      )

    assert {:ok, resumed_snapshot} = Tackle.snapshot(resumed.root_agent_ref)
    assert resumed_snapshot.agent_state.llm.ref == "test/child"

    # Reconfiguring starts from the restored selection, not the launch config.
    assert {:ok, reconfigured} = Tackle.reconfigure(resumed.root_agent_ref, thinking: "high")
    assert reconfigured.agent_state.llm.ref == "test/child"
    assert reconfigured.agent_state.llm_opts[:reasoning_effort] == "high"

    {:ok, replay} = read_journal(session_id, home: ctx.home)

    assert %{"model_ref" => "test/child", "thinking" => "high"} =
             replay.commits
             |> Enum.flat_map(& &1["events"])
             |> Enum.filter(&(&1["type"] == "session.configuration_changed"))
             |> List.last()
             |> Map.fetch!("data")
  end

  test "restores a thinking level set on the configured model", ctx do
    scope = start_durable_scope(home: ctx.home, root: [model: "test/echo", content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
    assert {:ok, _snapshot} = Tackle.reconfigure(scope.root_agent_ref, thinking: "high")
    stop_scope(scope.scope_ref)

    resumed =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id],
        root: [model: "test/echo", content: "answer"]
      )

    assert {:ok, resumed_snapshot} = Tackle.snapshot(resumed.root_agent_ref)
    assert resumed_snapshot.agent_state.llm.ref == "test/echo"
    assert resumed_snapshot.agent_state.llm_opts[:reasoning_effort] == "high"
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

    assert Journal.whereis(snapshot.session_id) == {:error, :not_found}
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

    {:ok, replay} = read_journal(session_id, home: ctx.home)
    created = Enum.find(replay.commits, &(&1["seq"] == 1))

    assert [%{"type" => "session.created", "data" => %{"model_ref" => "test/child"}}] =
             created["events"]
  end

  test "scope teardown terminates a turn waiting for a journal append", ctx do
    scope = start_durable_scope(home: ctx.home, root: [mode: :manual])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, _turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:adapter_called, turn_pid, _model, _opts}, 5_000
    {:ok, journal} = Journal.whereis(snapshot.session_id)
    :ok = :sys.suspend(journal)

    try do
      send(turn_pid, {:respond, "answer"})

      assert eventually(fn ->
               {:messages, messages} = Process.info(journal, :messages)

               Enum.any?(messages, fn
                 {:"$gen_call", _from,
                  {:append_message, %Message{role: :assistant}, _parent, _sync?}} ->
                   true

                 _other ->
                   false
               end)
             end) == :ok

      ref = Process.monitor(turn_pid)
      stop_scope(scope.scope_ref)
      assert_receive {:DOWN, ^ref, :process, ^turn_pid, _reason}, 5_000
      refute Process.alive?(journal)
      assert Tackle.Runtime.scope_snapshot(scope.scope_ref) == {:error, :scope_not_found}
    after
      if Process.alive?(journal), do: :sys.resume(journal)
    end
  end

  test "a stalled journal automatically terminates the durable scope", ctx do
    session = session_spec(home: ctx.home)
    session = %{session | storage: Keyword.put(session.storage, :journal_timeout, 250)}
    scope = start_scope(session: session, root: [mode: :manual])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, _turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:adapter_called, turn_pid, _model, _opts}, 5_000
    {:ok, journal} = Journal.whereis(snapshot.session_id)
    :ok = :sys.suspend(journal)
    ref = Process.monitor(turn_pid)
    send(turn_pid, {:respond, "answer"})

    assert eventually(fn ->
             Tackle.Runtime.scope_snapshot(scope.scope_ref) == {:error, :scope_not_found}
           end) == :ok

    assert_receive {:DOWN, ^ref, :process, ^turn_pid, _reason}, 1_000
    refute Process.alive?(journal)
    assert Journal.whereis(snapshot.session_id) == {:error, :not_found}
  end

  test "a message the journal refuses fails the turn and the session rebuilds from the journal",
       ctx do
    scope = start_durable_scope(home: ctx.home, root: [mode: :manual])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    {:ok, journal} = Journal.whereis(session_id)

    {:ok, first} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:adapter_called, adapter, _model, _opts}, 5_000
    # A process id cannot be journaled, so the journal refuses the answer.
    send(adapter, {:respond, "refused", %{"pid" => self()}})
    assert_receive {:tackle_turn_finished, ^session_id, ^first, {:error, errored}}, 5_000

    assert {:message_not_journaled, {:invalid_message, {:forbidden_term, :pid}}} =
             errored.error_reason

    # The journal stayed usable, and the session no longer holds the refused answer.
    assert Journal.whereis(session_id) == {:ok, journal}
    {:ok, current} = Tackle.snapshot(scope.root_agent_ref)
    assert Enum.map(current.agent_state.messages, & &1.content) == ["first"]

    {:ok, second} = Tackle.submit(scope.root_agent_ref, "second")
    assert_receive {:adapter_called, adapter, _model, _opts}, 5_000
    send(adapter, {:respond, "answer"})
    assert_receive {:tackle_turn_finished, ^session_id, ^second, {:ok, _state}}, 5_000

    {:ok, current} = Tackle.snapshot(scope.root_agent_ref)
    assert Enum.map(current.agent_state.messages, & &1.content) == ["first", "second", "answer"]

    {:ok, replay} = read_journal(session_id, home: ctx.home)

    assert Enum.map(replay.projection.messages, & &1["content"]) == [
             "first",
             "second",
             "answer"
           ]
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

    assert Journal.whereis(snapshot.session_id) == {:error, :not_found}
  end

  test "journal diagnostics survive the supervised agent shutdown", ctx do
    scope = start_durable_scope(home: ctx.home, root: [mode: :manual])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, monitor} = Tackle.monitor_agent(scope.root_agent_ref)
    {:ok, _turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:adapter_called, _pid, _model, _opts}, 5_000
    {:ok, journal} = Journal.whereis(snapshot.session_id)

    send(journal, {:disk_log, node(), {:tackle_session, snapshot.session_id}, :full})
    # The sibling session's monitor cannot reveal the journal's exit reason.
    assert_receive {:DOWN, ^monitor, :process, _pid, :shutdown}, 1_000

    {:ok, path} = Storage.journal_path(snapshot.session_id, home: ctx.home)
    report = Path.join(Path.dirname(path), "journal-failure.json")
    assert eventually(fn -> File.exists?(report) end) == :ok
    diagnostic = JSON.decode!(File.read!(report))
    assert diagnostic["failure"] == "journal_failure/disk_full"
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
        message_role(event["data"]["message"])

      other ->
        other
    end
  end

  defp message_role(%{"role" => "user"}), do: :user
  defp message_role(%{"role" => "assistant"}), do: :assistant
  defp message_role(%{"role" => "tool"}), do: :tool_result
end
