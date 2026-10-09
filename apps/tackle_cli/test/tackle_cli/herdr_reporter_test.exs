defmodule Tackle.CLI.Herdr.ReporterTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Herdr.Reporter

  @config %{pane_id: "w1:p1", socket_path: "/unused"}

  defp report(state, session_id \\ nil),
    do: %{state: state, session_id: session_id, resume_argv: nil}

  # Forwards every request to the test; when `gate?` is set the first request
  # blocks until the test sends `:continue`, so reports can queue behind it.
  defp start_reporter(opts \\ []) do
    test_pid = self()
    gate? = Keyword.get(opts, :gate?, false)
    result = Keyword.get(opts, :result, :ok)

    sender = fn _config, request ->
      send(test_pid, {:herdr, request["method"], request["params"]})

      if gate? and Process.get(:gated) == nil do
        Process.put(:gated, true)

        receive do
          :continue -> :ok
        end
      end

      result
    end

    {:ok, reporter} = Reporter.start_link(@config, sender: sender)
    reporter
  end

  test "sends a report from its own process" do
    reporter = start_reporter()

    :ok = Reporter.report(reporter, report(:working))

    assert_receive {:herdr, "pane.report_agent", %{"state" => "working", "seq" => seq}}
    assert is_integer(seq)
  end

  test "sends only the latest report queued behind one in flight" do
    reporter = start_reporter(gate?: true)

    :ok = Reporter.report(reporter, report(:working))
    assert_receive {:herdr, "pane.report_agent", %{"state" => "working", "seq" => first}}

    :ok = Reporter.report(reporter, report(:idle))
    :ok = Reporter.report(reporter, report(:working, "s-2"))
    :ok = Reporter.report(reporter, report(:idle, "s-3"))
    send(reporter, :continue)

    assert_receive {:herdr, "pane.report_agent", params}
    assert params["state"] == "idle"
    assert params["agent_session_id"] == "s-3"
    assert params["seq"] > first
    refute_receive {:herdr, "pane.report_agent", _params}
  end

  test "ignores send failures and keeps reporting" do
    reporter = start_reporter(result: {:error, :enoent})

    :ok = Reporter.report(reporter, report(:working))
    assert_receive {:herdr, "pane.report_agent", %{"state" => "working"}}

    :ok = Reporter.report(reporter, report(:idle))
    assert_receive {:herdr, "pane.report_agent", %{"state" => "idle"}}
  end

  test "survives a sender that raises" do
    test_pid = self()

    sender = fn _config, request ->
      send(test_pid, {:herdr, request["method"], request["params"]})
      raise "socket exploded"
    end

    {:ok, reporter} = Reporter.start_link(@config, sender: sender)

    :ok = Reporter.report(reporter, report(:working))
    assert_receive {:herdr, "pane.report_agent", %{"state" => "working"}}

    # Raising and catching can be slow on a loaded VM; waiting for the
    # reporter to finish the failed send keeps the next assertion about
    # survival rather than timing.
    _state = :sys.get_state(reporter)

    :ok = Reporter.report(reporter, report(:idle))
    assert_receive {:herdr, "pane.report_agent", %{"state" => "idle"}}, 1_000

    assert Reporter.release(reporter) == :ok
    assert_receive {:herdr, "pane.release_agent", _params}
  end

  test "release drops a queued report, releases the pane, and stops" do
    reporter = start_reporter(gate?: true)
    monitor = Process.monitor(reporter)

    :ok = Reporter.report(reporter, report(:working))
    assert_receive {:herdr, "pane.report_agent", %{"seq" => report_seq}}
    :ok = Reporter.report(reporter, report(:idle))

    release = Task.async(fn -> Reporter.release(reporter) end)
    # The queued report and the release must both wait behind the gate.
    await_queue(reporter, 2)
    send(reporter, :continue)

    assert Task.await(release) == :ok

    assert_receive {:herdr, "pane.release_agent",
                    %{"source" => "tackle", "agent" => "tackle", "seq" => release_seq}}

    assert release_seq > report_seq
    assert_receive {:DOWN, ^monitor, :process, ^reporter, :normal}
    refute_receive {:herdr, "pane.report_agent", _params}
  end

  test "release returns when the reporter is gone or slow" do
    reporter = start_reporter(gate?: true)
    :ok = Reporter.report(reporter, report(:working))
    assert_receive {:herdr, "pane.report_agent", _params}

    assert Reporter.release(reporter, 20) == :ok

    send(reporter, :continue)
    assert_receive {:herdr, "pane.release_agent", _params}
    assert Reporter.release(reporter) == :ok
  end

  defp await_queue(pid, length) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, ^length} ->
        :ok

      _other ->
        Process.sleep(1)
        await_queue(pid, length)
    end
  end
end
