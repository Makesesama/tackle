defmodule Tackle.CLI.Output.ProgressTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Output.Progress
  alias Tackle.Lib.Event

  test "describes status and response events" do
    assert Progress.event_label(Event.new(:status_change, %{status: :thinking})) == "Thinking…"

    assert Progress.event_label(Event.new(:message_delta, %{delta: "hello"})) ==
             "Writing response…"

    assert Progress.event_label(Event.new(:message_delta, %{delta: "why", field: :reasoning})) ==
             "Thinking…"
  end

  test "describes tool events using a bounded one-line target" do
    assert Progress.event_label(
             Event.new(:tool_start, %{
               name: "read",
               arguments: %{"path" => "README.md"}
             })
           ) == "Running read · README.md…"

    assert Progress.event_label(
             Event.new(:tool_start, %{
               name: "bash",
               arguments: %{command: "mix test\necho done"}
             })
           ) == "Running bash · mix test…"

    assert Progress.event_label(
             Event.new(:tool_execution_end, %{name: "bash", status: :completed})
           ) == "Completed bash"

    assert Progress.event_label(Event.new(:tool_execution_end, %{name: "bash", status: :failed})) ==
             "bash failed"
  end

  test "ignores events that do not improve progress" do
    assert Progress.event_label(Event.new(:usage, %{})) == nil
    assert Progress.event_label(Event.new(:status_change, %{status: :completed})) == nil
  end

  test "is disabled when the output device is not a terminal" do
    {:ok, device} = StringIO.open("")
    assert Progress.start(device: device) == :disabled
    assert Progress.event(:disabled, Event.new(:status_change, %{status: :thinking})) == :disabled
    assert Progress.finish(:disabled, {:ok, "answer"}) == :ok
  end

  test "accepts the conventional stderr alias when terminal geometry is available" do
    if Owl.IO.columns(:standard_error) && Owl.IO.rows(:standard_error) do
      progress = Progress.start(device: :stderr)
      assert %Progress{} = progress
      assert Progress.finish(progress, {:ok, "answer"}) == :ok
    end
  end

  test "finishing cannot block indefinitely when the live screen cannot render" do
    spinner_id = make_ref()
    spinner = start_blocked_spinner(spinner_id)

    progress = %Progress{
      screen: start_blocked_screen(),
      spinner_id: spinner_id,
      width: 80
    }

    task = Task.async(fn -> Progress.finish(progress, {:ok, "answer"}) end)

    assert Task.await(task, 1_000) == :ok
    refute Process.alive?(spinner)
    refute Process.alive?(progress.screen)
  end

  defp start_blocked_spinner(spinner_id) do
    parent = self()

    pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        Registry.register(Owl.WidgetsRegistry, spinner_id, nil)
        send(parent, {:spinner_registered, self()})
        blocked_screen_loop()
      end)

    assert_receive {:spinner_registered, ^pid}
    pid
  end

  defp start_blocked_screen do
    spawn(fn ->
      Process.flag(:trap_exit, true)
      blocked_screen_loop()
    end)
  end

  defp blocked_screen_loop do
    receive do
      _message -> blocked_screen_loop()
    end
  end
end
