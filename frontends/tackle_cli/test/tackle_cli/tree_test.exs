defmodule Tackle.CLI.TreeTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias Tackle.CLI.Keybinds
  alias Tackle.CLI.TUI.{Composer, Picker, Tree, Viewport}
  alias Tackle.CLI.TUI.State, as: TuiState
  alias Tackle.Lib.{Message, State}
  alias Tackle.Lib.Tree, as: ConversationTree

  defp base_state(opts \\ []) do
    input = ExRatatui.textarea_new()
    :ok = ExRatatui.textarea_set_value(input, Keyword.get(opts, :draft, ""))

    state = %TuiState{
      input: input,
      size: {80, 24},
      conversation: Viewport.new_conversation(80, 24),
      agent_state: Keyword.get(opts, :agent_state, State.new()),
      agent_ref: :agent_ref,
      session_id: "session-1"
    }

    state = Viewport.update_draft(state)
    %{state | overlay: Keyword.get(opts, :overlay)}
  end

  defp tree_with_branches do
    {:ok, tree, _} =
      ConversationTree.append_message(ConversationTree.new(), Message.user("investigate"))

    {:ok, tree, _} =
      ConversationTree.append_message(tree, Message.assistant(content: "two approaches"))

    {:ok, tree} = ConversationTree.move(tree, nil)
    {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("try B"))
    {:ok, tree, _} = ConversationTree.append_message(tree, Message.assistant(content: "result B"))
    tree
  end

  defp tree_with_pending_tool do
    {:ok, tree, _} =
      ConversationTree.append_message(ConversationTree.new(), Message.user("run it"))

    {:ok, tree, _} =
      ConversationTree.append_message(
        tree,
        Message.assistant(tool_calls: [%{id: "call_1", name: "tool", arguments: %{}}])
      )

    tree
  end

  defp selectable(picker, predicate) do
    index = picker |> Picker.filtered() |> Enum.find_index(predicate)
    Picker.move(picker, index || 0)
  end

  test "F5 resolves to the tree picker" do
    assert Keybinds.base(%Key{code: "f5", modifiers: []}, :composer) == :tree
    refute Keybinds.repeatable?(%Key{code: "f5", modifiers: []})
  end

  test "items render branches with an active marker and edit targets" do
    tree = tree_with_branches()
    items = Tree.items(tree)

    assert hd(items).id == :conversation_root
    labels = Enum.map(items, & &1.primary)

    assert Enum.any?(labels, &String.contains?(&1, "investigate"))
    assert Enum.any?(labels, &String.contains?(&1, "try B"))

    # The active branch (try B) is marked and its user message targets an edit.
    active = Enum.find(items, &(&1.marker == "●"))
    assert active.id == {:entry, ConversationTree.active_id(tree)}

    edit = Enum.find(items, &match?({:edit, _}, &1.id))
    assert match?({:edit, _}, edit.id)
  end

  test "an incomplete tool batch is inspect only" do
    tree = tree_with_pending_tool()
    items = Tree.items(tree)

    unsafe = Enum.find(items, &(&1.id == :unsafe_entry))
    assert unsafe
    assert unsafe.secondary =~ "inspect only"
  end

  test "open refuses when busy, without a tree, or when empty" do
    busy = base_state(agent_state: %{State.new() | tree: tree_with_branches()})
    busy = %{busy | active_turn: %{id: "turn-1"}}
    assert {:noreply, %{notice: notice}} = Tree.open(busy)
    assert notice =~ "idle"

    no_tree = base_state()
    assert {:noreply, %{notice: notice}} = Tree.open(no_tree)
    assert notice =~ "no conversation tree"

    empty = base_state(agent_state: %{State.new() | tree: ConversationTree.new()})
    assert {:noreply, %{notice: notice}} = Tree.open(empty)
    assert notice =~ "empty"
  end

  test "open mounts the picker and cancel leaves conversation state unchanged" do
    state = base_state(agent_state: %{State.new() | tree: tree_with_branches()})
    assert {:noreply, %{overlay: {:tree, %{picker: picker}}}} = Tree.open(state)
    assert length(Picker.filtered(picker)) >= 4

    assert {:noreply, %{overlay: nil}} =
             Tree.handle(:close, %{state | overlay: {:tree, %{picker: picker}}})
  end

  test "accept on a user message starts an edit navigation" do
    tree = tree_with_branches()
    state = base_state(agent_state: %{State.new() | tree: tree})

    picker = Picker.new(Tree.items(tree))
    picker = selectable(picker, &match?({:edit, _}, &1.id))
    state = %{state | overlay: {:tree, %{picker: picker}}}

    assert {:noreply, %{pending_operation: %{kind: :navigate, ref: ref}, overlay: nil},
            commands: [command]} =
             Tree.handle(:accept, state)

    assert is_reference(ref)
    assert match?(%ExRatatui.Command{}, command)
  end

  test "accept on an unsafe entry only notifies" do
    tree = tree_with_pending_tool()
    state = base_state(agent_state: %{State.new() | tree: tree})

    picker = Picker.new(Tree.items(tree))
    picker = selectable(picker, &(&1.id == :unsafe_entry))
    state = %{state | overlay: {:tree, %{picker: picker}}}

    assert {:noreply, %{notice: notice, pending_operation: nil}} = Tree.handle(:accept, state)
    assert notice =~ "Unsafe"
  end

  test "an untouched composer receives the selected user message" do
    state = base_state()

    outcome = %{mode: :edit, draft: Message.user("earlier text"), destination_id: nil}
    state = Tree.apply_outcome(state, outcome)

    assert ExRatatui.textarea_get_value(state.input) == "earlier text"
    assert state.notice =~ "workspace is unchanged"
  end

  test "a non-empty draft is preserved when a user message is selected" do
    state = base_state(draft: "my own draft")

    outcome = %{mode: :edit, draft: Message.user("earlier text"), destination_id: nil}
    state = Tree.apply_outcome(state, outcome)

    assert ExRatatui.textarea_get_value(state.input) == "my own draft"
    assert state.notice =~ "draft kept"
  end

  test "a move outcome never overwrites the draft" do
    state = base_state(draft: "keep me")
    state = Tree.apply_outcome(state, %{mode: :move, draft: nil, destination_id: "a1"})

    assert ExRatatui.textarea_get_value(state.input) == "keep me"
  end

  test "/tree opens the picker instead of submitting while idle" do
    state = base_state(agent_state: %{State.new() | tree: tree_with_branches()}, draft: "/tree")

    assert {:noreply, %{overlay: {:tree, _}, pending_operation: nil}} = Composer.submit(state)
    assert ExRatatui.textarea_get_value(state.input) == ""
  end

  test "/tree while busy keeps the draft and does not open" do
    state = base_state(agent_state: %{State.new() | tree: tree_with_branches()}, draft: "/tree")
    state = %{state | pending_operation: %{ref: make_ref(), kind: :compact}}

    assert {:noreply, %{overlay: nil, notice: notice}} = Composer.submit(state)
    assert notice =~ "Busy"
    assert ExRatatui.textarea_get_value(state.input) == "/tree"
  end

  test "/tree with no tree keeps the draft and explains why" do
    state = base_state(draft: "/tree")

    assert {:noreply, %{overlay: nil, notice: notice}} = Composer.submit(state)
    assert notice =~ "no conversation tree"
    assert ExRatatui.textarea_get_value(state.input) == "/tree"
  end
end
