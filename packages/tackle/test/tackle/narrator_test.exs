defmodule Tackle.NarratorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Tackle.Test.Runtime

  alias Tackle.Config.Narration
  alias Tackle.Lib.Event
  alias Tackle.Narrator
  alias Tackle.Runtime.Registry

  @writer :tackle_narrator_test_writer

  defmodule Writer do
    @moduledoc false
    # Chat adapter driven by the test process registered as the writer.
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "narr"

    @impl true
    def models, do: ["fake"]

    @impl true
    def generate(_schema, opts) do
      send(:tackle_narrator_test_writer, {:writer_called, self(), opts})

      receive do
        {:writer_reply, reply} -> reply
        :writer_crash -> raise "writer crashed"
      after
        5_000 -> {:error, :no_reply}
      end
    end
  end

  setup do
    Process.register(self(), @writer)
    :ok
  end

  describe "with a narrator beside a plain root" do
    setup do
      scope = start_scope()
      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      %{scope: scope, session_id: snapshot.session_id}
    end

    test "narrates a subagent run after first_after, not before", ctx do
      narrator = start_narrator(ctx.scope, first_after_seconds: 0.2)
      started = System.monotonic_time(:millisecond)

      send_event(narrator, subagent_tool_start("call-1", "find where titles are stored"))
      send_event(narrator, subagent_started("run-1", "call-1"))
      send_event(narrator, subagent_progress("run-1", "call-1", read("r1", "lib/session.ex")))

      assert_receive {:writer_called, writer, opts}, 2_000
      assert System.monotonic_time(:millisecond) - started >= 200

      assert [%{role: :user, content: prompt}] = Keyword.fetch!(opts, :messages)
      assert prompt =~ "find where titles are stored"
      assert prompt =~ "read lib/session.ex (running)"
      assert prompt =~ "explorer"
      assert opts[:tools] == []
      assert opts[:tool_choice] == "none"
      assert opts[:reasoning_effort] == :none
      assert opts[:max_tokens] == 60
      assert opts[:model] == "fake"

      send(writer, {:writer_reply, answer("\"Reading session.ex for titles.\"\nmore")})

      session_id = ctx.session_id

      assert_receive {:tackle_event, ^session_id, nil,
                      %Event{
                        type: :narration,
                        data: %{
                          run_id: "run-1",
                          tool_call_id: "call-1",
                          text: "Reading session.ex for titles",
                          auxiliary: true
                        }
                      }},
                     1_000

      # Nothing changed since: no further request.
      refute_receive {:writer_called, _writer, _opts}, 300
    end

    test "keeps one request in flight and sends only the newest state", ctx do
      narrator = start_narrator(ctx.scope)

      send_event(narrator, subagent_started("run-1", "call-1"))
      send_event(narrator, subagent_progress("run-1", "call-1", read("r1", "first.ex")))

      assert_receive {:writer_called, writer, _opts}, 2_000

      for i <- 2..4 do
        send_event(narrator, subagent_progress("run-1", "call-1", read("r#{i}", "file_#{i}.ex")))
      end

      refute_receive {:writer_called, _writer, _opts}, 200

      send(writer, {:writer_reply, answer("reading first.ex")})
      assert_receive {:tackle_event, _sid, nil, %Event{data: %{text: "reading first.ex"}}}, 1_000

      assert_receive {:writer_called, writer, opts}, 2_000
      [%{content: prompt}] = opts[:messages]
      assert prompt =~ "file_4.ex"
      assert prompt =~ "reading first.ex"
      send(writer, {:writer_reply, answer("reading file_4.ex")})
      assert_receive {:tackle_event, _sid, nil, %Event{data: %{text: "reading file_4.ex"}}}, 1_000
    end

    test "shares the model fairly across runs", ctx do
      narrator = start_narrator(ctx.scope)

      for run <- ["run-a", "run-b"] do
        send_event(narrator, subagent_started(run, "call-" <> run))
        send_event(narrator, subagent_progress(run, "call-" <> run, read(run, "#{run}.ex")))
      end

      assert_receive {:writer_called, writer, opts}, 2_000
      first = run_in(opts)
      second = if first == "run-a", do: "run-b", else: "run-a"

      # The first run changes again, but the other one was never narrated.
      send_event(narrator, subagent_progress(first, "call-" <> first, read("x", "again.ex")))
      send(writer, {:writer_reply, answer("narrating #{first}")})

      assert_receive {:writer_called, writer, opts}, 2_000
      assert run_in(opts) == second
      send(writer, {:writer_reply, answer("narrating #{second}")})

      assert_receive {:writer_called, writer, opts}, 2_000
      assert run_in(opts) == first
      send(writer, {:writer_reply, answer("narrating #{first} again")})

      for text <- ["narrating #{first}", "narrating #{second}", "narrating #{first} again"] do
        assert_receive {:tackle_event, _sid, nil, %Event{data: %{text: ^text}}}, 1_000
      end
    end

    test "drops finished runs and discards their late answers", ctx do
      narrator = start_narrator(ctx.scope)

      send_event(narrator, subagent_started("run-1", "call-1"))
      send_event(narrator, subagent_progress("run-1", "call-1", read("r1", "a.ex")))
      assert_receive {:writer_called, writer, _opts}, 2_000

      send_event(narrator, subagent_progress("run-1", "call-1", read("r2", "b.ex")))
      send_event(narrator, Event.new(:subagent_finished, %{run_id: "run-1", status: :ok}))
      send(writer, {:writer_reply, answer("too late")})

      refute_receive {:tackle_event, _sid, nil, %Event{type: :narration}}, 300
      refute_receive {:writer_called, _writer, _opts}, 100
      assert :sys.get_state(narrator).runs == %{}
    end

    test "drops empty and tool-call answers", ctx do
      narrator = start_narrator(ctx.scope)

      send_event(narrator, subagent_started("run-1", "call-1"))
      send_event(narrator, subagent_progress("run-1", "call-1", read("r1", "a.ex")))
      assert_receive {:writer_called, writer, _opts}, 2_000
      send(writer, {:writer_reply, answer("  \n \"\" ")})

      send_event(narrator, subagent_progress("run-1", "call-1", read("r2", "b.ex")))
      assert_receive {:writer_called, writer, _opts}, 2_000

      send(
        writer,
        {:writer_reply,
         {:ok, %{data: %{"content" => "x", "tool_calls" => [%{"name" => "read"}]}, usage: nil}}}
      )

      refute_receive {:tackle_event, _sid, nil, %Event{type: :narration}}, 200
    end

    test "attributes nested runs to their top-level run", ctx do
      narrator = start_narrator(ctx.scope)

      nested =
        Event.new(:subagent_progress, %{
          run_id: "grandchild",
          tool_call_id: "inner-call",
          event: read("g1", "deep/nested.ex")
        })

      workflow_nested =
        Event.new(:workflow_progress, %{
          kind: :run_event,
          run_id: "wf-child",
          tool_call_id: "inner-wf",
          event:
            Event.new(:tool_start, %{
              tool_call_id: "g2",
              name: "grep",
              arguments: %{"pattern" => "TODO"}
            })
        })

      send_event(narrator, subagent_started("run-1", "call-1"))
      send_event(narrator, subagent_progress("run-1", "call-1", nested))
      send_event(narrator, subagent_progress("run-1", "call-1", workflow_nested))

      assert_receive {:writer_called, writer, opts}, 2_000
      [%{content: prompt}] = opts[:messages]
      assert prompt =~ "read deep/nested.ex"
      assert prompt =~ "grep TODO"
      assert Map.keys(:sys.get_state(narrator).runs) == ["run-1"]

      send(writer, {:writer_reply, answer("digging into nested.ex")})

      assert_receive {:tackle_event, _sid, nil,
                      %Event{data: %{run_id: "run-1", text: "digging into nested.ex"}}},
                     1_000
    end

    test "narrates workflow runs by their run id and workflow call", ctx do
      narrator = start_narrator(ctx.scope)

      send_event(
        narrator,
        workflow(:run_started, "wf-run", %{profile: "reviewer", prompt: "review the diff"})
      )

      send_event(narrator, workflow(:run_event, "wf-run", %{event: read("r1", "diff.patch")}))

      assert_receive {:writer_called, writer, opts}, 2_000
      [%{content: prompt}] = opts[:messages]
      assert prompt =~ "review the diff"
      assert prompt =~ "reviewer"
      send(writer, {:writer_reply, answer("reading the diff")})

      assert_receive {:tackle_event, _sid, nil,
                      %Event{
                        type: :narration,
                        data: %{
                          run_id: "wf-run",
                          tool_call_id: "wf-call",
                          text: "reading the diff"
                        }
                      }},
                     1_000

      send_event(narrator, workflow(:run_finished, "wf-run", %{ok: true, status: :ok}))
      assert :sys.get_state(narrator).runs == %{}

      # Classifications are not runs: they are drawn by the frontend, not narrated.
      classify = %{kind: :classify_started, id: 1, tool_call_id: "wf-call", label: "gate"}
      send_event(narrator, Event.new(:workflow_progress, classify))

      send_event(
        narrator,
        Event.new(
          :workflow_progress,
          %{classify | kind: :classify_finished} |> Map.put(:ok, true)
        )
      )

      assert :sys.get_state(narrator).runs == %{}

      # Runs the workflow never awaited end with its tool call.
      send_event(narrator, workflow(:run_started, "wf-other", %{prompt: "x"}))
      assert Map.has_key?(:sys.get_state(narrator).runs, "wf-other")

      send_event(narrator, Event.new(:tool_end, %{tool_call_id: "wf-call", name: "run_workflow"}))
      assert :sys.get_state(narrator).runs == %{}
    end

    test "turn end drops foreground runs and keeps background ones", ctx do
      narrator = start_narrator(ctx.scope, first_after_seconds: 30)

      send_event(narrator, subagent_tool_start("call-fg", "foreground task"))
      send_event(narrator, subagent_started("run-fg", "call-fg"))

      send_event(
        narrator,
        subagent_tool_start("call-bg", "background task", %{"background" => true})
      )

      send_event(narrator, subagent_started("run-bg", "call-bg"))

      # A background launch ends its call at once; its run keeps going.
      send_event(narrator, Event.new(:tool_end, %{tool_call_id: "call-bg", name: "subagent"}))
      assert Map.keys(:sys.get_state(narrator).runs) |> Enum.sort() == ["run-bg", "run-fg"]

      send(narrator, {:tackle_turn_finished, ctx.session_id, "turn", {:ok, nil}})
      assert Map.keys(:sys.get_state(narrator).runs) == ["run-bg"]
      assert :sys.get_state(narrator).runs["run-bg"].digest.task == "background task"
    end

    test "a failing model warns once, backs off, and keeps narrating", ctx do
      narrator = start_narrator(ctx.scope, llm_opts: [receive_timeout: 50])

      log =
        capture_log(fn ->
          send_event(narrator, subagent_started("run-1", "call-1"))
          send_event(narrator, subagent_progress("run-1", "call-1", read("r1", "a.ex")))

          assert_receive {:writer_called, writer, _opts}, 2_000
          send(writer, {:writer_reply, {:error, :unreachable}})

          # Retried after the back-off although nothing changed.
          assert_receive {:writer_called, writer, _opts}, 2_000
          send(writer, :writer_crash)

          # A request that never answers times out.
          assert_receive {:writer_called, _writer, _opts}, 2_000

          assert_receive {:writer_called, writer, _opts}, 3_000
          send(writer, {:writer_reply, answer("reading a.ex")})

          assert_receive {:tackle_event, _sid, nil, %Event{data: %{text: "reading a.ex"}}},
                         1_000
        end)

      assert [_before, _after] = String.split(log, "narration model narr/fake failed")
      assert Process.alive?(narrator)
      assert :sys.get_state(narrator).backoff_ms == nil
    end
  end

  describe "started by the root backend" do
    test "runs only beside the root session, also without a watchdog" do
      scope =
        start_scope(
          root: [
            providers: [Tackle.Test.Adapter, Writer],
            allow_delegation: true,
            narration: [model: "narr/fake"]
          ],
          profiles: %{
            "child" =>
              agent_spec("child",
                mode: :manual,
                providers: [Tackle.Test.Adapter, Writer],
                narration: [model: "narr/fake"]
              )
          }
        )

      assert Narrator.running?(scope.root_agent_ref)

      {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "child", "work")
      assert_receive {:adapter_called, adapter, _model, _opts}, 2_000
      refute Narrator.running?(run_ref.agent_ref)
      assert Registry.service_task_supervisor(run_ref.agent_ref) == {:error, :not_found}

      send(adapter, {:respond, "done"})
      assert %Tackle.Runtime.Outcome{status: :ok} = Tackle.Runtime.await(run_ref, 2_000)

      Tackle.Runtime.stop_scope(scope.scope_ref)
      refute Narrator.running?(scope.root_agent_ref)
    end

    test "agents without a narration config run no narrator" do
      scope = start_scope()
      refute Narrator.running?(scope.root_agent_ref)
    end

    test "narrates a real foreground subagent through the root session" do
      tool_call = %{
        "id" => "call-1",
        "name" => "subagent",
        "arguments" => %{"profile" => "worker", "prompt" => "inspect the blocking tool"}
      }

      scope =
        start_scope(
          root: [
            providers: [Tackle.Test.Adapter, Writer],
            allow_delegation: true,
            tools: [Tackle.Tools.Subagent],
            mode: :tool_then_answer,
            llm_opts: [tool_call: tool_call, content: "root done"],
            narration: [model: "narr/fake", first_after_seconds: 0.05, interval_seconds: 0.05]
          ],
          profiles: %{
            "worker" =>
              agent_spec("worker",
                tools: [Tackle.Test.BlockingTool],
                context: %{test_pid: self()},
                mode: :tool_then_answer,
                llm_opts: [
                  tool_call: %{
                    "id" => "child-call",
                    "name" => "blocking",
                    "arguments" => %{"name" => "work"}
                  }
                ],
                content: "worker done"
              )
          }
        )

      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      session_id = snapshot.session_id
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "delegate")

      assert_receive {:tool_entered, "work", tool}, 5_000
      assert_receive {:writer_called, writer, opts}, 2_000
      [%{content: prompt}] = opts[:messages]
      assert prompt =~ "inspect the blocking tool"
      assert prompt =~ "blocking (running)"

      send(writer, {:writer_reply, answer("waiting on the blocking tool")})

      assert_receive {:tackle_event, ^session_id, nil,
                      %Event{
                        type: :narration,
                        data: %{tool_call_id: "call-1", text: "waiting on the blocking tool"}
                      }},
                     2_000

      send(tool, {:release, "work"})
      assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, state}}, 5_000
      assert Tackle.Lib.last_answer(state) == "root done"
      refute inspect(state.messages) =~ "waiting on the blocking tool"
    end
  end

  defp start_narrator(scope, opts \\ []) do
    {:ok, settings} =
      Narration.new(
        [
          model: "narr/fake",
          interval_seconds: Keyword.get(opts, :interval_seconds, 0.05),
          first_after_seconds: Keyword.get(opts, :first_after_seconds, 0.05)
        ],
        [Writer]
      )

    task_supervisor = start_supervised!(Task.Supervisor)

    start_supervised!(
      {Narrator,
       agent_ref: scope.root_agent_ref,
       task_supervisor: task_supervisor,
       settings: settings,
       llm_opts: Keyword.get(opts, :llm_opts, [])}
    )
  end

  defp send_event(narrator, %Event{} = event),
    do: send(narrator, {:tackle_event, "session", "turn", event})

  defp subagent_tool_start(id, prompt, extra \\ %{}) do
    arguments = Map.merge(%{"profile" => "explorer", "prompt" => prompt}, extra)
    Event.new(:tool_start, %{tool_call_id: id, name: "subagent", arguments: arguments})
  end

  defp subagent_started(run_id, call_id) do
    Event.new(:subagent_started, %{
      run_id: run_id,
      tool_call_id: call_id,
      profile: "explorer",
      status: :running
    })
  end

  defp subagent_progress(run_id, call_id, event) do
    Event.new(:subagent_progress, %{
      run_id: run_id,
      tool_call_id: call_id,
      profile: "explorer",
      background: false,
      event: event
    })
  end

  defp workflow(kind, run_id, data) do
    Event.new(
      :workflow_progress,
      Map.merge(%{kind: kind, run_id: run_id, tool_call_id: "wf-call"}, data)
    )
  end

  defp read(id, path),
    do: Event.new(:tool_start, %{tool_call_id: id, name: "read", arguments: %{"path" => path}})

  defp answer(text),
    do: {:ok, %{data: %{"content" => text, "tool_calls" => []}, usage: nil, model: "fake"}}

  defp run_in(opts) do
    [%{content: prompt}] = Keyword.fetch!(opts, :messages)
    if prompt =~ "run-a.ex", do: "run-a", else: "run-b"
  end
end
