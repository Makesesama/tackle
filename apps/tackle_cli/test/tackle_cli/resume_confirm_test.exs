defmodule Tackle.CLI.ResumeConfirmTest do
  @moduledoc "The expired-cache prompt before resuming, and archiving from `/resume`."

  use ExUnit.Case, async: true

  alias ExRatatui.Command
  alias ExRatatui.Event.Key
  alias Tackle.CLI.Keybinds
  alias Tackle.CLI.Test.AgentStates
  alias Tackle.CLI.TUI.{Resume, ResumeConfirm, Session, Viewport}
  alias Tackle.CLI.TUI.State, as: TuiState
  alias Tackle.CLI.Widgets.{Input, ResumeScreen}
  alias Tackle.Lib.{Message, ModelInfo}
  alias Tackle.Lib.State, as: AgentState

  defp base_state(opts) do
    input = Input.new()

    state = %TuiState{
      input: input,
      size: {80, 24},
      conversation: Viewport.new_conversation(80, 24),
      agent_state: Keyword.get(opts, :agent_state, AgentState.new()),
      agent_ref: :agent_ref,
      session_id: "current",
      list_recent_sessions:
        Keyword.get(opts, :list_recent_sessions, fn _cursor -> {:ok, page([])} end),
      list_archived_sessions: Keyword.get(opts, :list_archived_sessions),
      resume_session: Keyword.get(opts, :resume_session, &refuse_resume/1),
      inspect_session: Keyword.get(opts, :inspect_session),
      archive_session: Keyword.get(opts, :archive_session),
      unarchive_session: Keyword.get(opts, :unarchive_session),
      new_session: Keyword.get(opts, :new_session),
      recent_sessions: Keyword.get(opts, :recent_sessions, [])
    }

    Viewport.update_draft(state)
  end

  # Resuming always fails here, so the test can observe the attempt without
  # adopting a real scope.
  defp refuse_resume(id) do
    send(self(), {:resume_requested, id})
    {:error, :refused_in_test}
  end

  defp page(sessions, cursor \\ nil), do: %{sessions: sessions, next_cursor: cursor}

  defp session(id, opts) do
    %{
      session_id: id,
      title: Keyword.get(opts, :title, "Session #{id}"),
      preview: nil,
      cwd: "/home/me/project",
      model: Keyword.get(opts, :model),
      message_count: Keyword.get(opts, :message_count, 12),
      context_tokens: Keyword.get(opts, :context_tokens),
      archived: Keyword.get(opts, :archived, false),
      created_at: nil,
      updated_at: Keyword.get_lazy(opts, :updated_at, fn -> hours_ago(0) end)
    }
  end

  defp hours_ago(hours) do
    DateTime.utc_now() |> DateTime.add(-hours * 3600) |> DateTime.to_iso8601()
  end

  defp opened(state) do
    assert {:noreply, %{overlay: {:resume, _}} = state, commands: [_load]} = Resume.open(state)
    state
  end

  defp key(code, modifiers \\ []), do: %Key{code: code, modifiers: modifiers, kind: "press"}

  # -- when to ask ---------------------------------------------------------------

  test "only stale sessions with a non-negligible or unknown context ask" do
    now = DateTime.utc_now()
    refute ResumeConfirm.confirm?(session("a", context_tokens: 500_000), now)

    assert ResumeConfirm.confirm?(
             session("b", updated_at: hours_ago(2), context_tokens: 50_000),
             now
           )

    refute ResumeConfirm.confirm?(
             session("c", updated_at: hours_ago(2), context_tokens: 2_000),
             now
           )

    assert ResumeConfirm.confirm?(session("d", updated_at: hours_ago(2)), now)
    assert ResumeConfirm.confirm?(session("e", updated_at: nil), now)
  end

  test "a fresh session resumes from the picker without asking" do
    state = base_state(recent_sessions: [session("fresh", context_tokens: 90_000)]) |> opened()

    assert {:noreply, %{overlay: nil, error: error}} = Resume.handle(:accept, state)
    assert error =~ "refused_in_test"
    assert_received {:resume_requested, "fresh"}
  end

  test "a stale session asks first; cancelling returns to the picker" do
    stale = session("stale", updated_at: hours_ago(30), context_tokens: 183_000)
    state = base_state(recent_sessions: [stale]) |> opened()
    {:resume, picker} = state.overlay

    assert {:noreply, %{overlay: {:confirm_resume, confirm}} = asking} =
             Resume.handle(:accept, state)

    assert confirm.session.session_id == "stale"
    refute_received {:resume_requested, _}

    text = ResumeConfirm.text(asking)
    assert text =~ ~s(Resume "Session stale"?)
    assert text =~ "last active 30h ago"
    assert text =~ "12 messages"
    assert text =~ "≈ 183k tokens of context"
    assert text =~ "prompt cache has likely expired"

    assert {:noreply, %{overlay: {:resume, ^picker}}} =
             ResumeConfirm.handle(Keybinds.confirm(key("esc")), asking)

    assert {:noreply, %{overlay: nil, error: _}} =
             ResumeConfirm.handle(Keybinds.confirm(key("y")), asking)

    assert_received {:resume_requested, "stale"}
  end

  test "a recent-session shortcut asks for a stale session too" do
    stale = session("old", updated_at: hours_ago(5), context_tokens: 40_000)
    state = %{base_state(recent_sessions: [stale]) | draft_empty?: true}

    assert {:noreply, %{overlay: {:confirm_resume, %{return: nil}}}} =
             Session.resume_recent(state, 1)

    refute_received {:resume_requested, _}
  end

  test "an unknown context size is estimated through the inspector" do
    stale = session("unknown", updated_at: hours_ago(3))
    inspector = fn id -> {:ok, %{session_id: id, metadata: %{context_tokens: 64_000}}} end
    state = base_state(recent_sessions: [stale], inspect_session: inspector) |> opened()

    assert {:noreply, %{overlay: {:confirm_resume, confirm}} = asking, commands: [command]} =
             Resume.handle(:accept, state)

    assert confirm.context_tokens == :loading
    assert %Command{kind: :async} = command
    assert ResumeConfirm.text(asking) =~ "estimating context…"

    ref = confirm.estimate_ref
    result = inspector.("unknown")

    # A stale reply is ignored.
    assert {:noreply, ^asking, render?: false} =
             ResumeConfirm.apply_estimate(asking, make_ref(), "unknown", result)

    assert {:noreply, %{overlay: {:confirm_resume, %{context_tokens: 64_000}}} = estimated} =
             ResumeConfirm.apply_estimate(asking, ref, "unknown", result)

    assert ResumeConfirm.text(estimated) =~ "≈ 64k tokens of context"

    assert {:noreply, %{overlay: {:confirm_resume, %{context_tokens: nil}}} = failed} =
             ResumeConfirm.apply_estimate(asking, ref, "unknown", {:error, :gone})

    assert ResumeConfirm.text(failed) =~ "context size unknown"
  end

  test "the prompt prices uncached input with the current model's price card" do
    pricing = %{
      input: 2.0,
      output: 8.0,
      cache_read: 0.2,
      cache_write: 2.5,
      currency: "USD",
      unit_tokens: 1_000_000
    }

    agent_state = %{
      AgentState.new()
      | llm: %{ref: "provider/model", model_info: %ModelInfo{model: "model", pricing: pricing}}
    }

    priced = session("priced", updated_at: hours_ago(2), context_tokens: 250_000)

    state =
      base_state(agent_state: agent_state, recent_sessions: [%{priced | model: "provider/model"}])
      |> opened()

    {:noreply, asking} = Resume.handle(:accept, state)

    assert ResumeConfirm.text(asking) =~ "Uncached input: ≈ $0.50."

    other = %{priced | model: "other/model"}

    state =
      base_state(agent_state: agent_state, recent_sessions: [other])
      |> opened()

    {:noreply, asking} = Resume.handle(:accept, state)
    refute ResumeConfirm.text(asking) =~ "Uncached input"
  end

  test "confirming an archived session restores it before resuming" do
    archived = session("gone", updated_at: hours_ago(48), context_tokens: 20_000, archived: true)

    unarchive = fn id ->
      send(self(), {:unarchive_requested, id})
      :ok
    end

    state = base_state(recent_sessions: [archived], unarchive_session: unarchive) |> opened()
    {:noreply, asking} = Resume.handle(:accept, state)
    assert ResumeConfirm.text(asking) =~ ~s(Restore and resume "Session gone"?)

    assert {:noreply, %{overlay: nil}, _opts} = ResumeConfirm.handle(:confirm, asking)
    assert_received {:unarchive_requested, "gone"}
    assert_received {:resume_requested, "gone"}
  end

  test "a failed restore does not resume" do
    archived = session("stuck", archived: true)
    unarchive = fn _id -> {:error, {:session_exists, "stuck"}} end
    state = base_state(recent_sessions: [archived], unarchive_session: unarchive) |> opened()

    assert {:noreply, %{overlay: nil, error: error}} = Resume.handle(:accept, state)
    assert error =~ "unarchive_failed"
    refute_received {:resume_requested, _}
  end

  # -- archiving from the picker ---------------------------------------------------

  test "picker keys map to archive and the archived view" do
    assert Keybinds.resume(key("a", ["ctrl"])) == :archive
    assert Keybinds.resume(key("tab")) == :toggle_view
    assert Keybinds.resume(key("a")) == {:insert, "a"}
  end

  test "Ctrl+A archives the selected session and drops it from the list" do
    sessions = [session("one", []), session("two", [])]

    archive = fn id ->
      send(self(), {:archive_requested, id})
      :ok
    end

    state = base_state(recent_sessions: sessions, archive_session: archive) |> opened()

    assert {:noreply, %{overlay: {:resume, resume}, notice: "Archived session"}, commands: _} =
             Resume.handle(:archive, state)

    assert_received {:archive_requested, "one"}
    assert Enum.map(resume.sessions, & &1.session_id) == ["two"]
  end

  test "a refused archive is reported in the picker" do
    archive = fn _id -> {:error, {:session_in_use, %{"pid" => "42"}}} end
    state = base_state(recent_sessions: [session("busy", [])], archive_session: archive)
    state = opened(state)

    assert {:noreply, %{overlay: {:resume, resume}}} = Resume.handle(:archive, state)
    assert resume.error == "Could not archive: the session is open in another Tackle process"
    assert [%{session_id: "busy"}] = resume.sessions
  end

  test "an archive hook that exits is reported instead of crashing the shell" do
    archive = fn _id -> exit(:catalog_down) end
    state = base_state(recent_sessions: [session("one", [])], archive_session: archive)
    state = opened(state)

    assert {:noreply, %{overlay: {:resume, resume}}} = Resume.handle(:archive, state)
    assert resume.error =~ "catalog_down"
  end

  test "Tab lists archived sessions, where Ctrl+A restores" do
    archived = [session("old", archived: true)]

    unarchive = fn id ->
      send(self(), {:unarchive_requested, id})
      :ok
    end

    state =
      base_state(
        recent_sessions: [session("active", [])],
        list_archived_sessions: fn _cursor -> {:ok, page(archived)} end,
        unarchive_session: unarchive
      )
      |> opened()

    assert {:noreply, %{overlay: {:resume, resume}} = state, commands: [_load]} =
             Resume.handle(:toggle_view, state)

    assert resume.view == :archived
    assert resume.sessions == []

    {:noreply, state} =
      Resume.apply_page_result(state, resume.load_ref, :first, {:ok, page(archived)})

    screen = Resume.popup(state)
    assert %ResumeScreen{archived?: true, rows: [%{id: "old"}]} = screen

    assert {:noreply, %{overlay: {:resume, resume}, notice: "Restored session"}, commands: _} =
             Resume.handle(:archive, state)

    assert_received {:unarchive_requested, "old"}
    assert resume.sessions == []

    assert {:noreply, %{overlay: {:resume, %{view: :active}}}, commands: [_load]} =
             Resume.handle(:toggle_view, state)
  end

  test "Tab without an archive listing explains why" do
    state = base_state(recent_sessions: [session("a", [])]) |> opened()

    assert {:noreply, %{notice: notice, overlay: {:resume, %{view: :active}}}} =
             Resume.handle(:toggle_view, state)

    assert notice =~ "unavailable"
  end

  # -- /archive --------------------------------------------------------------------

  test "/archive asks only when there is history and the frontend can archive" do
    hooks = [new_session: fn _ -> {:error, :unused} end, archive_session: fn _ -> :ok end]

    assert {:noreply, %{notice: "Nothing to archive yet", overlay: nil}} =
             Session.request_archive(base_state(hooks))

    with_history = AgentStates.with_messages([Message.user("hi")])

    assert {:noreply, %{notice: notice, overlay: nil}} =
             Session.request_archive(base_state(agent_state: with_history))

    assert notice =~ "unavailable"

    assert {:noreply, %{overlay: {:confirm_archive, %{session_id: "current"}}}} =
             Session.request_archive(base_state([agent_state: with_history] ++ hooks))
  end

  test "/archive keeps the session when a new one cannot start" do
    state =
      base_state(
        new_session: fn _ -> {:error, :no_provider} end,
        archive_session: fn id -> send(self(), {:archive_requested, id}) end
      )

    state = %{state | overlay: {:confirm_archive, %{session_id: "current", title: nil}}}

    assert {:noreply, %{session_id: "current", overlay: nil, error: error}} =
             Session.archive_current(state)

    assert error =~ "no_provider"
    refute_received {:archive_requested, _}
  end
end
