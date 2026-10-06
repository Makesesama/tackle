defmodule Tackle.CLI.TUI.TerminalTitleTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.State
  alias Tackle.CLI.TUI.TerminalTitle

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
      terminal_title: Keyword.get(opts, :terminal_title),
      terminal_title_writer: Keyword.get(opts, :writer, writer())
    }
  end

  describe "text/1" do
    test "names the session and its activity" do
      assert TerminalTitle.text(state()) == "tackle · 01234567 · idle"
    end

    test "prefers the live activity over the turn" do
      assert TerminalTitle.text(state(activity: "thinking", active_turn: %{id: "t"})) ==
               "tackle · 01234567 · thinking"
    end

    test "falls back to working while a turn is active without finer state" do
      assert TerminalTitle.text(state(active_turn: %{id: "t"})) == "tackle · 01234567 · working"
    end

    test "omits a missing session id" do
      assert TerminalTitle.text(state(session_id: nil)) == "tackle · idle"
    end
  end

  describe "refresh/1" do
    test "writes the title when it changed and caches it" do
      refreshed = TerminalTitle.refresh(state())

      assert_receive {:title_set, "tackle · 01234567 · idle"}
      assert refreshed.terminal_title == "tackle · 01234567 · idle"
    end

    test "skips the write when the title is unchanged" do
      title = "tackle · 01234567 · idle"
      refreshed = TerminalTitle.refresh(state(terminal_title: title))

      refute_receive {:title_set, _title}
      assert refreshed.terminal_title == title
    end

    test "clears the managed title when sanitization removes all content" do
      test_pid = self()

      state(
        terminal_title: "tackle · old · idle",
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

    test "keeps the cache on a failed write so the next transition retries" do
      refreshed =
        state(
          terminal_title: "tackle · 01234567 · idle",
          writer: fn _title -> {:error, :closed} end
        )
        |> TerminalTitle.refresh()

      refute_receive {:title_set, _title}
      assert refreshed.terminal_title == "tackle · 01234567 · idle"
    end
  end

  describe "clear/1" do
    test "is a no-op when no title was written" do
      assert TerminalTitle.clear(state()) == state()
      refute_receive :title_cleared
    end

    test "clears a written title once" do
      cleared = TerminalTitle.clear(state(terminal_title: "tackle · 01234567 · idle"))

      assert_receive :title_cleared
      assert cleared.terminal_title == nil

      TerminalTitle.clear(cleared)
      refute_receive :title_cleared
    end

    test "keeps the cache on a failed clear" do
      state =
        state(
          terminal_title: "tackle · 01234567 · idle",
          writer: fn
            nil -> {:error, :closed}
            _title -> {:ok, :applied}
          end
        )

      assert TerminalTitle.clear(state).terminal_title == "tackle · 01234567 · idle"
    end
  end
end
