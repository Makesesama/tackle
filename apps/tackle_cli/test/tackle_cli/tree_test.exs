defmodule Tackle.CLI.TreeTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias Tackle.CLI.Keybinds
  alias Tackle.CLI.TUI.{Composer, Picker, Tree, Viewport}
  alias Tackle.CLI.TUI.State, as: TuiState
  alias Tackle.CLI.Widgets.{Input, TreeScreen}
  alias Tackle.Lib.{Message, State}
  alias Tackle.Lib.Tree, as: ConversationTree
  alias Tackle.Lib.Tree.Change
  alias Tackle.Lib.Tree.Navigator.Outcome

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

  defp edit_outcome(text) do
    %Outcome{
      change: %Change{from_id: "a1", to_id: nil, selected_id: "u1", mode: :edit, revision: 3},
      draft: Message.user(text)
    }
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

  # user → assistant (text + two tool calls) → two results → reply, then a
  # sibling reply forked from the first tool result, which is inspect only.
  defp tree_with_tool_turn do
    {:ok, tree, _} =
      ConversationTree.append_message(ConversationTree.new(), Message.user("read the docs"))

    {:ok, tree, _} =
      ConversationTree.append_message(
        tree,
        Message.assistant(
          content: "Let me look",
          tool_calls: [
            %{id: "call_1", name: "read", arguments: %{"path" => "README.md"}},
            %{id: "call_2", name: "bash", arguments: %{"command" => "ls -la"}}
          ]
        )
      )

    {:ok, tree, first} =
      ConversationTree.append_message(tree, Message.tool_result("call_1", "read", "# Readme"))

    {:ok, tree, _} =
      ConversationTree.append_message(tree, Message.tool_result("call_2", "bash", "total 0"))

    {:ok, tree, _} =
      ConversationTree.append_message(tree, Message.assistant(content: "It is a harness"))

    {tree, first}
  end

  defp overlay_state(tree, view) do
    state = base_state(agent_state: State.new(tree: tree))
    {:noreply, state} = Tree.open(state)
    if view == :default, do: state, else: cycle_to(state, view)
  end

  defp cycle_to(%{overlay: {:tree, %{view: view}}} = state, view), do: state

  defp cycle_to(state, view) do
    {:noreply, state} = Tree.handle(:next_view, state)
    cycle_to(state, view)
  end

  defp rows(%{overlay: {:tree, %{picker: picker}}}), do: Picker.filtered(picker)

  defp graph(items),
    do: Enum.map(items, &(&1.prefix <> if(&1.glyph, do: &1.glyph <> " ", else: "") <> &1.primary))

  defp render_text(%TreeScreen{} = screen, width, height) do
    area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: width, height: height}

    for {%ExRatatui.Widgets.Paragraph{text: lines}, _rect} <- TreeScreen.render(screen, area),
        line <- List.wrap(lines) do
      Enum.map_join(line.spans, & &1.content)
    end
  end

  defp selected_row(%{overlay: {:tree, %{picker: picker}}}),
    do: picker |> Picker.filtered() |> Enum.at(picker.selected)

  defp selectable(picker, predicate) do
    index = picker |> Picker.filtered() |> Enum.find_index(predicate)
    Picker.move(picker, index || 0)
  end

  test "F5 resolves to the tree picker" do
    assert Keybinds.base(%Key{code: "f5", modifiers: []}, :composer) == :tree
    refute Keybinds.repeatable?(%Key{code: "f5", modifiers: []})
  end

  test "rows lay out a git-style graph with forks, active path, and edit targets" do
    {:ok, tree, root} =
      ConversationTree.append_message(ConversationTree.new(), Message.user("shared"))

    {:ok, tree, reply} =
      ConversationTree.append_message(tree, Message.assistant(content: "answer"))

    {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("A"))
    {:ok, tree, _} = ConversationTree.append_message(tree, Message.assistant(content: "answer A"))
    {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("A2"))
    {:ok, tree} = ConversationTree.move(tree, reply.id)
    {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("B"))
    {:ok, tree, b} = ConversationTree.append_message(tree, Message.assistant(content: "answer B"))

    items = Tree.items(tree)

    assert graph(items) == [
             "○ Start of conversation",
             "● shared",
             "│ answer",
             "├─● B",
             "│   answer B",
             "└─● A",
             "  │ answer A",
             "  ● A2"
           ]

    assert Enum.map(items, & &1.active?) == [true, true, true, true, true, false, false, false]
    assert Enum.find(items, & &1.current?).id == {:entry, b.id}
    assert Enum.at(items, 1).id == {:edit, root.id}
    assert Enum.at(items, 1).kind == :user
    assert Enum.at(items, 2).kind == :reply
  end

  test "independent root histories fork from the start row" do
    items = Tree.items(tree_with_branches())

    assert graph(items) == [
             "○ Start of conversation",
             "├─● try B",
             "│   result B",
             "└─● investigate",
             "    two approaches"
           ]
  end

  test "linear history keeps a continuous rail and opens on the active leaf" do
    {:ok, tree, _} =
      ConversationTree.append_message(ConversationTree.new(), Message.user("first"))

    {:ok, tree, _} =
      ConversationTree.append_message(tree, Message.assistant(content: "second"))

    {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("third"))

    assert graph(Tree.items(tree)) == [
             "○ Start of conversation",
             "● first",
             "│ second",
             "● third"
           ]

    state = base_state(agent_state: State.new(tree: tree))
    assert {:noreply, %{overlay: {:tree, %{picker: picker}}}} = Tree.open(state)
    assert Picker.selected(picker).id == {:edit, ConversationTree.active_id(tree)}
  end

  test "the screen paints the header, view tabs, graph rows, selection, and hints" do
    state = %{
      base_state(agent_state: State.new(tree: tree_with_branches()))
      | size: {80, 20}
    }

    {:noreply, state} = Tree.open(state)

    assert %TreeScreen{view: :default} = screen = Tree.popup(state)
    text = render_text(screen, 80, 20)

    assert hd(text) =~ "Conversation tree"
    assert hd(text) =~ "messages  user only  all entries"
    assert Enum.any?(text, &(&1 =~ "Type to search  ·  5 entries"))
    assert Enum.any?(text, &(&1 =~ ~r/^ › │   result B\s+current $/))
    assert Enum.any?(text, &(&1 =~ "├─● try B"))
    assert Enum.any?(text, &(&1 =~ "3 / 5"))
    assert List.last(text) =~ "Enter stay here"
    assert List.last(text) =~ "Tab view"
  end

  test "the hint names what Enter does for the selected row" do
    state = %{
      base_state(agent_state: State.new(tree: tree_with_branches()))
      | size: {80, 20}
    }

    {:noreply, state} = Tree.open(state)
    {:noreply, state} = Tree.handle(:previous, state)
    assert state |> Tree.popup() |> render_text(80, 20) |> List.last() =~ "Enter edit from here"

    {:noreply, state} = Tree.handle(:previous, state)
    assert state |> Tree.popup() |> render_text(80, 20) |> List.last() =~ "Enter start over"
  end

  test "the list scrolls to keep the selection visible" do
    tree =
      Enum.reduce(1..30, ConversationTree.new(), fn index, tree ->
        {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("prompt #{index}"))
        tree
      end)

    state = %{base_state(agent_state: State.new(tree: tree)) | size: {80, 12}}
    {:noreply, state} = Tree.open(state)
    text = state |> Tree.popup() |> render_text(80, 12)
    assert Enum.any?(text, &(&1 =~ "› ● prompt 30"))
    refute Enum.any?(text, &(&1 =~ "Start of conversation"))

    state =
      Enum.reduce(1..7, state, fn _, state ->
        {:noreply, state} = Tree.handle(:page_up, state)
        state
      end)

    text = state |> Tree.popup() |> render_text(80, 12)
    assert Enum.any?(text, &(&1 =~ "› ○ Start of conversation"))
  end

  test "an incomplete tool batch is inspect only" do
    tree = tree_with_pending_tool()
    items = Tree.items(tree)

    unsafe = Enum.find(items, &(&1.id == :unsafe_entry))
    assert unsafe
    assert unsafe.secondary =~ "inspect only"
  end

  test "a tree of a few thousand entries lays out every row once" do
    # 30 root branches of 25 rounds: user, tool call, result, reply.
    tree =
      Enum.reduce(1..30, ConversationTree.new(), fn branch, tree ->
        {:ok, tree} = ConversationTree.move(tree, nil)

        Enum.reduce(1..25, tree, fn round, tree ->
          id = "call-#{branch}-#{round}"
          call = %{id: id, name: "bash", arguments: %{"command" => "ls"}}
          {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("go #{id}"))

          {:ok, tree, _} =
            ConversationTree.append_message(tree, Message.assistant(tool_calls: [call]))

          {:ok, tree, _} =
            ConversationTree.append_message(tree, Message.tool_result(id, "bash", "ok"))

          {:ok, tree, _} =
            ConversationTree.append_message(tree, Message.assistant(content: "done"))

          tree
        end)
      end)

    assert length(ConversationTree.enumerate(tree)) == 3_000

    all = Tree.items(tree, :all)
    assert length(all) == 3_001
    assert all |> Enum.map(& &1.entry_id) |> Enum.uniq() |> length() == 3_001
    # Only the tool calls wait for a result; every other entry is selectable.
    assert Enum.count(all, & &1.unsafe?) == 750

    default = Tree.items(tree)
    assert Enum.count(default, &(&1.kind == :user)) == 750
    refute Enum.any?(default, & &1.unsafe?)
  end

  test "open refuses when busy or when empty" do
    busy = base_state(agent_state: State.new(tree: tree_with_branches()))
    busy = %{busy | active_turn: %{id: "turn-1"}}
    assert {:noreply, %{notice: notice}} = Tree.open(busy)
    assert notice =~ "idle"

    empty = base_state()
    assert {:noreply, %{notice: notice}} = Tree.open(empty)
    assert notice =~ "empty"
  end

  test "open mounts the picker and cancel leaves conversation state unchanged" do
    state = base_state(agent_state: State.new(tree: tree_with_branches()))
    assert {:noreply, %{overlay: {:tree, %{picker: picker}}}} = Tree.open(state)
    assert [_, _, _, _ | _] = Picker.filtered(picker)

    assert {:noreply, %{overlay: nil}} =
             Tree.handle(:close, %{state | overlay: {:tree, %{picker: picker}}})
  end

  test "accept on a user message starts an edit navigation" do
    tree = tree_with_branches()
    state = base_state(agent_state: State.new(tree: tree))

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
    state = base_state(agent_state: State.new(tree: tree))

    picker = Picker.new(Tree.items(tree))
    picker = selectable(picker, &(&1.id == :unsafe_entry))
    state = %{state | overlay: {:tree, %{picker: picker}}}

    assert {:noreply, %{notice: notice, pending_operation: nil}} = Tree.handle(:accept, state)
    assert notice =~ "Unsafe"
  end

  test "an untouched composer receives the selected user message" do
    state = base_state()

    state = Tree.apply_outcome(state, edit_outcome("earlier text"))

    assert Input.get_value(state.input) == "earlier text"
    assert state.notice =~ "workspace is unchanged"
  end

  test "a non-empty draft is preserved when a user message is selected" do
    state = base_state(draft: "my own draft")

    state = Tree.apply_outcome(state, edit_outcome("earlier text"))

    assert Input.get_value(state.input) == "my own draft"
    assert state.notice =~ "draft kept"
  end

  test "a move outcome never overwrites the draft" do
    state = base_state(draft: "keep me")

    outcome = %Outcome{
      change: %Change{from_id: "a2", to_id: "a1", selected_id: "a1", revision: 3}
    }

    state = Tree.apply_outcome(state, outcome)

    assert Input.get_value(state.input) == "keep me"
  end

  test "/tree opens the picker instead of submitting while idle" do
    state = base_state(agent_state: State.new(tree: tree_with_branches()), draft: "/tree")

    assert {:noreply, %{overlay: {:tree, _}, pending_operation: nil}} = Composer.submit(state)
    assert Input.get_value(state.input) == ""
  end

  test "/tree while busy keeps the draft and does not open" do
    state = base_state(agent_state: State.new(tree: tree_with_branches()), draft: "/tree")
    state = %{state | pending_operation: %{ref: make_ref(), kind: :compact}}

    assert {:noreply, %{overlay: nil, notice: notice}} = Composer.submit(state)
    assert notice =~ "Busy"
    assert Input.get_value(state.input) == "/tree"
  end

  test "/tree with an empty tree keeps the draft and explains why" do
    state = base_state(draft: "/tree")

    assert {:noreply, %{overlay: nil, notice: notice}} = Composer.submit(state)
    assert notice =~ "empty"
    assert Input.get_value(state.input) == "/tree"
  end

  describe "views" do
    test "Tab and Shift+Tab resolve to view cycling in the tree picker" do
      assert Keybinds.tree(%Key{code: "tab", modifiers: []}) == :next_view
      assert Keybinds.tree(%Key{code: "tab", modifiers: ["shift"]}) == :previous_view
      assert Keybinds.tree(%Key{code: "back_tab", modifiers: []}) == :previous_view
      assert Keybinds.tree(%Key{code: "down", modifiers: []}) == :next
      assert Keybinds.tree(%Key{code: "x", modifiers: []}) == {:insert, "x"}
      assert Keybinds.tree(%Key{code: "esc", modifiers: []}) == :cancel
      assert Keybinds.tree(%Key{code: "page_down", modifiers: []}) == :page_down
    end

    test "the default view folds tool steps into the reply and hides unsafe entries" do
      {tree, _first} = tree_with_tool_turn()
      items = Tree.items(tree, :default)

      assert graph(items) == [
               "○ Start of conversation",
               "● read the docs",
               "  It is a harness"
             ]

      reply = List.last(items)
      assert reply.secondary == "2 tools: read, bash · current"
      refute Enum.any?(items, & &1.unsafe?)
    end

    test "the user view shows only user messages and the current position" do
      {tree, _first} = tree_with_tool_turn()
      items = Tree.items(tree, :user)

      assert Enum.map(items, & &1.primary) == [
               "Start of conversation",
               "read the docs",
               "It is a harness"
             ]

      {:ok, tree} = ConversationTree.move(tree, nil)

      assert Enum.map(Tree.items(tree, :user), & &1.primary) == [
               "Start of conversation",
               "read the docs"
             ]
    end

    test "the all view labels tool rows with their main argument and marks unsafe rows" do
      {tree, _first} = tree_with_tool_turn()
      items = Tree.items(tree, :all)

      assert Enum.map(items, &{&1.prefix <> (&1.glyph || "") <> &1.primary, &1.unsafe?}) == [
               {"○Start of conversation", false},
               {"●read the docs", false},
               {"  Let me look", true},
               {"  read README.md", true},
               {"  bash ls -la", false},
               {"  It is a harness", false}
             ]

      assert Enum.at(items, 2).secondary == "inspect only"
      assert Enum.at(items, 3).id == :unsafe_entry
      assert Enum.at(items, 4).id == {:entry, Enum.at(items, 4).entry_id}
    end

    test "the cursor skips inspect-only rows in the all view" do
      {tree, _first} = tree_with_tool_turn()
      state = overlay_state(tree, :all)

      assert selected_row(state).primary == "It is a harness"
      {:noreply, state} = Tree.handle(:previous, state)
      assert selected_row(state).primary == "bash ls -la"
      {:noreply, state} = Tree.handle(:previous, state)
      assert selected_row(state).primary == "read the docs"
      {:noreply, state} = Tree.handle(:next, state)
      assert selected_row(state).primary == "bash ls -la"
    end

    test "a query that lands on an inspect-only row settles on a selectable one" do
      {tree, _first} = tree_with_tool_turn()
      state = overlay_state(tree, :all)

      {:noreply, state} = Tree.handle({:insert, "look"}, state)
      assert [%{unsafe?: true}] = rows(state)
      assert {:noreply, %{notice: notice}} = Tree.handle(:accept, state)
      assert notice =~ "Unsafe"

      {:noreply, state} = Tree.handle(:backspace, state)
      {:noreply, state} = Tree.handle(:backspace, state)
      {:noreply, state} = Tree.handle(:backspace, state)
      {:noreply, state} = Tree.handle(:backspace, state)
      refute selected_row(state).unsafe?
    end

    test "a query selects its best match while rows keep graph order" do
      {tree, _first} = tree_with_tool_turn()
      state = overlay_state(tree, :default)

      {:noreply, state} = Tree.handle({:insert, "harness"}, state)
      assert selected_row(state).primary == "It is a harness"

      {:noreply, state} = Tree.handle(:cancel, state)
      assert selected_row(state).primary == "It is a harness"
      assert length(rows(state)) == 3
    end

    test "opening on an unsafe current entry selects its nearest safe ancestor" do
      {:ok, tree, user} =
        ConversationTree.append_message(ConversationTree.new(), Message.user("run the test"))

      {:ok, tree, _} = ConversationTree.append_message(tree, Message.assistant(content: "done"))
      {:ok, tree} = ConversationTree.move(tree, user.id)

      {:ok, tree, _} =
        ConversationTree.append_message(
          tree,
          Message.assistant(tool_calls: [%{id: "call_1", name: "bash", arguments: %{}}])
        )

      state = overlay_state(tree, :default)
      assert selected_row(state).id == {:edit, user.id}
    end

    test "a resize keeps the selection visible" do
      tree =
        Enum.reduce(1..30, ConversationTree.new(), fn index, tree ->
          {:ok, tree, _} = ConversationTree.append_message(tree, Message.user("prompt #{index}"))
          tree
        end)

      state = %{base_state(agent_state: State.new(tree: tree)) | size: {80, 40}}
      {:noreply, state} = Tree.open(state)
      state = Tree.resize(%{state | size: {80, 12}})
      text = state |> Tree.popup() |> render_text(80, 12)
      assert Enum.any?(text, &(&1 =~ "› ● prompt 30"))
    end

    test "Esc clears an active search before closing" do
      {tree, _first} = tree_with_tool_turn()
      state = overlay_state(tree, :default)
      {:noreply, state} = Tree.handle({:insert, "docs"}, state)
      assert [%{primary: "read the docs"}] = rows(state)

      {:noreply, state} = Tree.handle(:cancel, state)
      assert {:tree, %{picker: %{query: ""}}} = state.overlay
      assert selected_row(state).primary == "read the docs"

      assert {:noreply, %{overlay: nil}} = Tree.handle(:cancel, state)
    end

    test "cycling views keeps the selection on the nearest visible entry" do
      {tree, _first} = tree_with_tool_turn()
      state = overlay_state(tree, :all)
      {:noreply, state} = Tree.handle(:previous, state)
      assert selected_row(state).primary == "bash ls -la"

      {:noreply, state} = Tree.handle(:previous_view, state)
      assert {:tree, %{view: :user}} = state.overlay
      assert selected_row(state).primary == "read the docs"

      {:noreply, state} = Tree.handle(:previous_view, state)
      assert {:tree, %{view: :default}} = state.overlay
      assert selected_row(state).primary == "read the docs"

      assert %TreeScreen{view: :default} = Tree.popup(state)
    end

    test "branches forked inside hidden tool steps stay connected to their visible parent" do
      {tree, first} = tree_with_tool_turn()
      {:ok, tree} = ConversationTree.move(tree, first.id)

      {:ok, tree, _} =
        ConversationTree.append_message(tree, Message.tool_result("call_2", "bash", "retry"))

      {:ok, tree, _} = ConversationTree.append_message(tree, Message.assistant(content: "Other"))

      items = Tree.items(tree, :default)

      assert graph(items) == [
               "○ Start of conversation",
               "● read the docs",
               "├─◇ Other",
               "└─◇ It is a harness"
             ]

      assert Enum.at(items, 2).active?
      refute Enum.at(items, 3).active?
    end
  end
end
