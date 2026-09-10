defmodule Tackle.Session.CompactionTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Compaction
  alias Tackle.Lib.Compaction.Summary
  alias Tackle.Session.Projection
  alias Tackle.Session.Reader

  defmodule Summarizer do
    @behaviour Tackle.Lib.Compaction.Summarizer

    @impl true
    def summarize(request, _opts) do
      if pid = Application.get_env(:tackle, :compaction_summary_pid) do
        send(pid, {:compaction_request, request})
      end

      case Application.get_env(:tackle, :compaction_summary_result, :default) do
        :default -> {:ok, default_summary()}
        {:ok, summary} -> {:ok, summary}
        {:error, reason} -> {:error, reason}
      end
    end

    def default_summary do
      %Summary{
        content: "compacted background",
        usage: Tackle.Lib.Usage.normalize(%{"input_tokens" => 5, "output_tokens" => 7}),
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

    assert [checkpoint, retained] = compacted.agent_state.model_messages
    assert Compaction.checkpoint?(checkpoint)
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
  end

  test "keeps the canonical transcript inspectable and searchable while compacted", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt(marker: "secret-marker"))
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000
    session_id = snapshot.session_id

    assert {:ok, _compacted, _record} = Tackle.compact(scope.root_agent_ref)

    assert {:ok, inspected} = Tackle.inspect_session(session_id, home: ctx.home)
    assert length(inspected.messages) == 2
    assert length(inspected.model_messages) == 2
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

    refute Enum.any?(current.agent_state.model_messages, &Compaction.checkpoint?/1)
  end

  test "resumes by replaying the compacted model surface", ctx do
    scope = start_durable_scope(home: ctx.home, root: root_opts())
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, long_prompt())
    assert_receive {:tackle_turn_finished, _sid, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, _compacted, _record} = Tackle.compact(scope.root_agent_ref)
    session_id = snapshot.session_id
    stop_scope(scope.scope_ref)

    resumed =
      start_durable_scope(home: ctx.home, session: [session_id: session_id], root: root_opts())

    assert {:ok, resumed_snapshot} = Tackle.snapshot(resumed.root_agent_ref)
    assert Enum.map(resumed_snapshot.agent_state.messages, & &1.role) == [:user, :assistant]
    assert [checkpoint, retained] = resumed_snapshot.agent_state.model_messages
    assert Compaction.checkpoint?(checkpoint)
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

    assert length(child.messages) == 2
    assert length(child.model_messages) == 2
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
    assert String.starts_with?(checkpoint["content"], Compaction.marker())
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
          summary_max_tokens: 100,
          max_summary_tokens: 100
        ]
      ],
      content: "ack"
    ]
  end

  defp long_prompt(opts \\ []) do
    prefix = Keyword.get(opts, :marker, "context")
    String.duplicate("#{prefix} ", 80)
  end

  defp huge_prompt, do: String.duplicate("payload ", 500)

  defp compacted_commit?(commit) do
    Enum.any?(commit["events"], &(&1["type"] == "context.compacted"))
  end
end
