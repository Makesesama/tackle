defmodule Tackle.Session.LoaderTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
  alias Tackle.Lib.Compaction.Checkpoint
  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree
  alias Tackle.Session.Codec
  alias Tackle.Session.Loader
  alias Tackle.Session.Log
  alias Tackle.Session.Projection

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "loader-test"

    @impl true
    def models, do: ["model", "other"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  test "restores the persisted session id without consuming a generated id" do
    test_pid = self()

    {:ok, config} =
      Config.new(
        providers: [Adapter],
        model: "loader-test/model",
        tools: [],
        id_generator: fn ->
          send(test_pid, :id_generated)
          "generated-id"
        end
      )

    projection =
      Projection.new(
        %{
          "session_id" => "persisted-session",
          "created_at" => "2026-01-01T00:00:00Z",
          "cwd" => nil,
          "parent" => nil
        },
        model_ref: config.model_ref
      )

    assert {:ok, %{state: state}} = Loader.load(projection, config)
    assert state.session_id == "persisted-session"
    refute_receive :id_generated
  end

  test "installs the replayed tree of a branching session as it is" do
    {:ok, config} = Config.new(providers: [Adapter], model: "loader-test/model", tools: [])

    projection =
      Projection.new(
        %{
          "session_id" => "tree-session",
          "created_at" => "2026-01-01T00:00:00Z",
          "cwd" => nil,
          "parent" => nil
        },
        model_ref: config.model_ref,
        tree: true
      )

    projection =
      [{"u1", :user, nil}, {"a1", :assistant, "u1"}, {"u2", :user, nil}]
      |> Enum.with_index(1)
      |> Enum.reduce(projection, fn {{id, role, parent_id}, seq}, projection ->
        message = %Message{id: id, role: role, content: id, timestamp: ~U[2026-01-01 00:00:00Z]}
        {:ok, data} = Codec.encode_message(message)

        Projection.apply_commit(
          projection,
          Log.commit(
            session_id: "tree-session",
            seq: seq,
            commit_id: "commit-#{seq}",
            written_at: "2026-01-01T00:00:00Z",
            events: [
              Log.event("message.appended", %{"message" => data, "parent_id" => parent_id})
            ]
          )
        )
      end)

    assert {:ok, %{state: state}} = Loader.load(projection, config)
    assert state.tree == projection.tree
    assert Enum.map(Tree.children(state.tree, nil), & &1.id) == ["u1", "u2"]
    assert Enum.map(state.messages, & &1.id) == ["u2"]
    assert state.model_messages == Tree.model_context(state.tree)
  end

  test "loads a journal without branching, compactions included, into a tree" do
    {:ok, config} = Config.new(providers: [Adapter], model: "loader-test/model", tools: [])

    projection =
      Projection.new(
        %{
          "session_id" => "linear-session",
          "created_at" => "2026-01-01T00:00:00Z",
          "cwd" => nil,
          "parent" => nil
        },
        model_ref: config.model_ref
      )

    messages =
      for {id, role} <- [{"u1", :user}, {"a1", :assistant}, {"u2", :user}] do
        %Message{id: id, role: role, content: id, timestamp: ~U[2026-01-01 00:00:00Z]}
      end

    record = %Record{
      compaction_id: "c1",
      trigger: :manual,
      summary_message: Checkpoint.message("c1", "summary"),
      shadowed_message_ids: ["u1"],
      first_retained_message_id: "a1",
      tokens_before: 10,
      estimated_tokens_after: 5,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    {:ok, compaction} = Codec.encode_compaction(record)

    # Written the way a journal without branching writes them: no parent ids.
    events =
      Enum.map(Enum.take(messages, 2), &message_event/1) ++
        [Log.event("context.compacted", compaction), message_event(List.last(messages))]

    projection =
      events
      |> Enum.with_index(1)
      |> Enum.reduce(projection, fn {event, seq}, projection ->
        Projection.apply_commit(projection, commit("linear-session", seq, event))
      end)

    refute projection.tree_enabled?
    assert {:ok, %{state: state}} = Loader.load(projection, config)

    assert state.messages == messages
    assert Enum.map(state.model_messages, & &1.id) == ["c1", "a1", "u2"]
    assert State.last_compaction_id(state) == "c1"
    assert Tree.active_id(state.tree) == "u2"
    assert state.tree == projection.tree
  end

  describe "the recorded model and thinking level" do
    test "restore a recorded model whose thinking level was never set" do
      {:ok, config} =
        Config.new(
          providers: [Adapter],
          model: "loader-test/model",
          llm_opts: [reasoning_effort: "high"]
        )

      # `session.configuration_changed` records the adapter option as is.
      projection = selection_projection("loader-test/other", nil)

      assert {:ok, %{state: state, config: resolved, configuration_changed?: false}} =
               Loader.load(projection, config)

      assert resolved.model_ref == "loader-test/other"
      refute Keyword.has_key?(resolved.llm_opts, :reasoning_effort)
      assert state.llm.ref == "loader-test/other"
      refute Keyword.has_key?(state.llm_opts, :reasoning_effort)
    end

    test "restore a recorded thinking level on the configured model" do
      {:ok, config} = Config.new(providers: [Adapter], model: "loader-test/model")
      projection = selection_projection("loader-test/model", "high")

      assert {:ok, %{state: state, config: resolved, configuration_changed?: false}} =
               Loader.load(projection, config)

      assert resolved.llm_opts[:reasoning_effort] == "high"
      assert state.llm_opts[:reasoning_effort] == "high"
    end

    test "clear a configured thinking level the recording does not have" do
      {:ok, config} =
        Config.new(
          providers: [Adapter],
          model: "loader-test/model",
          llm_opts: [reasoning_effort: "high"]
        )

      assert {:ok, %{config: resolved}} =
               Loader.load(selection_projection("loader-test/model", "off"), config)

      refute Keyword.has_key?(resolved.llm_opts, :reasoning_effort)
    end

    test "require configuration for an invalid recorded thinking level" do
      {:ok, config} = Config.new(providers: [Adapter], model: "loader-test/model")

      assert {:error, {:configuration_required, %{thinking: "extreme"}}} =
               Loader.load(selection_projection("loader-test/other", "extreme"), config)
    end

    test "an override records a thinking-only change and keeps the supplied config" do
      {:ok, config} =
        Config.new(
          providers: [Adapter],
          model: "loader-test/model",
          llm_opts: [reasoning_effort: "high"]
        )

      assert {:ok, %{config: ^config, configuration_changed?: true}} =
               Loader.load(selection_projection("loader-test/model", "low"), config,
                 override_config: true
               )

      assert {:ok, %{config: ^config, configuration_changed?: false}} =
               Loader.load(selection_projection("loader-test/model", "high"), config,
                 override_config: true
               )

      {:ok, unset} = Config.new(providers: [Adapter], model: "loader-test/model")

      assert {:ok, %{configuration_changed?: false}} =
               Loader.load(selection_projection("loader-test/model", nil), unset,
                 override_config: true
               )
    end
  end

  defp selection_projection(model_ref, thinking) do
    Projection.new(
      %{
        "session_id" => "selection-session",
        "created_at" => "2026-01-01T00:00:00Z",
        "cwd" => nil,
        "parent" => nil
      },
      model_ref: model_ref,
      thinking: thinking
    )
  end

  defp message_event(message) do
    {:ok, data} = Codec.encode_message(message)
    Log.event("message.appended", %{"message" => data})
  end

  defp commit(session_id, seq, event) do
    Log.commit(
      session_id: session_id,
      seq: seq,
      commit_id: "commit-#{seq}",
      written_at: "2026-01-01T00:00:00Z",
      events: [event]
    )
  end
end
