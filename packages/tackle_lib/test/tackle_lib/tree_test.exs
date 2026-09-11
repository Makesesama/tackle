defmodule Tackle.Lib.TreeTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Tree.Change
  alias Tackle.Lib.Tree.Navigator
  alias Tackle.Lib.Usage

  defp msg(id, role, content, opts \\ []) do
    %Message{
      id: id,
      role: role,
      content: content,
      timestamp: ~U[2026-01-01 00:00:00Z],
      tool_calls: Keyword.get(opts, :tool_calls),
      tool_call_id: Keyword.get(opts, :tool_call_id),
      token_usage: Keyword.get(opts, :token_usage)
    }
  end

  defp compaction(id, summary, shadowed, first_retained) do
    %Record{
      compaction_id: id,
      trigger: :manual,
      summary_message: msg(id, :user, summary),
      shadowed_message_ids: shadowed,
      first_retained_message_id: first_retained,
      tokens_before: 100,
      estimated_tokens_after: 10,
      created_at: "2026-01-01T00:00:00Z"
    }
  end

  defp append!(tree, message, opts \\ []) do
    {:ok, tree, entry} = Tree.append_message(tree, message, opts)
    {tree, entry}
  end

  describe "append and traversal" do
    test "appends to the active position and derives the transcript" do
      tree = Tree.new()
      {tree, u1} = append!(tree, msg("u1", :user, "hello"))
      {tree, a1} = append!(tree, msg("a1", :assistant, "hi"))

      assert u1.parent_id == nil
      assert a1.parent_id == "u1"
      assert Tree.active_id(tree) == "a1"
      assert Enum.map(Tree.transcript(tree), & &1.id) == ["u1", "a1"]
      assert Enum.map(Tree.enumerate(tree), & &1.id) == ["u1", "a1"]
    end

    test "creating a sibling preserves both branches" do
      {tree, _u1} = append!(Tree.new(), msg("u1", :user, "investigate"))
      {tree, _a1} = append!(tree, msg("a1", :assistant, "two approaches"))

      {:ok, tree} = Tree.move(tree, nil)
      {tree, _u2} = append!(tree, msg("u2", :user, "try B"))
      {tree, _a2} = append!(tree, msg("a2", :assistant, "result B"))

      assert Enum.map(Tree.transcript(tree), & &1.id) == ["u2", "a2"]
      assert Enum.map(Tree.children(tree, nil), & &1.id) == ["u1", "u2"]
      assert Tree.size(tree) == 4

      {:ok, tree} = Tree.move(tree, "a1")
      assert Enum.map(Tree.transcript(tree), & &1.id) == ["u1", "a1"]
    end

    test "rejects duplicate ids and unknown parents" do
      {tree, _u1} = append!(Tree.new(), msg("u1", :user, "hello"))

      assert {:error, {:duplicate_entry, "u1"}} =
               Tree.append_message(tree, msg("u1", :user, "again"))

      assert {:error, {:unknown_parent, "nope"}} =
               Tree.append_message(tree, msg("u2", :user, "x"), parent_id: "nope")
    end

    test "rejects invalid entry ids" do
      assert {:error, {:invalid_entry_id, nil}} =
               Tree.append_message(Tree.new(), msg(nil, :user, "x"))
    end
  end

  describe "restore/2" do
    test "rebuilds a validated tree with an active position" do
      descriptors = [
        %{id: "u1", parent_id: nil, kind: :message, message: msg("u1", :user, "a")},
        %{id: "a1", parent_id: "u1", kind: :message, message: msg("a1", :assistant, "b")},
        %{id: "u2", parent_id: nil, kind: :message, message: msg("u2", :user, "c")}
      ]

      assert {:ok, tree} = Tree.restore(descriptors, active_id: "u2")
      assert Tree.active_id(tree) == "u2"
      assert Enum.map(Tree.transcript(tree), & &1.id) == ["u2"]
    end

    test "rejects duplicates, unknown parents, and unknown active positions" do
      duplicate = [
        %{id: "u1", parent_id: nil, kind: :message, message: msg("u1", :user, "a")},
        %{id: "u1", parent_id: nil, kind: :message, message: msg("u1", :user, "b")}
      ]

      assert {:error, {:duplicate_entry, "u1"}} = Tree.restore(duplicate)

      orphan = [
        %{id: "a1", parent_id: "missing", kind: :message, message: msg("a1", :assistant, "b")}
      ]

      assert {:error, {:unknown_parent, "missing"}} = Tree.restore(orphan)

      valid = [%{id: "u1", parent_id: nil, kind: :message, message: msg("u1", :user, "a")}]
      assert {:error, {:unknown_active_entry, "gone"}} = Tree.restore(valid, active_id: "gone")
    end
  end

  describe "compaction-aware model context" do
    test "applies a compaction only on its own branch" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "old"))
      {tree, _} = append!(tree, msg("a1", :assistant, "reply"))

      {:ok, tree, _} = Tree.append_compaction(tree, compaction("c1", "summary", ["u1"], "a1"))
      {tree, _} = append!(tree, msg("u2", :user, "next"))
      {tree, _} = append!(tree, msg("a2", :assistant, "answer"))

      assert Enum.map(Tree.model_context(tree), & &1.id) == ["c1", "a1", "u2", "a2"]
      assert Enum.map(Tree.transcript(tree), & &1.id) == ["u1", "a1", "u2", "a2"]

      # A new sibling of c1 never inherits the compaction.
      {:ok, tree} = Tree.move(tree, "a1")
      {tree, _} = append!(tree, msg("u3", :user, "try elsewhere"))

      assert Enum.map(Tree.model_context(tree), & &1.id) == ["u1", "a1", "u3"]
      assert Tree.last_compaction_id(tree) == nil
    end

    test "navigating after a compaction restores the same summary without re-summarizing" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "old"))
      {tree, _} = append!(tree, msg("a1", :assistant, "reply"))
      {:ok, tree, _} = Tree.append_compaction(tree, compaction("c1", "summary", ["u1"], "a1"))
      {tree, _} = append!(tree, msg("u2", :user, "more"))

      compacted = Enum.map(Tree.model_context(tree), & &1.id)
      {:ok, tree} = Tree.move(tree, nil)
      {:ok, tree} = Tree.move(tree, "u2")

      assert Enum.map(Tree.model_context(tree), & &1.id) == compacted
      assert Tree.last_compaction_id(tree) == "c1"
    end
  end

  describe "resumable?/2" do
    test "is false for an assistant tool call without a result" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "run it"))

      {tree, _} =
        append!(
          tree,
          msg("a1", :assistant, nil, tool_calls: [%{id: "call_1", name: "tool", arguments: %{}}])
        )

      refute Tree.resumable?(tree, "a1")
      assert Tree.resumable?(tree, "u1")

      {tree, _} = append!(tree, msg("t1", :tool, "ok", tool_call_id: "call_1"))
      assert Tree.resumable?(tree, "t1")
    end

    test "the root position is always resumable" do
      assert Tree.resumable?(Tree.new(), nil)
    end
  end

  describe "usage" do
    test "archive usage counts shared messages once while branch usage follows the path" do
      usage = %Usage{total_tokens: 10}

      {tree, _} = append!(Tree.new(), msg("u1", :user, "hi"))
      {tree, _} = append!(tree, msg("a1", :assistant, "yo", token_usage: usage))
      {:ok, tree} = Tree.move(tree, nil)
      {tree, _} = append!(tree, msg("u2", :user, "hi again"))
      {tree, _} = append!(tree, msg("a2", :assistant, "yes", token_usage: usage))

      assert Tree.usage(tree).total_tokens == 20
      assert Tree.branch_usage(tree).total_tokens == 10
    end
  end

  describe "Navigator" do
    test "edit target moves to the parent and exposes a draft" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "first"))
      {tree, _} = append!(tree, msg("a1", :assistant, "answer"))

      assert {:ok, outcome} = Navigator.navigate(tree, {:edit, "u1"})
      assert outcome.destination_id == nil
      assert outcome.selected_id == "u1"
      assert outcome.draft.content == "first"
      assert outcome.tree.active_id == nil
      assert %Change{from_id: "a1", to_id: nil, mode: :edit} = outcome.change
    end

    test "rejects unknown entries, unsafe destinations, and stale revisions" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "run"))

      {tree, _} =
        append!(
          tree,
          msg("a1", :assistant, nil, tool_calls: [%{id: "call_1", name: "tool", arguments: %{}}])
        )

      assert {:error, {:unknown_entry, "nope"}} = Navigator.navigate(tree, "nope")
      assert {:error, {:unsafe_continuation, "a1"}} = Navigator.navigate(tree, "a1")

      assert {:error, {:stale_transition, 0, revision}} =
               Navigator.navigate(tree, "u1", expected_revision: 0)

      assert is_integer(revision)
    end

    test "selecting the current position is a no-op" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "run"))

      assert {:ok, outcome} = Navigator.navigate(tree, "u1")
      assert outcome.noop?
      assert outcome.change == nil
      assert outcome.tree == tree
    end
  end

  describe "state integration" do
    test "tree mode derives transcript, model context, and readers" do
      state = State.new(tree: true, id_generator: id_generator())

      state = State.add_message(state, msg("u1", :user, "hello"))

      state =
        State.add_message(
          state,
          msg("a1", :assistant, "hi", token_usage: %Usage{total_tokens: 5})
        )

      assert Enum.map(state.messages, & &1.id) == ["u1", "a1"]
      assert Enum.map(State.model_messages(state), & &1.id) == ["u1", "a1"]
      refute is_nil(state.tree)
    end

    test "navigate commits before installing and keeps state on commit failure" do
      state =
        State.new(
          tree: true,
          id_generator: id_generator(),
          tree_committer: __MODULE__.OkCommitter
        )

      state = State.add_message(state, msg("u1", :user, "hello"))
      state = State.add_message(state, msg("a1", :assistant, "hi"))

      assert {:ok, state, outcome} = Tackle.Lib.navigate(state, {:edit, "u1"})
      assert outcome.draft.content == "hello"
      assert state.tree.active_id == nil
      assert state.messages == []

      failing = %{
        State.new(tree: true, id_generator: id_generator())
        | tree_committer: __MODULE__.FailCommitter
      }

      failing = State.add_message(failing, msg("u1", :user, "hello"))

      assert {:error, {:durable_commit_failed, :nope}} = Tackle.Lib.navigate(failing, nil)
      assert failing.tree.active_id == "u1"
      assert failing.messages != []
    end

    test "navigation is rejected when tree mode is disabled" do
      state = State.new()
      assert {:error, :tree_disabled} = Tackle.Lib.navigate(state, nil)
    end

    test "navigation rejects a visibly active state" do
      state = State.new(tree: true, id_generator: id_generator())
      state = State.add_message(state, msg("u1", :user, "hello"))
      state = %{state | status: :thinking}

      assert {:error, :turn_in_progress} = Tackle.Lib.navigate(state, nil)
    end
  end

  defmodule OkCommitter do
    @behaviour Tackle.Lib.Tree.Committer

    @impl true
    def commit_navigation(%Change{}, _context), do: :ok
  end

  defmodule FailCommitter do
    @behaviour Tackle.Lib.Tree.Committer

    @impl true
    def commit_navigation(%Change{}, _context), do: {:error, :nope}
  end

  defmodule TreeSummarizer do
    @behaviour Tackle.Lib.Compaction.Summarizer

    @impl true
    def summarize(_request, _opts) do
      {:ok,
       %Tackle.Lib.Compaction.Summary{content: "branch summary", usage: nil, model: "test/m"}}
    end
  end

  defmodule TreeAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "test"

    @impl true
    def models, do: ["tree-model"]

    @impl true
    def model_info(_model), do: %{context_window: 100_000, max_output_tokens: 1_000}

    @impl true
    def generate(_schema, _opts) do
      {:ok, %{data: %{"content" => "ok", "tool_calls" => []}, usage: nil, model: "tree-model"}}
    end
  end

  describe "compaction integration" do
    test "appends a compaction entry and keeps the branch transcript" do
      config =
        Tackle.Lib.Compaction.Config.new!(
          summarizer: TreeSummarizer,
          policy: [retain_tokens: 10, summary_max_tokens: 1_000, max_summary_tokens: 1_000]
        )

      selection = %Tackle.Lib.LLM.Selection{
        adapter: TreeAdapter,
        adapter_id: "test",
        model: "tree-model",
        ref: "test/tree-model",
        model_info: %Tackle.Lib.ModelInfo{model: "tree-model", context_window: 100_000}
      }

      state = State.new(tree: true, llm: selection, compaction: config)
      state = State.add_message(state, msg("u1", :user, String.duplicate("x", 4000)))
      state = State.add_message(state, msg("a1", :assistant, String.duplicate("y", 4000)))

      assert {:ok, compacted, %Record{compaction_id: id}} = Tackle.Lib.compact(state)
      assert id == compacted.tree.active_id
      assert Tree.size(compacted.tree) == 3
      assert Enum.map(Tree.transcript(compacted.tree), & &1.id) == ["u1", "a1"]
      assert [summary | _tail] = Tree.model_context(compacted.tree)
      assert summary.id == id
      assert Tackle.Lib.messages(compacted) |> Enum.map(& &1.id) == ["u1", "a1"]
    end
  end

  defp id_generator do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      "id-#{:counters.get(counter, 1)}"
    end
  end
end
