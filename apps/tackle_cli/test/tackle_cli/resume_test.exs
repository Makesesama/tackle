defmodule Tackle.CLI.ResumeTest do
  @moduledoc "The fullscreen `/resume` saved-session picker."

  use ExUnit.Case, async: true

  alias ExRatatui.Command
  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.Line
  alias ExRatatui.Widgets.{Clear, Paragraph}
  alias Tackle.CLI.Keybinds
  alias Tackle.CLI.TUI.{Composer, Resume, Session, Viewport}
  alias Tackle.CLI.TUI.State, as: TuiState
  alias Tackle.CLI.Widgets.{Input, ResumeScreen}
  alias Tackle.Lib.State, as: AgentState

  defp base_state(opts) do
    input = Input.new()
    :ok = Input.set_value(input, Keyword.get(opts, :draft, ""))

    state = %TuiState{
      input: input,
      size: {80, 24},
      conversation: Viewport.new_conversation(80, 24),
      agent_state: Keyword.get(opts, :agent_state, AgentState.new()),
      agent_ref: :agent_ref,
      session_id: "session-1",
      list_recent_sessions:
        Keyword.get(opts, :list_recent_sessions, fn _cursor -> {:ok, page([])} end),
      resume_session: Keyword.get(opts, :resume_session),
      inspect_session: Keyword.get(opts, :inspect_session),
      recent_sessions: Keyword.get(opts, :recent_sessions, [])
    }

    Viewport.update_draft(state)
  end

  defp page(sessions, cursor \\ nil), do: %{sessions: sessions, next_cursor: cursor}

  defp saved_sessions do
    [
      %{
        session_id: "session-1",
        title: "Current session",
        preview: nil,
        cwd: "/home/me/project",
        created_at: nil,
        updated_at: nil
      },
      %{
        session_id: "session-2",
        title: nil,
        preview: "fix the flaky test\nand rerun",
        cwd: "/home/me/project",
        created_at: nil,
        updated_at: iso_hours_ago(3)
      }
    ]
  end

  defp iso_hours_ago(hours) do
    DateTime.utc_now() |> DateTime.add(-hours * 3600) |> DateTime.to_iso8601()
  end

  defp opened(state) do
    assert {:noreply, %{overlay: {:resume, resume}} = state, commands: [command]} =
             Resume.open(state)

    assert %Command{kind: :async} = command
    {state, resume}
  end

  defp load_ref(%{overlay: {:resume, resume}}), do: resume.load_ref

  defp move(state, times) do
    Enum.reduce(1..times, state, fn _, acc ->
      assert {:noreply, acc, _commands} = Resume.handle(:next, acc)
      acc
    end)
  end

  # -- slash command ---------------------------------------------------------

  test "/resume opens the fullscreen picker and loads the first page" do
    state =
      base_state(
        draft: "/resume",
        recent_sessions: saved_sessions(),
        resume_session: fn _id -> {:error, :unused} end
      )

    assert {:noreply, %{overlay: {:resume, _}}, commands: [%Command{}]} = Composer.submit(state)
    assert Input.get_value(state.input) == ""
  end

  test "/resume while busy keeps the draft and does not open" do
    state =
      base_state(
        draft: "/resume",
        recent_sessions: saved_sessions(),
        resume_session: fn _id -> {:error, :unused} end
      )

    state = %{state | pending_operation: %{ref: make_ref(), kind: :compact}}

    assert {:noreply, %{overlay: nil, notice: notice}} = Composer.submit(state)
    assert notice =~ "Busy"
    assert Input.get_value(state.input) == "/resume"
  end

  test "/resume without a resume hook reports the frontend limitation" do
    state = base_state(draft: "/resume", recent_sessions: saved_sessions())

    assert {:noreply, %{overlay: nil, notice: notice}} = Composer.submit(state)
    assert notice =~ "unavailable"
    assert Input.get_value(state.input) == "/resume"
  end

  # -- pages -----------------------------------------------------------------

  test "the first page replaces the seed and records the cursor" do
    state =
      base_state(
        recent_sessions: saved_sessions(),
        resume_session: fn _id -> {:error, :unused} end
      )

    {state, resume} = opened(state)
    assert resume.loading?

    assert {:noreply, %{overlay: {:resume, resume}}, commands: commands} =
             Resume.apply_page_result(
               state,
               load_ref(state),
               :first,
               {:ok, page([List.last(saved_sessions())], "cursor-1")}
             )

    refute resume.loading?
    assert resume.cursor == "cursor-1"
    assert [%{id: "session-2"}] = resume.picker.items
    # A single-session result is small, so the picker prefetches the next page.
    assert [%Command{kind: :async}] = commands
  end

  test "a later page appends without duplicating loaded sessions" do
    state =
      base_state(
        recent_sessions: saved_sessions(),
        resume_session: fn _id -> {:error, :unused} end
      )

    {state, _} = opened(state)

    assert {:noreply, state, commands: _} =
             Resume.apply_page_result(
               state,
               load_ref(state),
               :first,
               {:ok, page(saved_sessions(), "cursor-1")}
             )

    assert {:noreply, %{overlay: {:resume, resume}}} =
             Resume.apply_page_result(
               state,
               load_ref(state),
               :more,
               {:ok,
                page([
                  %{session_id: "session-2", title: "Updated"},
                  %{session_id: "session-3"}
                ])}
             )

    ids = Enum.map(resume.picker.items, & &1.id)

    # The current session is never offered, and the repeated session-2 from
    # the second page does not appear twice.
    assert ids == ["session-2", "session-3"]
    assert resume.cursor == nil
  end

  test "a failed page load reports inline without closing the picker" do
    state =
      base_state(recent_sessions: [], resume_session: fn _id -> {:error, :unused} end)

    {state, _} = opened(state)

    assert {:noreply, %{overlay: {:resume, resume}}} =
             Resume.apply_page_result(state, load_ref(state), :first, {:error, :no_sessions})

    assert resume.error =~ "no_sessions"
    refute resume.loading?
  end

  test "stale page results for a closed picker are ignored" do
    state =
      base_state(recent_sessions: [], resume_session: fn _id -> {:error, :unused} end)

    {state, _} = opened(state)
    state = %{state | overlay: nil}

    assert {:noreply, ^state, render?: false} =
             Resume.apply_page_result(state, make_ref(), :first, {:ok, page([])})
  end

  test "moving near the end of the loaded rows loads the next page" do
    sessions = for index <- 1..10, do: %{session_id: "s-#{index}", title: "Session #{index}"}

    state =
      base_state(
        recent_sessions: sessions,
        resume_session: fn _id -> {:error, :unused} end
      )

    {state, _} = opened(state)

    assert {:noreply, state} =
             Resume.apply_page_result(
               state,
               load_ref(state),
               :first,
               {:ok, page(sessions, "cursor-1")}
             )

    # Ten rows loaded; the seventh move enters the load threshold.
    state = move(state, 6)

    assert {:noreply, _state, commands: [command]} = Resume.handle(:next, state)
    assert %Command{kind: :async} = command
  end

  # -- selection and scrolling -------------------------------------------------

  test "the window follows the selection and reports continued content" do
    sessions = for index <- 1..30, do: %{session_id: "s-#{index}", title: "Session #{index}"}

    state =
      base_state(
        recent_sessions: sessions,
        resume_session: fn _id -> {:error, :unused} end
      )

    {state, _} = opened(state)

    assert {:noreply, state} =
             Resume.apply_page_result(state, load_ref(state), :first, {:ok, page(sessions)})

    state = move(state, 12)
    %{overlay: {:resume, resume}} = state
    assert resume.picker.selected == 12
    assert resume.scroll_top > 0

    screen = Resume.popup(state)
    assert screen.selected == 12
    assert screen.scroll_top == resume.scroll_top

    height = ResumeScreen.list_height({80, 24})
    win = ResumeScreen.window(screen.rows, screen.scroll_top, screen.selected, height)
    assert win.more_above?
    assert win.more_below?
    assert Enum.any?(win.visible, &(&1.id == "s-13"))
  end

  test "walking to the last row never loses the selection" do
    sessions = for index <- 1..30, do: %{session_id: "s-#{index}", title: "Session #{index}"}

    state =
      base_state(
        recent_sessions: sessions,
        resume_session: fn _id -> {:error, :unused} end
      )

    {state, _} = opened(state)

    assert {:noreply, state} =
             Resume.apply_page_result(state, load_ref(state), :first, {:ok, page(sessions)})

    # Pressing next through the whole list must keep the selected row inside
    # the window at every step, including the boundary rows where the window
    # scrolls and the bottom indicator claims a line.
    height = ResumeScreen.list_height({80, 24})

    {state, lost} =
      Enum.reduce(1..29, {state, []}, fn step, {state, lost} ->
        assert {:noreply, state, _commands} = Resume.handle(:next, state)
        screen = Resume.popup(state)

        win = ResumeScreen.window(screen.rows, screen.scroll_top, screen.selected, height)

        visible? = Enum.any?(win.visible, &(&1.id == "s-#{screen.selected + 1}"))
        {state, if(visible?, do: lost, else: [step | lost])}
      end)

    assert lost == []
    %{overlay: {:resume, resume}} = state
    assert resume.picker.selected == 29
  end

  test "a row taller than the window starts the window at the selection" do
    rows =
      for index <- 1..30 do
        %{id: "s-#{index}", title: "t", meta: "m", preview: nil, expanded?: false}
      end

    rows =
      List.update_at(rows, 29, fn row ->
        %{row | expanded?: true, preview: {:ok, for(_ <- 1..6, do: %{speaker: :user, text: "x"})}}
      end)

    height = ResumeScreen.list_height({80, 10})
    win = ResumeScreen.window(rows, 0, 29, height)

    assert win.scroll_top == 29
    assert Enum.any?(win.visible, &(&1.id == "s-30"))
  end

  test "an exactly full window scrolls instead of swapping its last row" do
    # A terminal whose list height is an exact multiple of the row height
    # leaves no spare line for the bottom indicator; the window must scroll
    # by one row rather than deleting a row above the selection.
    rows =
      for index <- 1..12 do
        %{id: "s-#{index}", title: "t", meta: "m", preview: nil, expanded?: false}
      end

    height = ResumeScreen.list_height({80, 22})
    assert rem(height, 3) == 0

    {top, visible} =
      Enum.reduce(0..11, {0, []}, fn selected, {top, _} ->
        win = ResumeScreen.window(rows, top, selected, height)

        ids =
          Enum.map(win.visible, &(String.replace_prefix(&1.id, "s-", "") |> String.to_integer()))

        # The window is contiguous and contains the selection.
        assert ids == Enum.to_list(Enum.at(ids, 0)..List.last(ids))
        assert (selected + 1) in ids

        {win.scroll_top, ids}
      end)

    # The last window holds four of the twelve rows.
    assert top == 8
  end

  test "esc clears an active query first and closes on the second press" do
    state =
      base_state(
        recent_sessions: saved_sessions(),
        resume_session: fn _id -> {:error, :unused} end
      )

    {state, _} = opened(state)
    state = Resume.paste(state, "flaky")

    assert {:noreply, state} = Resume.handle(:cancel, state)
    %{overlay: {:resume, resume}} = state
    assert resume.picker.query == ""

    assert {:noreply, %{overlay: nil}} = Resume.handle(:cancel, state)
  end

  # -- expansion and previews ---------------------------------------------------

  test "expanding the selection loads and installs the transcript preview" do
    state =
      base_state(
        recent_sessions: saved_sessions(),
        resume_session: fn _id -> {:error, :unused} end,
        inspect_session: fn "session-2" -> {:ok, %{messages: inspected_messages()}} end
      )

    {state, _} = opened(state)
    state = move(state, 1)

    assert {:noreply, state, commands: [%Command{kind: :async}]} = Resume.handle(:expand, state)
    %{overlay: {:resume, resume}} = state

    assert resume.expanded == "session-2"
    assert resume.previews["session-2"] == :loading

    assert {:noreply, state} =
             Resume.apply_preview_result(
               state,
               resume.preview_ref,
               "session-2",
               {:ok, %{messages: inspected_messages()}}
             )

    %{overlay: {:resume, resume}} = state
    assert {:ok, turns} = resume.previews["session-2"]

    assert [
             %{speaker: :user, text: "fix the flaky test"},
             %{speaker: :assistant, text: "rerunning"},
             %{speaker: :user, text: "later turn"}
           ] = turns

    screen = Resume.popup(state)
    expanded = Enum.find(screen.rows, & &1.expanded?)
    assert expanded.id == "session-2"
    assert {:ok, ^turns} = expanded.preview

    # Expanding again collapses the row.
    assert {:noreply, %{overlay: {:resume, resume}}} = Resume.handle(:expand, state)
    assert resume.expanded == nil
  end

  test "expanding without an inspector marks the preview unavailable" do
    state =
      base_state(
        recent_sessions: saved_sessions(),
        resume_session: fn _id -> {:error, :unused} end
      )

    {state, _} = opened(state)

    assert {:noreply, %{overlay: {:resume, resume}}} = Resume.handle(:expand, state)
    assert resume.expanded == "session-1"
    assert resume.previews["session-1"] == {:error, :no_inspector}
  end

  # -- accepting ---------------------------------------------------------------

  test "accept resumes the selected session through the frontend hook" do
    state =
      base_state(
        recent_sessions: saved_sessions(),
        resume_session: fn id ->
          send(self(), {:resume_requested, id})
          {:error, "cannot adopt"}
        end
      )

    {state, _} = opened(state)
    state = move(state, 1)

    assert {:noreply, %{overlay: nil, error: error}} = Resume.handle(:accept, state)
    assert error =~ "cannot adopt"
    assert_received {:resume_requested, "session-2"}
  end

  test "a crashing resume hook is reported without taking down the shell" do
    state =
      base_state(
        recent_sessions: saved_sessions(),
        resume_session: fn _id -> raise "boom" end
      )

    {state, _} = opened(state)

    assert {:noreply, %{overlay: nil, error: error}} = Resume.handle(:accept, state)
    assert error =~ "resume_session_failed"
  end

  test "resume_by_id reports a frontend refusal and keeps the session" do
    state = base_state(resume_session: fn _id -> {:error, :no_sessions} end)

    assert {:noreply, %{overlay: nil, error: error}} = Session.resume_by_id(state, "gone")
    assert error =~ "no_sessions"
  end

  # -- rows and rendering --------------------------------------------------------

  test "rows show the title or preview, the age, and the working directory" do
    items = Resume.items(saved_sessions())

    assert [%{id: "session-1"}, %{id: "session-2"}] = items
    assert [%{primary: "Current session", secondary: "/home/me/project"}] = [hd(items)]

    second = Enum.at(items, 1)
    assert second.primary == "fix the flaky test"
    assert second.secondary =~ "3h ago"
    assert second.secondary =~ "/home/me/project"
    assert second.search =~ "session-2"
  end

  test "a session older than a week shows its calendar date" do
    old = DateTime.utc_now() |> DateTime.add(-30 * 86_400) |> DateTime.to_iso8601()

    assert [%{secondary: secondary}] =
             Resume.items([%{session_id: "s", title: "t", cwd: "/w", updated_at: old}])

    {:ok, at, _offset} = DateTime.from_iso8601(old)
    assert secondary =~ Calendar.strftime(at, "%b %d")
  end

  test "an unparseable timestamp falls back to the directory alone" do
    assert [%{secondary: secondary}] =
             Resume.items([%{session_id: "s", title: "t", cwd: "/w", updated_at: "not a date"}])

    assert secondary == "/w"
  end

  test "the screen renders fullscreen chrome: header, search, list, footer" do
    state =
      base_state(
        recent_sessions: saved_sessions(),
        resume_session: fn _id -> {:error, :unused} end
      )

    {state, _} = opened(state)
    screen = Resume.popup(state)
    placements = ResumeScreen.render(screen, %Rect{x: 0, y: 0, width: 80, height: 24})

    assert {%Clear{}, %Rect{width: 80, height: 24}} = List.first(placements)

    texts =
      placements
      |> Enum.filter(fn {widget, _rect} -> match?(%Paragraph{}, widget) end)
      |> Enum.map(fn {widget, _rect} -> widget.text end)

    assert Enum.any?(texts, &contains?(&1, "Resume a previous session"))
    assert Enum.any?(texts, &contains?(&1, "Type to search"))
    assert Enum.any?(texts, &contains?(&1, "resume"))
    assert Enum.any?(texts, &contains?(&1, "1 / 2"))
  end

  test "the screen shows the empty state while the first page loads" do
    state =
      base_state(recent_sessions: [], resume_session: fn _id -> {:error, :unused} end)

    {state, _} = opened(state)
    screen = Resume.popup(state)
    assert screen.loading?
    refute screen.error

    placements = ResumeScreen.render(screen, %Rect{x: 0, y: 0, width: 80, height: 24})

    assert Enum.any?(placements, fn {widget, _} ->
             contains_paragraph(widget, "Loading sessions…")
           end)
  end

  # -- keybinds -------------------------------------------------------------------

  test "the resume keybinds resolve picker intents" do
    assert Keybinds.resume(%Key{code: "esc", modifiers: []}) == :cancel
    assert Keybinds.resume(%Key{code: "up", modifiers: []}) == :previous
    assert Keybinds.resume(%Key{code: "down", modifiers: []}) == :next
    assert Keybinds.resume(%Key{code: "p", modifiers: ["ctrl"]}) == :previous
    assert Keybinds.resume(%Key{code: "n", modifiers: ["ctrl"]}) == :next
    assert Keybinds.resume(%Key{code: "page_down", modifiers: []}) == :page_down
    assert Keybinds.resume(%Key{code: "enter", modifiers: []}) == :accept
    assert Keybinds.resume(%Key{code: "backspace", modifiers: []}) == :backspace
    assert Keybinds.resume(%Key{code: "right", modifiers: []}) == :expand
    assert Keybinds.resume(%Key{code: "left", modifiers: []}) == :collapse
    assert Keybinds.resume(%Key{code: "e", modifiers: ["ctrl"]}) == :expand
    assert Keybinds.resume(%Key{code: "f", modifiers: []}) == {:insert, "f"}
    assert Keybinds.resume(%Key{code: "c", modifiers: ["ctrl"]}) == :ignore
  end

  # -- helpers ----------------------------------------------------------------------

  defp inspected_messages do
    [
      %{"role" => "user", "content" => "fix the flaky test"},
      %{"role" => "assistant", "content" => "rerunning\nwith a seed"},
      %{"role" => "tool", "content" => "ignored"},
      %{"role" => "user", "content" => "later turn"}
    ]
  end

  defp contains?(lines, needle) when is_list(lines) do
    Enum.any?(lines, fn
      %Line{spans: spans} -> Enum.any?(spans, &String.contains?(&1.content, needle))
      text when is_binary(text) -> String.contains?(text, needle)
      _other -> false
    end)
  end

  defp contains?(text, needle) when is_binary(text), do: String.contains?(text, needle)

  defp contains_paragraph(%Paragraph{} = widget, needle), do: contains?(widget.text, needle)
  defp contains_paragraph(_widget, _needle), do: false
end
