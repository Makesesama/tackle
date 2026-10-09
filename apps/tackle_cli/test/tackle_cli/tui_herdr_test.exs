defmodule Tackle.CLI.TUI.HerdrTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Herdr.Reporter
  alias Tackle.CLI.TUI.Herdr
  alias Tackle.CLI.TUI.State
  alias Tackle.Lib.Message
  alias Tackle.Lib.State, as: AgentState

  @session "01234567-89ab-cdef-0123-456789abcdef"

  defp reporter do
    test_pid = self()

    sender = fn _config, request ->
      send(test_pid, {:herdr, request["method"], request["params"]})
      :ok
    end

    {:ok, reporter} =
      Reporter.start_link(%{pane_id: "w1:p1", socket_path: "/unused"}, sender: sender)

    reporter
  end

  defp state(opts \\ []) do
    %State{
      session_id: Keyword.get(opts, :session_id, @session),
      active_turn: Keyword.get(opts, :active_turn),
      pending_operation: Keyword.get(opts, :pending_operation),
      agent_state: Keyword.get(opts, :agent_state),
      herdr: Keyword.get(opts, :herdr)
    }
  end

  defp resumable(state), do: %{state: state, session_id: @session, resume_argv: resume()}
  defp resume, do: ["tackle", "--resume", @session]

  describe "start/1" do
    test "never reads the environment in test shells" do
      assert Herdr.start(test_mode: {80, 24}) == nil
    end

    test "adopts an injected reporter" do
      reporter = reporter()
      assert %Herdr{reporter: ^reporter, reported: nil} = Herdr.start(herdr_reporter: reporter)
    end
  end

  describe "report/2" do
    test "a fresh session is idle and not yet resumable" do
      assert Herdr.report(state(), nil) == %{state: :idle, session_id: nil, resume_argv: nil}
    end

    test "a running turn is working and makes the session resumable" do
      assert Herdr.report(state(active_turn: %{id: "t"}), nil) == resumable(:working)
    end

    test "a shell operation between turns is working" do
      assert %{state: :working, session_id: nil} =
               Herdr.report(state(pending_operation: %{kind: :submit}), nil)
    end

    test "a session with history is resumable" do
      agent_state = %AgentState{messages: [Message.user("hi")]}
      assert Herdr.report(state(agent_state: agent_state), nil) == resumable(:idle)
    end

    test "a session stays resumable once reported as resumable" do
      assert Herdr.report(state(), resumable(:working)) == resumable(:idle)
    end

    test "a new session is not resumable until it has a prompt" do
      assert Herdr.report(state(session_id: "other"), resumable(:idle)) ==
               %{state: :idle, session_id: nil, resume_argv: nil}
    end
  end

  describe "refresh/1" do
    test "is a no-op outside Herdr" do
      assert Herdr.refresh(state()) == state()
    end

    test "sends a changed report and remembers it" do
      herdr = %Herdr{reporter: reporter()}

      refreshed = Herdr.refresh(state(herdr: herdr, active_turn: %{id: "t"}))

      assert refreshed.herdr.reported == resumable(:working)

      assert_receive {:herdr, "pane.report_agent",
                      %{"state" => "working", "agent_session_id" => @session} = params}

      assert params["resume_argv"] == resume()
    end

    test "skips an unchanged report" do
      herdr = %Herdr{reporter: reporter(), reported: resumable(:idle)}
      state = state(herdr: herdr)

      assert Herdr.refresh(state) == state
      refute_receive {:herdr, _method, _params}
    end
  end

  describe "release/1" do
    test "is a no-op outside Herdr" do
      assert Herdr.release(state()) == :ok
    end

    test "releases the pane" do
      assert Herdr.release(state(herdr: %Herdr{reporter: reporter()})) == :ok
      assert_receive {:herdr, "pane.release_agent", %{"pane_id" => "w1:p1"}}
    end
  end
end
