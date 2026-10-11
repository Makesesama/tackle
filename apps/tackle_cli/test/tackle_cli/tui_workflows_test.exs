defmodule Tackle.CLI.TUI.WorkflowsTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Widgets.{Paragraph, Popup}
  alias Tackle.CLI.Keybinds

  alias Tackle.CLI.TUI.{
    ExternalEditor,
    Pastes,
    Picker,
    RuntimeEvents,
    SlashCommands,
    State,
    Viewport,
    Workflows
  }

  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.State, as: AgentState

  setup do
    dir = Path.join(System.tmp_dir!(), "tackle-workflow-ui-#{System.unique_integer([:positive])}")
    cwd = Path.join(dir, "project")
    home = Path.join(dir, "home")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.mkdir_p!(Path.join(cwd, ".tackle/workflows"))
    File.mkdir_p!(Path.join(home, "workflows"))
    on_exit(fn -> File.rm_rf!(dir) end)

    state = %State{
      cwd: cwd,
      env: %{"TACKLE_HOME" => home},
      input: Input.new(),
      agent_state: AgentState.new(),
      conversation: Viewport.new_conversation(80, 24),
      workflow_editor: fn _ -> {:error, :no_editor} end
    }

    %{state: state, cwd: cwd, home: home}
  end

  test "/workflows discovers fresh project and user rows, with project precedence", %{
    state: state,
    cwd: cwd,
    home: home
  } do
    File.write!(Path.join(cwd, ".tackle/workflows/review.lua"), "-- Project review\nreturn 'ok'")
    File.write!(Path.join(home, "workflows/review.lua"), "-- Shadowed\nreturn 'old'")
    File.write!(Path.join(home, "workflows/scout.lua"), "-- User scout\nreturn 'ok'")

    {:noreply, state} = SlashCommands.dispatch(state, "/workflows")
    assert Enum.map(picker(state).items, & &1.primary) == ["review", "scout"]

    assert Enum.map(picker(state).items, & &1.secondary) == [
             "Project review [project]",
             "User scout [user]"
           ]

    File.write!(Path.join(cwd, ".tackle/workflows/new.lua"), "-- Added later")
    {:noreply, state} = Workflows.open(state)
    assert Enum.map(picker(state).items, & &1.primary) == ["new", "review", "scout"]
  end

  test "empty state explains locations and creation", %{state: state} do
    {:noreply, state} = Workflows.open(state)
    assert %Popup{content: %Paragraph{text: hint}} = Workflows.popup(state)
    assert hint =~ ".tackle/workflows"
    assert hint =~ "$TACKLE_HOME/workflows"
    assert hint =~ "ask the agent"
  end

  test "typing, paste, backspace, navigation and Esc follow picker conventions", %{
    state: state,
    cwd: cwd
  } do
    File.write!(Path.join(cwd, ".tackle/workflows/review.lua"), "-- Review changes")
    File.write!(Path.join(cwd, ".tackle/workflows/scout.lua"), "-- Inspect project")
    {:noreply, state} = Workflows.open(state)
    {:noreply, state} = Workflows.handle({:insert, "review"}, state)
    assert [%{id: "review"}] = Picker.filtered(picker(state))
    {:noreply, state} = Workflows.handle(:backspace, state)
    assert picker(state).query == "revie"
    state = Workflows.paste(state, "w\n")
    assert picker(state).query == "review "
    assert [%{id: "review"}] = Picker.filtered(picker(state))

    {:noreply, state} = Workflows.open(state)

    {:noreply, state} =
      Workflows.handle(Keybinds.workflows(%Key{code: "n", modifiers: ["ctrl"]}), state)

    assert Picker.selected(picker(state)).id == "scout"

    {:noreply, state} =
      Workflows.handle(Keybinds.workflows(%Key{code: "p", modifiers: ["ctrl"]}), state)

    assert Picker.selected(picker(state)).id == "review"
    assert Keybinds.workflows(%Key{code: "g", modifiers: ["ctrl"]}) == :external_editor
    {:noreply, state} = Workflows.handle(:close, state)
    assert state.overlay == nil
  end

  test "Enter submits the ordinary prompt and restores it on failure", %{state: state, cwd: cwd} do
    File.write!(Path.join(cwd, ".tackle/workflows/review.lua"), "return 'ok'")
    {:noreply, state} = SlashCommands.dispatch(state, "/workflows")
    {:noreply, state, commands: [_]} = Workflows.handle(:accept, state)
    prompt = ~s(Run the saved workflow "review".)
    assert state.overlay == nil
    assert state.pending_operation.kind == :submit
    assert state.pending_operation.prompt == prompt
    assert state.pending_prompt == prompt
    assert state.pending_operation.draft == Pastes.Draft.new(prompt)
    assert Input.get_value(state.input) == ""
    ref = state.pending_operation.ref

    failed =
      elem(
        RuntimeEvents.handle({:tui_operation_result, ref, :submit, {:error, :rejected}}, state),
        1
      )

    assert Pastes.draft(failed) == Pastes.Draft.new(prompt)
    Input.set_value(state.input, "")

    {:noreply, started, _} =
      RuntimeEvents.handle({:tui_operation_result, ref, :submit, {:ok, "turn-1"}}, state)

    assert Input.get_value(started.input) == ""
  end

  test "a queued picker submission restores the workflow prompt on withdrawal", %{
    state: state,
    cwd: cwd
  } do
    File.write!(Path.join(cwd, ".tackle/workflows/review.lua"), "return 'ok'")
    {:noreply, state} = SlashCommands.dispatch(state, "/workflows")
    {:noreply, state, commands: [_]} = Workflows.handle(:accept, state)
    prompt = ~s(Run the saved workflow "review".)
    ref = state.pending_operation.ref

    {:noreply, queued} =
      RuntimeEvents.handle({:tui_operation_result, ref, :submit, {:ok, :queued}}, state)

    assert queued.queued_prompts == [prompt]
    assert queued.queued_drafts == %{prompt => Pastes.Draft.new(prompt)}
    ref = make_ref()
    queued = %{queued | pending_operation: %{ref: ref, kind: :withdraw_queued, prompt: prompt}}

    {:noreply, restored, _} =
      RuntimeEvents.handle({:tui_operation_result, ref, :withdraw_queued, :ok}, queued)

    assert Pastes.draft(restored) == Pastes.Draft.new(prompt)
    assert restored.queued_prompts == []
    assert restored.queued_drafts == %{}
  end

  test "matching workflows rank ahead of creation in selection and rendering", %{
    state: state,
    cwd: cwd
  } do
    File.write!(Path.join(cwd, ".tackle/workflows/review.lua"), "-- Review changes")
    File.write!(Path.join(cwd, ".tackle/workflows/revision.lua"), "-- Revision")
    {:noreply, state} = Workflows.open(state)
    {:noreply, state} = Workflows.handle({:insert, "rev"}, state)
    matches = Picker.filter(picker(state).items, "rev")
    assert Picker.filtered(picker(state)) == matches ++ picker(state).trailing_items
    assert Picker.selected(picker(state)).id == hd(matches).id
    assert %Popup{content: %{items: rows, selected: 0}} = Workflows.popup(state)
    assert List.last(rows) =~ ~s(+ new workflow "rev")
    {:noreply, moved} = Workflows.handle(:next, state)
    {:noreply, moved} = Workflows.handle(:next, moved)
    assert Picker.selected(picker(moved)).id == {:new, "rev"}
    assert %Popup{content: %{selected: 2}} = Workflows.popup(moved)
    {:noreply, submitted, commands: [_]} = Workflows.handle(:accept, state)
    assert submitted.pending_operation.prompt == ~s(Run the saved workflow "#{hd(matches).id}".)
    refute File.exists?(Path.join(cwd, ".tackle/workflows/rev.lua"))
  end

  test "Enter refuses to run while a turn or operation is active, but keeps the overlay", %{
    state: state,
    cwd: cwd
  } do
    File.write!(Path.join(cwd, ".tackle/workflows/review.lua"), "return 'ok'")

    for busy <- [
          %{state | active_turn: %{id: "turn-1"}},
          %{state | pending_operation: %{kind: :submit}}
        ] do
      {:noreply, busy} = Workflows.open(busy)
      {:noreply, refused} = Workflows.handle(:accept, busy)
      assert refused.overlay == busy.overlay
      assert refused.notice =~ "idle"
      assert refused.pending_operation == busy.pending_operation
    end
  end

  test "Ctrl+G fetches fresh text, writes changes during a turn, and refreshes descriptions", %{
    state: state,
    cwd: cwd
  } do
    path = Path.join(cwd, ".tackle/workflows/review.lua")
    File.write!(path, "-- Old\nreturn 'old'")
    {:noreply, state} = Workflows.open(state)
    File.write!(path, "-- Fresh\nreturn 'fresh'")

    editor = fn text ->
      assert text == "-- Fresh\nreturn 'fresh'"
      {:ok, "-- New\nreturn 'new'\n"}
    end

    state = %{state | workflow_editor: editor, active_turn: %{id: "turn-1"}}
    {:noreply, state, commands: [_]} = Workflows.handle(:external_editor, state)
    assert File.read!(path) == "-- New\nreturn 'new'\n"
    assert [%{secondary: "New [project]"}] = picker(state).items
    assert state.notice == "Saved .tackle/workflows/review.lua"
    assert state.full_repaint?
    assert state.active_turn == %{id: "turn-1"}
  end

  test "unchanged edits do not write, editor failures leave the file alone", %{
    state: state,
    cwd: cwd
  } do
    path = Path.join(cwd, ".tackle/workflows/review.lua")
    File.write!(path, "-- Review")
    {:noreply, state} = Workflows.open(state)
    # Removing the original inside the fake editor proves an unchanged result
    # does not recreate it through a redundant save.
    editor = fn text ->
      File.rm!(path)
      {:ok, text}
    end

    {:noreply, unchanged, commands: [_]} =
      Workflows.handle(:external_editor, %{state | workflow_editor: editor})

    refute File.exists?(path)
    assert unchanged.notice == "Workflow unchanged"

    File.write!(path, "-- Review")

    for reason <- [:no_editor, {:exit_status, 1}, :invalid_utf8] do
      reply =
        Workflows.handle(:external_editor, %{
          state
          | workflow_editor: fn _ -> {:error, reason} end
        })

      failed = elem(reply, 1)
      assert failed.notice =~ "editor" or failed.notice =~ "Editor" or failed.notice =~ "UTF-8"
      assert failed.full_repaint? == (reason != :no_editor)
      assert File.read!(path) == "-- Review"
    end

    assert ExternalEditor.repainted?(:tui_external_editor_repainted)
  end

  test "create row is offered only for valid names not already saved", %{state: state, cwd: cwd} do
    File.write!(Path.join(cwd, ".tackle/workflows/review.lua"), "-- Review")

    for name <- [
          "",
          "UPPER",
          "has space",
          "has_underscore",
          "-leading",
          "trailing-",
          "two--hyphens",
          "review"
        ] do
      {:noreply, opened} = Workflows.open(state)
      {:noreply, queried} = Workflows.handle({:insert, name}, opened)
      refute Enum.any?(Picker.filtered(picker(queried)), &match?({:new, _}, &1.id))
    end

    {:noreply, state} = Workflows.open(state)
    {:noreply, state} = Workflows.handle({:insert, "new-review-2"}, state)
    assert [%{id: {:new, "new-review-2"}}] = Picker.filtered(picker(state))
  end

  test "creation edits a template before creating directories and writes only on success", %{
    state: state,
    cwd: cwd
  } do
    File.rm_rf!(Path.join(cwd, ".tackle"))
    {:noreply, state} = Workflows.open(state)
    {:noreply, state} = Workflows.handle({:insert, "new-review"}, state)
    path = Path.join(cwd, ".tackle/workflows/new-review.lua")
    {:noreply, failed} = Workflows.handle(:accept, state)
    refute File.exists?(Path.join(cwd, ".tackle"))
    assert failed.notice =~ "$EDITOR"

    {:noreply, failed, commands: [_]} =
      Workflows.handle(:accept, %{
        state
        | workflow_editor: fn _ -> {:error, {:exit_status, 1}} end
      })

    refute File.exists?(path)
    assert failed.notice =~ "status 1"

    editor = fn template ->
      refute File.exists?(path)
      assert template == Tackle.Workflows.template("new-review")
      {:ok, "-- My review\nreturn 'done'"}
    end

    {:noreply, created, commands: [_]} =
      Workflows.handle(:accept, %{state | workflow_editor: editor})

    assert File.read!(path) == "-- My review\nreturn 'done'"
    assert created.notice == "Created .tackle/workflows/new-review.lua"
    assert [%{id: "new-review"}] = Picker.filtered(picker(created))
  end

  test "an unchanged template creates neither the file nor directories", %{state: state, cwd: cwd} do
    File.rm_rf!(Path.join(cwd, ".tackle"))
    {:noreply, state} = Workflows.open(state)
    {:noreply, state} = Workflows.handle({:insert, "new-review"}, state)

    editor = fn template ->
      assert template == Tackle.Workflows.template("new-review")
      {:ok, template}
    end

    {:noreply, state, commands: [_]} =
      Workflows.handle(:accept, %{state | workflow_editor: editor})

    assert state.notice == "Workflow not created (template unchanged)"
    refute File.exists?(Path.join(cwd, ".tackle"))
  end

  test "creation is exclusive when the file appeared while editing", %{state: state, cwd: cwd} do
    {:noreply, state} = Workflows.open(state)
    {:noreply, state} = Workflows.handle({:insert, "racing"}, state)
    path = Path.join(cwd, ".tackle/workflows/racing.lua")

    editor = fn _ ->
      File.write!(path, "original")
      {:ok, "replacement"}
    end

    {:noreply, state, commands: [_]} =
      Workflows.handle(:accept, %{state | workflow_editor: editor})

    assert state.notice =~ "already exists"
    assert File.read!(path) == "original"
  end

  defp picker(%{overlay: {:workflows, %{picker: picker}}}), do: picker
end
