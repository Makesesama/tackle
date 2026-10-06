defmodule Tackle.CLI.TUI.TerminalTitleTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.State
  alias Tackle.CLI.TUI.TerminalTitle

  # The project segment is the working directory's basename; tests run from
  # the CLI app directory, so derive it the same way the title does.
  @project Path.basename(File.cwd!())

  defp writer do
    test_pid = self()

    fn
      nil ->
        send(test_pid, :title_cleared)
        :ok

      title ->
        send(test_pid, {:title_set, title})
        {:ok, :applied}
    end
  end

  defp state(opts \\ []) do
    %State{
      session_id: Keyword.get(opts, :session_id, "01234567-89ab-cdef-0123-456789abcdef"),
      activity: Keyword.get(opts, :activity),
      active_turn: Keyword.get(opts, :active_turn),
      pending_operation: Keyword.get(opts, :pending_operation),
      spinner_frame: Keyword.get(opts, :spinner_frame, 0),
      terminal_title: Keyword.get(opts, :terminal_title),
      terminal_title_writer: Keyword.get(opts, :writer, writer())
    }
  end

  describe "text/1" do
    test "names the session, its activity, and the project with ASCII separators" do
      assert TerminalTitle.text(state()) == "tackle | 01234567 | idle | #{@project}"
    end

    test "prefers the live activity over the turn and prefixes the spinner frame" do
      assert TerminalTitle.text(state(activity: "thinking", active_turn: %{id: "t"})) ==
               "tackle | 01234567 | ⠋ thinking | #{@project}"
    end

    test "advances the spinner with the shell's spinner frame" do
      assert TerminalTitle.text(
               state(activity: "responding", active_turn: %{id: "t"}, spinner_frame: 3)
             ) == "tackle | 01234567 | ⠸ responding | #{@project}"
    end

    test "falls back to working while a turn is active without finer state" do
      assert TerminalTitle.text(state(active_turn: %{id: "t"})) ==
               "tackle | 01234567 | ⠋ working | #{@project}"
    end

    test "idle wins over a stale activity label once no turn or operation runs" do
      assert TerminalTitle.text(state(activity: "turn end")) ==
               "tackle | 01234567 | idle | #{@project}"
    end

    test "labels shell operations that run between turns" do
      for {kind, label} <- [
            {:submit, "starting"},
            {:cancel, "cancelling"},
            {:compact, "compacting"},
            {:navigate, "working"}
          ] do
        assert TerminalTitle.text(state(pending_operation: %{kind: kind})) ==
                 "tackle | 01234567 | ⠋ #{label} | #{@project}"
      end
    end

    test "omits a missing session id" do
      assert TerminalTitle.text(state(session_id: nil)) == "tackle | idle | #{@project}"
    end
  end

  describe "truncate_part/2" do
    test "keeps short values unchanged" do
      assert TerminalTitle.truncate_part("my-project", 24) == "my-project"
    end

    test "marks the cut with an ellipsis when there is room for it" do
      assert TerminalTitle.truncate_part("a-really-long-project-name", 24) ==
               "a-really-long-project..."
    end

    test "cuts without an ellipsis when too few characters remain" do
      assert TerminalTitle.truncate_part("abcdef", 3) == "abc"
      assert TerminalTitle.truncate_part("abcdef", 0) == ""
    end
  end

  describe "refresh/1" do
    test "writes the title when it changed and caches it" do
      refreshed = TerminalTitle.refresh(state())

      assert_receive {:title_set, "tackle | 01234567 | idle | #{@project}"}
      assert refreshed.terminal_title == "tackle | 01234567 | idle | #{@project}"
    end

    test "skips the write when the title is unchanged" do
      title = "tackle | 01234567 | idle | #{@project}"
      refreshed = TerminalTitle.refresh(state(terminal_title: title))

      refute_receive {:title_set, _title}
      assert refreshed.terminal_title == title
    end

    test "clears the managed title when sanitization removes all content" do
      test_pid = self()

      state(
        terminal_title: "tackle | old | idle",
        writer: fn
          nil ->
            send(test_pid, :title_cleared)
            :ok

          _title ->
            {:ok, :no_visible_content}
        end
      )
      |> TerminalTitle.refresh()

      assert_receive :title_cleared
    end

    test "keeps the cache on a failed write so the next transition retries it" do
      refreshed =
        state(
          terminal_title: "tackle | 01234567 | idle | #{@project}",
          writer: fn _title -> {:error, :closed} end
        )
        |> TerminalTitle.refresh()

      refute_receive {:title_set, _title}
      assert refreshed.terminal_title == "tackle | 01234567 | idle | #{@project}"
    end
  end

  describe "clear/1" do
    test "is a no-op when no title was written" do
      assert TerminalTitle.clear(state()) == state()
      refute_receive :title_cleared
    end

    test "clears a written title once" do
      cleared =
        TerminalTitle.clear(state(terminal_title: "tackle | 01234567 | idle | #{@project}"))

      assert_receive :title_cleared
      assert cleared.terminal_title == nil

      TerminalTitle.clear(cleared)
      refute_receive :title_cleared
    end

    test "keeps the cache on a failed clear" do
      state =
        state(
          terminal_title: "tackle | 01234567 | idle | #{@project}",
          writer: fn
            nil -> {:error, :closed}
            _title -> {:ok, :applied}
          end
        )

      assert TerminalTitle.clear(state).terminal_title ==
               "tackle | 01234567 | idle | #{@project}"
    end
  end
end
