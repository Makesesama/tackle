defmodule Tackle.Session.CompactionTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Compaction.Checkpoint
  alias Tackle.Lib.Compaction.Summary
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Usage
  alias Tackle.Session.Projection
  alias Tackle.Session.Reader

  defmodule Summarizer do
    @behaviour Tackle.Lib.Compaction.Summarizer

    @impl true
    def summarize(request, opts) do
      if pid = Application.get_env(:tackle, :compaction_summary_pid) do
        send(pid, {:compaction_request, request, opts})
      end

      case Application.get_env(:tackle, :compaction_summary_result, :default) do
        :default ->
          {:ok, default_summary()}

        :block ->
          receive do
            :release_compaction -> {:ok, default_summary()}
          end

        :until_cancelled ->
          await_cancellation(Keyword.fetch!(opts, :cancellation_signal))

        {:ok, summary} ->
          {:ok, summary}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp await_cancellation(signal) do
      if Cancellation.cancelled?(signal) do
        {:error, :cancelled}
      else
        Process.sleep(5)
        await_cancellation(signal)
      end
    end

    def default_summary do
      %Summary{
        content: "compacted background",
        usage: Usage.normalize(%{"input_tokens" => 5, "output_tokens" => 7}),
        model: "test/echo"
      }
    end
  end

  setup do
    home = tmp_home()
    Application.put_env(:tackle, :compaction_summary_pid, self())
    Application.put_env(:tackle, :compaction_summary_result, :default)

    on_exit(fn ->
      Application.delete_env(:tackle, :compaction_summary_pid)
      Application.delete_env(:tackle, :compaction_summary_result)
    end)

    {:ok, home: home}
  end

  test "manual compaction replaces the model surface while preserving the transcript", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt())
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

    session_id = snapshot.session_id

    assert {:ok, compacted, record} = Tackle.compact(scope.root_agent_ref)
    assert record.trigger == :manual

    assert_receive {:compaction_request, _request, summarizer_opts}, 5_000

    assert {Tackle.Auth.Store, _reference} =
             summarizer_opts[:llm_opts][:credential_store]

    assert [checkpoint, retained] = compacted.agent_state.model_messages
    assert checkpoint == record.summary_message
    assert State.last_compaction(compacted.agent_state) == record
    assert checkpoint.id == record.compaction_id
    assert retained.role == :assistant

    assert Enum.map(compacted.agent_state.messages, & &1.role) == [:user, :assistant]

    assert_receive {:tackle_compaction, ^session_id, %Tackle.Lib.Event{type: :compaction_start}},
                   5_000

    assert_receive {:tackle_compaction, ^session_id, %Tackle.Lib.Event{type: :compaction_end}},
                   5_000

    assert_receive {:tackle_session_compacted, ^session_id, _snapshot, ^record}, 5_000

    assert {:ok, replay} = Reader.read(session_id, home: ctx.home)
    assert Enum.any?(replay.commits, &compacted_commit?/1)

    # The record names the tree entry it attaches to; the journal keeps it.
    assert record.parent_id == retained.id

    assert %{"data" => %{"parent_id" => parent_id}} =
             replay.commits
             |> Enum.flat_map(& &1["events"])
             |> Enum.find(&(&1["type"] == "context.compacted"))

    assert parent_id == record.parent_id
  end

  test "a session without branching compacts and resumes in its journal format", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts(), session: [tree: false])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt())
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, compacted, record} = Tackle.compact(scope.root_agent_ref)
    assert State.last_compaction(compacted.agent_state) == record
    session_id = snapshot.session_id
    stop_scope(scope.scope_ref)

    # The journal records neither message nor compaction parents: each
    # attaches to the entry before it.
    assert {:ok, replay} = Reader.read(session_id, home: ctx.home)
    events = Enum.flat_map(replay.commits, & &1["events"])

    assert [_ | _] =
             appended =
             Enum.filter(events, &(&1["type"] in ["message.appended", "context.compacted"]))

    refute Enum.any?(appended, &Map.has_key?(&1["data"], "parent_id"))

    resumed =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id, tree: false],
        root: root_opts()
      )

    assert {:ok, resumed_snapshot} = Tackle.snapshot(resumed.root_agent_ref)
    agent_state = resumed_snapshot.agent_state
    assert State.last_compaction_id(agent_state) == record.compaction_id
    assert hd(agent_state.model_messages) == record.summary_message
    assert agent_state.messages == Tree.transcript(agent_state.tree)
    assert {:error, :tree_disabled} = Tackle.navigate(resumed.root_agent_ref, nil)
  end

  test "keeps the canonical transcript inspectable and searchable while compacted", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt(marker: "secret-marker"))
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000
    session_id = snapshot.session_id

    assert {:ok, _compacted, _record} = Tackle.compact(scope.root_agent_ref)

    assert {:ok, inspected} = Tackle.inspect_session(session_id, home: ctx.home)
    assert [_, _] = inspected.messages
    assert [_, _] = inspected.model_messages
    assert hd(inspected.messages)["content"] =~ "secret-marker"
    refute hd(inspected.model_messages)["content"] =~ "secret-marker"

    {:ok, projection} = Reader.projection(session_id, home: ctx.home)
    assert Projection.search_text(projection) =~ "secret-marker"
    refute Projection.search_text(projection) =~ "compacted background"

    assert {:ok, %{sessions: sessions}} =
             Tackle.search_sessions("secret-marker", home: ctx.home)

    assert Enum.any?(sessions, &(&1.session_id == session_id))
  end

  test "records auxiliary summarization usage without making it a context checkpoint", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt())
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, _compacted, _record} = Tackle.compact(scope.root_agent_ref)

    {:ok, projection} = Reader.projection(snapshot.session_id, home: ctx.home)

    assert [%{"summary_usage" => %{"input_tokens" => 5, "output_tokens" => 7}}] =
             projection.compactions

    checkpoint = hd(projection.model_messages)
    assert Map.get(checkpoint, "token_usage") == nil
  end

  test "a summary failure writes no compaction event and leaves the surface unchanged", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt())
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

    Application.put_env(:tackle, :compaction_summary_result, {:error, :provider_unavailable})

    assert {:error, :provider_unavailable} = Tackle.compact(scope.root_agent_ref)

    assert {:ok, replay} = Reader.read(snapshot.session_id, home: ctx.home)
    refute Enum.any?(replay.commits, &compacted_commit?/1)

    assert {:ok, current} = Tackle.snapshot(scope.root_agent_ref)

    assert Enum.map(current.agent_state.model_messages, & &1.id) ==
             Enum.map(current.agent_state.messages, & &1.id)

    assert State.last_compaction(current.agent_state) == nil
  end

  test "resumes by replaying the compacted model surface", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt())
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, _compacted, compacted_record} = Tackle.compact(scope.root_agent_ref)
    session_id = snapshot.session_id
    stop_scope(scope.scope_ref)

    resumed =
      start_durable_scope(home: ctx.home, session: [session_id: session_id], root: root_opts())

    assert {:ok, resumed_snapshot} = Tackle.snapshot(resumed.root_agent_ref)
    assert Enum.map(resumed_snapshot.agent_state.messages, & &1.role) == [:user, :assistant]
    assert [checkpoint, retained] = resumed_snapshot.agent_state.model_messages
    assert checkpoint == State.last_compaction(resumed_snapshot.agent_state).summary_message
    assert checkpoint.id == compacted_record.compaction_id
    assert retained.role == :assistant
  end

  test "forks a compacted session and copies the compaction event", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt())
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, _compacted, _record} = Tackle.compact(scope.root_agent_ref)

    assert {:ok, child_id} = Tackle.fork_session(snapshot.session_id, home: ctx.home)
    assert {:ok, child} = Tackle.inspect_session(child_id, home: ctx.home)

    assert [_, _] = child.messages
    assert [_, _] = child.model_messages
    assert hd(child.model_messages)["role"] == "user"
    assert child.compactions != []

    {:ok, replay} = Reader.read(child_id, home: ctx.home)
    assert Enum.any?(replay.commits, &compacted_commit?/1)
  end

  test "automatically compacts under pressure before the next provider call", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)

    {:ok, first} = Tackle.submit(scope.root_agent_ref, huge_prompt())
    assert_receive {:tackle_turn_finished, _sid, ^first, {:ok, _state}}, 5_000

    {:ok, replay} = Reader.read(snapshot.session_id, home: ctx.home)
    refute Enum.any?(replay.commits, &compacted_commit?/1)

    {:ok, second} = Tackle.submit(scope.root_agent_ref, huge_prompt())
    assert_receive {:tackle_turn_finished, _sid, ^second, {:ok, _state}}, 5_000

    {:ok, projection} = Reader.projection(snapshot.session_id, home: ctx.home)
    assert projection.compactions != []

    checkpoint = hd(projection.model_messages)
    assert checkpoint["role"] == "user"
    assert checkpoint["id"] == Tree.last_compaction_id(projection.tree)
    assert String.starts_with?(checkpoint["content"], String.trim(Checkpoint.framing()))
  end

  test "non-durable compaction also leaves Session controls responsive" do
    scope = start_scope(root: root_opts())
    {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt())
    assert_receive {:tackle_turn_finished, _, ^turn_id, _}, 5_000
    flush_compaction_requests()
    Application.put_env(:tackle, :compaction_summary_result, :block)
    compact = Task.async(fn -> Tackle.compact(scope.root_agent_ref) end)
    assert_receive {:compaction_request, _, _}, 5_000
    assert {:ok, _} = Tackle.snapshot(scope.root_agent_ref)
    assert {:error, :storage_busy} = Tackle.submit(scope.root_agent_ref, "rejected")
    {:ok, session} = Tackle.Runtime.session_pid(scope.root_agent_ref)
    send(:sys.get_state(session).storage_task.task.pid, :release_compaction)
    assert {:ok, _snapshot, _record} = Task.await(compact)
  end

  test "cancel stops a running manual compaction and deletes its signal", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt())
    assert_receive {:tackle_turn_finished, _, ^turn_id, _}, 5_000
    flush_compaction_requests()
    before = Tackle.snapshot(scope.root_agent_ref)

    Application.put_env(:tackle, :compaction_summary_result, :until_cancelled)
    compact = Task.async(fn -> Tackle.compact(scope.root_agent_ref) end)
    assert_receive {:compaction_request, _request, opts}, 5_000
    signal = Keyword.fetch!(opts, :cancellation_signal)

    assert :ok = Tackle.cancel(scope.root_agent_ref)
    assert {:error, {:cancelled, :user_cancelled}} = Task.await(compact)

    assert :ets.lookup(Cancellation.Store.Ets, signal.id) == []
    assert Tackle.snapshot(scope.root_agent_ref) == before

    {:ok, replay} = Reader.read(snapshot.session_id, home: ctx.home)
    refute Enum.any?(replay.commits, &compacted_commit?/1)

    # The next compaction gets a fresh signal and succeeds.
    Application.put_env(:tackle, :compaction_summary_result, :default)
    assert {:ok, _compacted, _record} = Tackle.compact(scope.root_agent_ref)
  end

  defp flush_compaction_requests do
    receive do
      {:compaction_request, _, _} -> flush_compaction_requests()
    after
      0 -> :ok
    end
  end

  test "rejects manual compaction while a turn is active", ctx do
    scope = start_durable_scope(home: ctx.home, root: [mode: :manual] ++ root_opts())

    {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello")
    assert_receive {:adapter_called, adapter_pid, _model, _opts}, 5_000

    assert {:error, :turn_in_progress} = Tackle.compact(scope.root_agent_ref)

    send(adapter_pid, {:respond, "answer"})
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000
  end

  defp root_opts do
    [
      compaction: [
        summarizer: Summarizer,
        policy: [
          response_reserve: 10,
          safety_reserve: 0,
          attention_ratio: 0.5,
          retain_tokens: 1,
          summary_max_tokens: 100
        ]
      ],
      content: "ack"
    ]
  end

  defp long_prompt(opts \\ []) do
    prefix = Keyword.get(opts, :marker, "context")
    String.duplicate("#{prefix} ", 80)
  end

  # One prompt stays below the 500-token threshold of the 1,000-token test
  # window; two exceed it. (A single prompt that alone exceeds the threshold
  # is compacted before its first request.)
  defp huge_prompt, do: String.duplicate("payload ", 200)

  defp compacted_commit?(commit) do
    Enum.any?(commit["events"], &(&1["type"] == "context.compacted"))
  end
end
