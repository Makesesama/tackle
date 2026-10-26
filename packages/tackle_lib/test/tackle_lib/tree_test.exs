defmodule Tackle.Lib.TreeTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction.Config
  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Message
  alias Tackle.Lib.ModelInfo
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Tree.Change
  alias Tackle.Lib.Tree.Navigator
  alias Tackle.Lib.Tree.Navigator.Outcome
  alias Tackle.Lib.Usage

  defp msg(id, role, content, opts \\ []) do
    %Message{
      id: id,
      role: role,
      content: content,
      timestamp: ~U[2026-01-01 00:00:00Z],
      tool_calls: Keyword.get(opts, :tool_calls, []),
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
      created_at: ~U[2026-01-01 00:00:00Z]
    }
  end

  defp append!(tree, message, opts \\ []) do
    {:ok, tree, entry} = Tree.append_message(tree, message, opts)
    {tree, entry}
  end

  describe "State.usage_segments/1" do
    test "splits the active path's usage at compactions" do
      u1 = %Usage{input_tokens: 10, cache_read_tokens: 0}
      u2 = %Usage{input_tokens: 5, cache_read_tokens: 10}
      u3 = %Usage{input_tokens: 4, cache_read_tokens: 1}

      tree = Tree.new()
      {tree, _} = append!(tree, msg("u1", :user, "hello"))
      {tree, _} = append!(tree, msg("a1", :assistant, "hi", token_usage: u1))
      {tree, _} = append!(tree, msg("u2", :user, "more"))
      {tree, _} = append!(tree, msg("a2", :assistant, "ok", token_usage: u2))
      {:ok, tree, _} = Tree.append_compaction(tree, compaction("c1", "summary", ["u1"], "u2"))
      {tree, _} = append!(tree, msg("u3", :user, "next"))
      {tree, _} = append!(tree, msg("a3", :assistant, "done", token_usage: u3))
      {:ok, tree, _} = Tree.append_compaction(tree, compaction("c2", "summary", ["u2"], "u3"))

      state = State.new(tree: tree)

      # The span after the last compaction has no usage yet, but is current.
      assert State.usage_segments(state) == [[u1, u2], [u3], []]

      # The rewritten prefix after each compaction is not a cache miss.
      assert Usage.cache_reuse_rate(State.usage_segments(state)) == 1.0
      assert Usage.cache_reuse_rate([u1, u2, u3]) < 1.0
    end
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
      assert length(Tree.enumerate(tree)) == 4

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
          msg("a1", :assistant, nil,
            tool_calls: [%Call{id: "call_1", name: "tool", arguments: %{}}]
          )
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

  describe "resumable_ids/1" do
    test "returns exactly the entries resumable?/2 accepts, across branches" do
      tree = tool_branches(Tree.new(), 3, 4)

      expected =
        tree
        |> Tree.enumerate()
        |> Enum.filter(&Tree.resumable?(tree, &1.id))
        |> MapSet.new(& &1.id)

      assert Tree.resumable_ids(tree) == expected
      refute MapSet.member?(expected, "b0-1-call")
      assert MapSet.member?(expected, "b0-1-result")
    end

    test "a result recorded before its call still answers it" do
      {tree, _} = append!(Tree.new(), msg("t1", :tool, "early", tool_call_id: "call_1"))

      {tree, _} =
        append!(
          tree,
          msg("a1", :assistant, nil,
            tool_calls: [%Call{id: "call_1", name: "tool", arguments: %{}}]
          )
        )

      assert Tree.resumable?(tree, "a1")
      assert Tree.resumable_ids(tree) == MapSet.new(["t1", "a1"])
    end

    test "is empty for an empty tree" do
      assert Tree.resumable_ids(Tree.new()) == MapSet.new()
    end
  end

  describe "child index" do
    test "stays consistent through appends, branches, and compactions" do
      tree = tool_branches(Tree.new(), 3, 2)
      {:ok, tree} = Tree.move(tree, "b1-0-user")
      {:ok, tree, _} = Tree.append_compaction(tree, compaction("c1", "summary", [], nil))
      {tree, _} = append!(tree, msg("root2", :user, "new root"), parent_id: nil)

      assert_index_consistent(tree)
    end

    test "children/2 and resumable_ids/1 read the index rather than scanning entries" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "one"))
      {:ok, tree} = Tree.move(tree, nil)
      {tree, _} = append!(tree, msg("u2", :user, "two"))

      hidden = %{tree | child_ids: %{nil => ["u2"]}}

      assert Enum.map(Tree.children(hidden, nil), & &1.id) == ["u2"]
      assert Tree.resumable_ids(hidden) == MapSet.new(["u2"])
    end

    test "handles a few thousand entries, deep and wide" do
      # 40 branches of 25 rounds (user, call, result, answer): 4,000 entries.
      tree = tool_branches(Tree.new(), 40, 25)
      assert length(Tree.enumerate(tree)) == 4_000

      chain =
        Enum.reduce(1..3_000, Tree.new(), fn index, tree ->
          {tree, _} = append!(tree, msg("m#{index}", :user, "step"))
          tree
        end)

      assert_index_consistent(tree)
      assert length(Tree.children(tree, nil)) == 40
      assert Enum.map(Tree.children(chain, "m1500"), & &1.id) == ["m1501"]

      resumable = Tree.resumable_ids(tree)
      # Every entry but the unanswered calls (one per round).
      assert MapSet.size(resumable) == 4_000 - 40 * 25
      refute MapSet.member?(resumable, "b39-24-call")
      assert MapSet.member?(resumable, "b39-24-answer")
      assert Tree.resumable?(tree, "b39-24-answer")

      assert MapSet.size(Tree.resumable_ids(chain)) == 3_000
    end
  end

  # `branches` root branches of `rounds` user/call/result/answer rounds each.
  defp tool_branches(tree, branches, rounds) do
    Enum.reduce(0..(branches - 1), tree, fn branch, tree ->
      {:ok, tree} = Tree.move(tree, nil)

      Enum.reduce(0..(rounds - 1), tree, fn round, tree ->
        prefix = "b#{branch}-#{round}"
        call_id = "#{prefix}-id"
        call = %Call{id: call_id, name: "tool", arguments: %{}}
        {tree, _} = append!(tree, msg("#{prefix}-user", :user, "go"))
        {tree, _} = append!(tree, msg("#{prefix}-call", :assistant, nil, tool_calls: [call]))
        {tree, _} = append!(tree, msg("#{prefix}-result", :tool, "ok", tool_call_id: call_id))
        {tree, _} = append!(tree, msg("#{prefix}-answer", :assistant, "done"))
        tree
      end)
    end)
  end

  defp assert_index_consistent(tree) do
    entries = Tree.enumerate(tree)
    expected = Enum.group_by(entries, & &1.parent_id, & &1.id)

    for parent <- [nil | Enum.map(entries, & &1.id)] do
      assert Enum.map(Tree.children(tree, parent), & &1.id) == Map.get(expected, parent, [])
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

      assert {:ok, moved, %Outcome{} = outcome} = Navigator.prepare(tree, {:edit, "u1"})
      assert outcome.draft.content == "first"
      refute outcome.noop?
      assert moved.active_id == nil

      assert %Change{from_id: "a1", to_id: nil, selected_id: "u1", mode: :edit} =
               outcome.change

      assert outcome.change.revision == moved.revision
    end

    test "rejects unknown entries, unsafe destinations, and stale revisions" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "run"))

      {tree, _} =
        append!(
          tree,
          msg("a1", :assistant, nil,
            tool_calls: [%Call{id: "call_1", name: "tool", arguments: %{}}]
          )
        )

      assert {:error, {:unknown_entry, "nope"}} = Navigator.prepare(tree, "nope")
      assert {:error, {:unsafe_continuation, "a1"}} = Navigator.prepare(tree, "a1")

      assert {:error, {:stale_transition, 0, revision}} =
               Navigator.prepare(tree, "u1", expected_revision: 0)

      assert is_integer(revision)
    end

    test "selecting the current position is a no-op" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "run"))

      assert {:ok, ^tree, outcome} = Navigator.prepare(tree, "u1")
      assert outcome.noop?

      assert outcome.change == %Change{
               from_id: "u1",
               to_id: "u1",
               selected_id: "u1",
               mode: :move,
               revision: tree.revision
             }
    end
  end

  describe "state integration" do
    test "a state derives transcript, model context, and readers from its tree" do
      state = State.new(id_generator: id_generator())

      state = State.add_message(state, msg("u1", :user, "hello"))

      state =
        State.add_message(
          state,
          msg("a1", :assistant, "hi", token_usage: %Usage{total_tokens: 5})
        )

      assert Enum.map(state.messages, & &1.id) == ["u1", "a1"]
      assert Enum.map(State.model_messages(state), & &1.id) == ["u1", "a1"]
      assert Tree.transcript(state.tree) == state.messages
    end

    test "restored branches extend their projections without importing sibling messages" do
      {tree, _} = append!(Tree.new(), msg("u1", :user, "old"))
      {tree, _} = append!(tree, msg("a1", :assistant, "reply"))
      {:ok, tree, _} = Tree.append_compaction(tree, compaction("c1", "summary", ["u1"], "a1"))
      {tree, _} = append!(tree, msg("u2", :user, "next"))
      {:ok, tree} = Tree.move(tree, "a1")
      {tree, _} = append!(tree, msg("u3", :user, "other branch"))

      {:ok, tree} = Tree.move(tree, "u2")
      restored = State.new(tree: tree)
      assert restored.messages == Tree.transcript(tree)
      assert State.model_messages(restored) == Tree.model_context(tree)

      extended = State.add_message(restored, msg("a2", :assistant, "answer"))
      assert extended.messages == Tree.transcript(extended.tree)
      assert State.model_messages(extended) == Tree.model_context(extended.tree)
      refute Enum.any?(extended.messages, &(&1.id == "u3"))

      assert {:ok, sibling, _outcome} = Tackle.Lib.navigate(extended, "u3")
      sibling = State.add_message(sibling, msg("a3", :assistant, "alternate answer"))
      assert sibling.messages == Tree.transcript(sibling.tree)
      assert State.model_messages(sibling) == Tree.model_context(sibling.tree)
      refute Enum.any?(State.model_messages(sibling), &(&1.id == "c1"))
    end

    test "navigate commits before installing and keeps state on commit failure" do
      state =
        State.new(
          id_generator: id_generator(),
          committer: __MODULE__.OkCommitter
        )

      state = State.add_message(state, msg("u1", :user, "hello"))
      state = State.add_message(state, msg("a1", :assistant, "hi"))

      assert {:ok, state, outcome} = Tackle.Lib.navigate(state, {:edit, "u1"})
      assert outcome.draft.content == "hello"
      assert state.tree.active_id == nil
      assert state.messages == []

      failing = %{
        State.new(id_generator: id_generator())
        | committer: __MODULE__.FailCommitter
      }

      failing = State.add_message(failing, msg("u1", :user, "hello"))

      assert {:error, {:durable_commit_failed, :nope}} = Tackle.Lib.navigate(failing, nil)
      assert failing.tree.active_id == "u1"
      assert [_ | _] = failing.messages
    end

    test "navigation always commits through the state's committer" do
      state = %{
        State.new(id_generator: id_generator())
        | committer: __MODULE__.RecordingCommitter
      }

      state = State.add_message(state, msg("u1", :user, "hello"))

      assert_raise ArgumentError, fn ->
        Tackle.Lib.navigate(state, nil, committer: __MODULE__.SkippingCommitter)
      end

      refute_received :skipped

      assert {:ok, _state, outcome} = Tackle.Lib.navigate(state, nil)
      assert_received {:committed, change, context}
      assert change == outcome.change
      assert context == %{session_id: state.session_id, context: state.context}
    end

    test "selecting the current position commits nothing" do
      state = %{
        State.new(id_generator: id_generator())
        | committer: __MODULE__.RecordingCommitter
      }

      state = State.add_message(state, msg("u1", :user, "hello"))

      assert {:ok, navigated, %Outcome{noop?: true}} = Tackle.Lib.navigate(state, "u1")
      assert navigated.tree == state.tree
      refute_received {:committed, _change, _context}
    end

    test "navigation honours an expected revision" do
      state = State.new(id_generator: id_generator())
      state = State.add_message(state, msg("u1", :user, "hello"))
      revision = state.tree.revision

      assert {:error, {:stale_transition, 0, ^revision}} =
               Tackle.Lib.navigate(state, nil, expected_revision: 0)
    end

    test "every state can navigate, since every state keeps a tree" do
      state = State.add_message(State.new(), msg("u1", :user, "hello"))

      assert {:ok, navigated, _outcome} = Tackle.Lib.navigate(state, nil)
      assert navigated.messages == []
      assert navigated.model_messages == []
    end

    test "navigation rejects a visibly active state" do
      state = State.new(id_generator: id_generator())
      state = State.add_message(state, msg("u1", :user, "hello"))
      state = %{state | status: :thinking}

      assert {:error, :turn_in_progress} = Tackle.Lib.navigate(state, nil)
    end
  end

  defmodule OkCommitter do
    @behaviour Tackle.Lib.Committer

    @impl true
    def commit(%Change{}, _context), do: :ok
  end

  defmodule FailCommitter do
    @behaviour Tackle.Lib.Committer

    @impl true
    def commit(%Change{}, _context), do: {:error, :nope}
  end

  defmodule RecordingCommitter do
    @behaviour Tackle.Lib.Committer

    @impl true
    def commit(change, context) do
      send(self(), {:committed, change, context})
      :ok
    end
  end

  defmodule SkippingCommitter do
    @behaviour Tackle.Lib.Committer

    @impl true
    def commit(_change, _context) do
      send(self(), :skipped)
      :ok
    end
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
        Config.new!(
          summarizer: TreeSummarizer,
          policy: [retain_tokens: 10, summary_max_tokens: 1_000]
        )

      selection = %Selection{
        adapter: TreeAdapter,
        provider_id: "test",
        model: "tree-model",
        ref: "test/tree-model",
        model_info: %ModelInfo{model: "tree-model", context_window: 100_000}
      }

      state =
        State.new(llm: selection, compaction: config, committer: RecordingCommitter)

      state = State.add_message(state, msg("u1", :user, String.duplicate("x", 4000)))
      state = State.add_message(state, msg("a1", :assistant, String.duplicate("y", 4000)))

      assert {:ok, compacted, %Record{compaction_id: id} = record} = Tackle.Lib.compact(state)
      assert id == compacted.tree.active_id

      # The committed record names the entry it attaches to, so a committer
      # does not need the tree.
      assert record.parent_id == "a1"
      assert Tree.entry(compacted.tree, id).compaction == record
      assert_received {:committed, ^record, _context}
      assert compacted.model_messages == Tree.model_context(compacted.tree)
      assert length(Tree.enumerate(compacted.tree)) == 3
      assert Enum.map(Tree.transcript(compacted.tree), & &1.id) == ["u1", "a1"]
      assert [summary | _tail] = Tree.model_context(compacted.tree)
      assert summary.id == id
      assert Tackle.Lib.messages(compacted) |> Enum.map(& &1.id) == ["u1", "a1"]

      appended = State.add_message(compacted, msg("u2", :user, "next"))
      assert appended.messages == Tree.transcript(appended.tree)
      assert State.model_messages(appended) == Tree.model_context(appended.tree)
      assert hd(State.model_messages(appended)).id == id
    end

    test "a compaction the tree refuses is never committed" do
      config =
        Config.new!(
          summarizer: TreeSummarizer,
          policy: [retain_tokens: 10, summary_max_tokens: 1_000]
        )

      selection = %Selection{
        adapter: TreeAdapter,
        provider_id: "test",
        model: "tree-model",
        ref: "test/tree-model",
        model_info: %ModelInfo{model: "tree-model", context_window: 100_000}
      }

      # The compaction id collides with an existing entry.
      state =
        State.new(
          llm: selection,
          compaction: config,
          committer: RecordingCommitter,
          id_generator: fn -> "u1" end
        )

      state = State.add_message(state, msg("u1", :user, String.duplicate("x", 4000)))
      state = State.add_message(state, msg("a1", :assistant, String.duplicate("y", 4000)))

      assert {:error, {:invalid_compaction, _reason}, ^state} = Tackle.Lib.compact(state)
      refute_received {:committed, _record, _context}
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
