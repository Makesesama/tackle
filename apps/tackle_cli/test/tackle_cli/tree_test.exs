defmodule Tackle.CLI.TreeTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias Tackle.CLI.Keybinds
  alias Tackle.CLI.TUI.{Composer, Picker, Tree, Viewport}
  alias Tackle.CLI.TUI.State, as: TuiState
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.{Message, State}
  alias Tackle.Lib.Tree, as: ConversationTree

  defp base_state(opts \\ []) do
    input = Input.new()
    :ok = Input.set_value(input, Keyword.get(opts, :draft, ""))

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

  test "items project branch structure, active path, and edit targets" do
    tree = tree_with_branches()
    items = Tree.items(tree)

    assert hd(items).id == :conversation_root
    labels = Enum.map(items, & &1.primary)

    assert Enum.any?(labels, &String.contains?(&1, "investigate"))
    assert Enum.any?(labels, &String.contains?(&1, "try B"))

    assert Enum.all?(items, &(length(&1.ancestor_continues) == &1.depth))
    assert Enum.count(items, & &1.active?) == 2

    # The active leaf is marked and user messages target edits.
    active = Enum.find(items, &(&1.marker == "●"))
    assert active.id == {:entry, ConversationTree.active_id(tree)}

    edit = Enum.find(items, &match?({:edit, _}, &1.id))
    assert match?({:edit, _}, edit.id)
  end

  test "multiple root histories start at the left edge without a virtual fork" do
    tree = tree_with_branches()
    items = Tree.items(tree)

    assert Enum.map(tl(items), &{&1.depth, &1.connector?, &1.ancestor_continues}) == [
             {0, false, []},
             {1, false, [false]},
             {0, false, []},
             {1, false, [false]}
           ]

    {:noreply, state} = Tree.open(base_state(agent_state: %{State.new() | tree: tree}))
    popup = Tree.popup(state)
    area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: 80, height: 10}

    [{%ExRatatui.Widgets.Paragraph{text: lines}, ^area}] =
      Tackle.CLI.Widgets.Tree.render(
        %Tackle.CLI.Widgets.Tree{nodes: popup.nodes, selected: popup.selected},
        area
      )

    text = Enum.map(lines, fn line -> Enum.map_join(line.spans, & &1.content) end)
    assert Enum.at(text, 1) =~ "  ┬ • user: try B"
    assert Enum.at(text, 2) =~ "› └─ • assistant: result B"
    assert Enum.at(text, 3) =~ "  ┬ user: investigate"
    assert Enum.at(text, 4) =~ "  └─ assistant: two approaches"
    refute Enum.any?(text, &String.contains?(&1, "├"))
  end

  test "real forks inside multiple root histories retain their connectors" do
    {:ok, tree, root} =
      ConversationTree.append_message(ConversationTree.new(), Message.user("shared"))

    {:ok, tree, first} =
      ConversationTree.append_message(tree, Message.assistant(content: "first"))

    {:ok, tree} = ConversationTree.move(tree, root.id)

    {:ok, tree, second} =
      ConversationTree.append_message(tree, Message.assistant(content: "second"))

    {:ok, tree} = ConversationTree.move(tree, nil)
    {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("other root"))

    by_id = Map.new(Tree.items(tree), &{&1.id, &1})
    assert by_id[{:edit, root.id}].depth == 0
    refute by_id[{:edit, root.id}].connector?

    for entry <- [first, second] do
      assert by_id[{:entry, entry.id}].depth == 1
      assert by_id[{:entry, entry.id}].connector?
      assert by_id[{:entry, entry.id}].ancestor_continues == [false]
    end
  end

  test "popup uses the native tree surface" do
    state = base_state(agent_state: %{State.new() | tree: tree_with_branches()})
    assert {:noreply, state} = Tree.open(state)
    assert %Tackle.CLI.Widgets.TreePopup{nodes: nodes, count: count} = Tree.popup(state)
    assert count == length(nodes)
    assert Enum.any?(nodes, &String.starts_with?(&1.text, "user: "))
    popup = Tree.popup(state)
    assert Enum.at(nodes, popup.selected).secondary == "current position"
    assert hd(nodes).secondary == nil
  end

  test "linear history stays flat and opens on the active leaf" do
    {:ok, tree, _} =
      ConversationTree.append_message(ConversationTree.new(), Message.user("first"))

    {:ok, tree, _} =
      ConversationTree.append_message(tree, Message.assistant(content: "second"))

    {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("third"))
    items = Tree.items(tree)
    messages = tl(items)

    assert Enum.all?(messages, &(&1.depth == 0 and not &1.connector?))

    state = base_state(agent_state: %{State.new() | tree: tree})
    assert {:noreply, %{overlay: {:tree, %{picker: picker}}}} = Tree.open(state)
    assert Picker.selected(picker).id == {:edit, ConversationTree.active_id(tree)}
  end

  test "only actual sibling paths receive branch connectors" do
    {:ok, tree, root} =
      ConversationTree.append_message(ConversationTree.new(), Message.user("root"))

    {:ok, tree, first} =
      ConversationTree.append_message(tree, Message.assistant(content: "first branch"))

    {:ok, tree} = ConversationTree.move(tree, root.id)

    {:ok, tree, second} =
      ConversationTree.append_message(tree, Message.assistant(content: "second branch"))

    items = Tree.items(tree)
    by_id = Map.new(items, &{&1.id, &1})

    refute by_id[{:edit, root.id}].connector?
    assert by_id[{:entry, first.id}].connector?
    assert by_id[{:entry, second.id}].connector?
  end

  test "native rendering joins forks with visible rails on both sibling paths" do
    {:ok, tree, root} =
      ConversationTree.append_message(ConversationTree.new(), Message.user("shared"))

    {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("A"))
    {:ok, tree, _} = ConversationTree.append_message(tree, Message.assistant(content: "answer A"))
    {:ok, tree} = ConversationTree.move(tree, root.id)
    {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("B"))
    {:ok, tree, _} = ConversationTree.append_message(tree, Message.assistant(content: "answer B"))

    state = base_state(agent_state: %{State.new() | tree: tree})
    {:noreply, state} = Tree.open(state)
    popup = Tree.popup(state)
    area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: 80, height: 10}

    [{%ExRatatui.Widgets.Paragraph{text: lines}, ^area}] =
      Tackle.CLI.Widgets.Tree.render(
        %Tackle.CLI.Widgets.Tree{nodes: popup.nodes, selected: popup.selected},
        area
      )

    text = Enum.map(lines, fn line -> Enum.map_join(line.spans, & &1.content) end)
    assert Enum.at(text, 1) =~ "┬ • user: shared"
    assert Enum.at(text, 2) =~ "├──┬ • user: B"
    assert Enum.at(text, 3) =~ "› │  └─ • assistant: answer B"
    assert Enum.at(text, 4) =~ "└──┬ user: A"
    assert Enum.at(text, 5) =~ "   └─ assistant: answer A"
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
    assert [_, _, _, _ | _] = Picker.filtered(picker)

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

    assert Input.get_value(state.input) == "earlier text"
    assert state.notice =~ "workspace is unchanged"
  end

  test "a non-empty draft is preserved when a user message is selected" do
    state = base_state(draft: "my own draft")

    outcome = %{mode: :edit, draft: Message.user("earlier text"), destination_id: nil}
    state = Tree.apply_outcome(state, outcome)

    assert Input.get_value(state.input) == "my own draft"
    assert state.notice =~ "draft kept"
  end

  test "a move outcome never overwrites the draft" do
    state = base_state(draft: "keep me")
    state = Tree.apply_outcome(state, %{mode: :move, draft: nil, destination_id: "a1"})

    assert Input.get_value(state.input) == "keep me"
  end

  test "/tree opens the picker instead of submitting while idle" do
    state = base_state(agent_state: %{State.new() | tree: tree_with_branches()}, draft: "/tree")

    assert {:noreply, %{overlay: {:tree, _}, pending_operation: nil}} = Composer.submit(state)
    assert Input.get_value(state.input) == ""
  end

  test "/tree while busy keeps the draft and does not open" do
    state = base_state(agent_state: %{State.new() | tree: tree_with_branches()}, draft: "/tree")
    state = %{state | pending_operation: %{ref: make_ref(), kind: :compact}}

    assert {:noreply, %{overlay: nil, notice: notice}} = Composer.submit(state)
    assert notice =~ "Busy"
    assert Input.get_value(state.input) == "/tree"
  end

  test "/tree with no tree keeps the draft and explains why" do
    state = base_state(draft: "/tree")

    assert {:noreply, %{overlay: nil, notice: notice}} = Composer.submit(state)
    assert notice =~ "no conversation tree"
    assert Input.get_value(state.input) == "/tree"
  end
end
