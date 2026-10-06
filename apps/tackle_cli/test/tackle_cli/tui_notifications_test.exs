defmodule Tackle.CLI.TUI.NotificationsTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.Notifications
  alias Tackle.CLI.TUI.State

  defp writer do
    test_pid = self()

    fn message ->
      send(test_pid, {:notified, message})
      {:ok, :applied}
    end
  end

  defp state(opts) do
    %State{
      terminal_focused?: Keyword.get(opts, :focused?, true),
      queued_prompts: Keyword.get(opts, :queued_prompts, []),
      notification_writer: Keyword.get(opts, :writer, writer()),
      stream: %State.Stream{
        response: Keyword.get(opts, :response, "")
      }
    }
  end

  describe "turn_finished_message/2" do
    test "previews the streamed response" do
      assert Notifications.turn_finished_message(state(response: "  All done.  "), :ok) ==
               "All done."
    end

    test "falls back to a plain outcome line without response prose" do
      assert Notifications.turn_finished_message(state(response: "  "), :ok) == "Turn complete"
      assert Notifications.turn_finished_message(state(response: ""), :error) == "Turn failed"

      assert Notifications.turn_finished_message(state(response: "partial"), :cancelled) ==
               "Turn cancelled"
    end
  end

  describe "turn_finished/2" do
    test "notifies when the terminal is unfocused" do
      :ok = Notifications.turn_finished(state(focused?: false, response: "Done"), :ok)

      assert_receive {:notified, "Done"}
    end

    test "stays quiet while the terminal is focused" do
      :ok = Notifications.turn_finished(state(focused?: true, response: "Done"), :ok)

      refute_receive {:notified, _message}
    end

    test "stays quiet while a queued prompt keeps the agent working" do
      :ok =
        Notifications.turn_finished(
          state(focused?: false, queued_prompts: ["next"], response: "Done"),
          :ok
        )

      refute_receive {:notified, _message}
    end

    test "a failed write does not surface an error" do
      state = state(focused?: false, writer: fn _message -> {:error, :enoent} end)

      assert Notifications.turn_finished(state, :ok) == :ok
    end
  end
end
