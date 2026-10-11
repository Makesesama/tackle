defmodule Tackle.Workflow.ToolTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Tackle.Workflow.TestSupport

  alias Tackle.Lib.Event
  alias Tackle.Lib.Tool
  alias Tackle.Workflow
  alias Tackle.Workflow.Tool, as: WorkflowTool

  @workflow_timeout 5_000

  # Runs the tool the way a session does: a script argument, plus the host's
  # context (the runtime handle and optional workflow configuration).
  defp run_workflow(scope, script, opts \\ []) do
    args = Map.merge(%{"script" => script}, Keyword.get(opts, :args, %{}))
    context = opts |> Keyword.get(:context, %{}) |> Map.put_new(:runtime, handle(scope))

    WorkflowTool.run(args, context)
  end

  describe "saved workflows" do
    test "resolves a name with the host loader" do
      scope = start_scope()

      loader = fn name ->
        assert name == "report"
        {:ok, "return 'saved result'"}
      end

      assert {:ok, "saved result"} =
               WorkflowTool.run(%{"workflow" => "report"}, %{
                 runtime: handle(scope),
                 workflow_loader: loader
               })
    end

    test "treats a null source as absent" do
      scope = start_scope()

      assert {:ok, "saved"} =
               WorkflowTool.run(%{"script" => nil, "workflow" => "report"}, %{
                 runtime: handle(scope),
                 workflow_loader: fn "report" -> {:ok, "return 'saved'"} end
               })
    end

    test "requires exactly one source" do
      for args <- [%{}, %{"script" => "return 1", "workflow" => "report"}] do
        assert {:error, "run_workflow requires exactly one of script or workflow"} =
                 WorkflowTool.run(args, %{})
      end
    end

    test "missing or invalid host loader is unavailable, never taken from model input" do
      for context <- [
            %{},
            %{workflow_loader: "bad"},
            %{workflow_loader: fn -> :ok end},
            %{workflow_loader: fn _ -> :bad end}
          ] do
        assert {:error, "saved workflows are not available in this session"} =
                 WorkflowTool.run(
                   %{"workflow" => "report", "workflow_loader" => fn _ -> {:ok, "return 1"} end},
                   context
                 )
      end
    end

    test "passes loader errors through" do
      assert {:error, "Unknown workflow. Available: report"} =
               WorkflowTool.run(%{"workflow" => "missing"}, %{
                 workflow_loader: fn _ -> {:error, "Unknown workflow. Available: report"} end
               })
    end
  end

  describe "the workflow skill guide" do
    test "is an Agent Skills document named tackle-workflows" do
      assert "---\nname: tackle-workflows\ndescription: " <> _rest = WorkflowTool.skill_markdown()
    end

    test "saved workflow guidance leaves availability to the host" do
      assert WorkflowTool.skill_markdown() =~ "files the host makes available by name"
      assert WorkflowTool.skill_markdown() =~ "in the Tackle CLI:"
      assert WorkflowTool.skill_markdown() =~ "the error lists the available ones"
      assert WorkflowTool.description() =~ "files the host makes available by name"
      assert WorkflowTool.description() =~ "lists the available ones"
    end

    test "every Lua example compiles" do
      examples =
        ~r/```lua\n(.*?)```/s
        |> Regex.scan(WorkflowTool.skill_markdown(), capture: :all_but_first)
        |> List.flatten()

      assert length(examples) >= 3

      for example <- examples do
        assert {:ok, _chunk} = Lua.parse_chunk(example), "does not compile:\n" <> example
      end
    end
  end

  describe "the skill's goal loop example" do
    # The guide is model-facing instructions, so its goal loop is run against fake
    # profiles to keep its stop rules honest.
    defp goal_loop do
      [_, example] =
        Regex.run(~r/## Goal loops.*?```lua\n(.*?)```/s, WorkflowTool.skill_markdown())

      example
    end

    defp goal_result(scope, opts \\ []) do
      opts = Keyword.put_new(opts, :log, fn _message -> :ok end)
      {:ok, ref} = Workflow.run(handle(scope), goal_loop(), opts)
      assert {:ok, [table]} = Workflow.await(ref, @workflow_timeout)
      Map.new(table)
    end

    defp round_events(tokens) do
      [Event.new(:step_end, %{iteration: 1, usage: %{total_tokens: tokens}}), tool_end()]
    end

    defp tool_end, do: Event.new(:tool_end, %{tool_call_id: "call", name: "bash"})

    test "completes only after the independent audit agrees" do
      scope =
        start_scope(
          profiles: %{
            "worker" =>
              agent_spec("worker",
                mode: :content,
                content: "Split parse/1.\nSTATUS: complete",
                events: round_events(1_000)
              ),
            "reviewer" => agent_spec("reviewer", mode: :content, content: "ACHIEVED\nall met")
          }
        )

      assert %{"status" => "complete", "rounds" => 1} = goal_result(scope)
    end

    test "stops as blocked after three rounds that called no tools" do
      scope =
        start_scope(
          profiles: %{
            "worker" =>
              agent_spec("worker", mode: :content, content: "Did a lot.\nSTATUS: progress")
          }
        )

      assert %{"status" => "blocked", "rounds" => 3} = goal_result(scope)
    end

    test "ends as budget_limited before a round could overrun the budget" do
      scope =
        start_scope(
          profiles: %{
            "worker" =>
              agent_spec("worker",
                mode: :content,
                content: "Renamed modules.\nSTATUS: progress",
                events: round_events(50_000)
              )
          }
        )

      assert %{"status" => "budget_limited", "rounds" => 1, "used" => 50_000} =
               goal_result(scope, token_budget: 100_000)
    end

    test "does not crash when a completing round used up the budget before its audit" do
      scope =
        start_scope(
          profiles: %{
            "worker" =>
              agent_spec("worker",
                mode: :content,
                content: "Done.\nSTATUS: complete",
                events: round_events(120_000)
              ),
            "reviewer" => agent_spec("reviewer", mode: :content, content: "ACHIEVED")
          }
        )

      assert %{"status" => "budget_limited", "rounds" => 1, "unaudited" => true} =
               goal_result(scope, token_budget: 100_000)
    end
  end

  describe "the run_workflow tool" do
    test "is a valid Tackle tool" do
      assert WorkflowTool.name() == "run_workflow"
      assert %Tool.Registry{} = Tool.Registry.new([WorkflowTool])
    end

    test "runs a workflow and returns the value it produced" do
      scope =
        start_scope(profiles: %{"scout" => agent_spec("scout"), "worker" => agent_spec("worker")})

      script = """
      local findings = tackle.await(tackle.spawn("scout", "map the code"))
      return tackle.await(tackle.spawn("worker", "implement: " .. findings.text)).text
      """

      assert {:ok, "implement: map the code"} = run_workflow(scope, script)
    end

    test "returns every value the workflow produced" do
      scope = start_scope(profiles: %{})

      assert {:ok, "one\ntwo\n3"} = run_workflow(scope, ~s|return "one", "two", 3|)
      assert {:ok, "nil"} = run_workflow(scope, "return nil")
      assert {:ok, "(the workflow returned no values)"} = run_workflow(scope, "local _ = 1")
    end

    test "renders a returned sequence table one element per line" do
      scope = start_scope(profiles: %{"scout" => agent_spec("scout")})

      script = """
      local result = tackle.await(tackle.spawn("scout", "map the code"))
      return {result.text, "second", 3, true}
      """

      assert {:ok, "map the code\nsecond\n3\ntrue"} = run_workflow(scope, script)
      assert {:ok, "one\ntwo\nthree"} = run_workflow(scope, ~s|return {"one", "two"}, "three"|)
    end

    test "renders keyed and nested tables as JSON" do
      scope = start_scope(profiles: %{})

      assert {:ok, json} = run_workflow(scope, ~s|return {ok = true, text = "done", n = 2}|)
      assert JSON.decode!(json) == %{"ok" => true, "text" => "done", "n" => 2}

      # A table nested in a sequence stays one JSON value on its own line.
      assert {:ok, "first\n" <> nested} =
               run_workflow(scope, ~s|return {"first", {a = {1, 2}, [3] = "x"}}|)

      assert JSON.decode!(nested) == %{"a" => [1, 2], "3" => "x"}

      # A sparse table is not a sequence; its keys stay explicit.
      assert {:ok, sparse} = run_workflow(scope, ~s|return {[1] = "a", [3] = "c"}|)
      assert JSON.decode!(sparse) == %{"1" => "a", "3" => "c"}

      assert {:ok, "[]"} = run_workflow(scope, "return {}")
      assert {:ok, "[[1,2],[]]"} = run_workflow(scope, "return {{{1, 2}, {}}}")
    end

    test "keeps a readable fallback for values JSON cannot represent" do
      scope = start_scope(profiles: %{})

      assert {:ok, "nan"} = run_workflow(scope, "return 0/0")
      assert {:ok, ~s|{"x":null}|} = run_workflow(scope, "return {x = 0/0}")

      # Functions have no data representation; they never leak VM internals.
      assert {:ok, "<function>"} = run_workflow(scope, "return function() end")
      assert {:ok, ~s|{"f":"<function>"}|} = run_workflow(scope, "return {f = function() end}")
      assert {:ok, ~s|["<function>","x"]|} = run_workflow(scope, ~s|return {{print, "x"}}|)

      # Keys that collide once stringified would silently lose a value.
      assert {:ok, colliding} =
               run_workflow(scope, ~s|return {[1] = "int", ["1"] = "str", [2] = 0}|)

      assert colliding =~ ~s|"int"|
      assert colliding =~ ~s|"str"|

      # Lua strings are bytes; invalid UTF-8 cannot be JSON.
      assert {:ok, bytes} = run_workflow(scope, ~S|return {k = "\255"}|)
      assert bytes =~ "<<255>>"
    end

    test "reports a workflow error for a rejected spawn" do
      scope = start_scope(profiles: %{})

      assert {:error, message} = run_workflow(scope, ~s|return tackle.spawn("ghost", "go")|)
      assert message =~ ~s|the workflow failed:|
      assert message =~ "unknown_profile"
    end

    test "reports a workflow whose Lua does not compile" do
      scope = start_scope(profiles: %{})

      assert {:error, message} = run_workflow(scope, "local = broken")
      assert message =~ "does not compile"
    end

    test "sets no deadline: a slow run still settles the workflow" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :manual)})
      script = ~s|return tackle.await(tackle.spawn("worker", "go")).text|

      task = Task.async(fn -> run_workflow(scope, script) end)

      assert_receive {:agent_called, agent}, 1_000
      send(agent, {:respond, "done"})

      assert {:ok, "done"} = Task.await(task, @workflow_timeout)
    end

    test "offers the model no deadline argument" do
      schema = WorkflowTool.parameters_schema()
      assert schema |> Keyword.keys() |> Enum.sort() == [:script, :token_budget, :workflow]
      refute Keyword.get(schema[:script], :required, false)
      refute Keyword.get(schema[:workflow], :required, false)
    end
  end

  describe "the workflow profile allowlist" do
    test "narrows the profiles a workflow may spawn" do
      scope =
        start_scope(profiles: %{"scout" => agent_spec("scout"), "worker" => agent_spec("worker")})

      context = %{workflow_profiles: ["scout"]}

      assert {:ok, "ask"} =
               run_workflow(
                 scope,
                 ~s|return tackle.await(tackle.spawn("scout", "ask")).text|,
                 context: context
               )

      assert {:error, message} =
               run_workflow(
                 scope,
                 ~s|return tackle.await(tackle.spawn("worker", "go")).text|,
                 context: context
               )

      assert message =~ ~s|profile "worker" is not allowlisted for workflows|
    end

    test "bounds a fan-out to the allowlist and reports the refused item" do
      scope =
        start_scope(profiles: %{"scout" => agent_spec("scout"), "worker" => agent_spec("worker")})

      script = """
      local results = tackle.parallel({"scout", "worker"}, function(item)
        return item, "ask:" .. item
      end)
      return results[1].status, results[1].text, results[2].status, results[2].text
      """

      expected =
        "ok\nask:scout\nspawn_error\nspawn failed: profile \"worker\" is not allowlisted " <>
          "for workflows"

      assert {:ok, ^expected} =
               run_workflow(scope, script, context: %{workflow_profiles: ["scout"]})
    end

    test "leaves the decision to the scope when the host does not narrow it" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

      assert {:ok, "go"} =
               run_workflow(scope, ~s|return tackle.await(tackle.spawn("worker", "go")).text|)
    end

    test "rejects a malformed allowlist instead of guessing" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

      assert {:error, message} =
               run_workflow(scope, "return 1", context: %{workflow_profiles: "w"})

      assert message =~ "workflow_profiles must be a list of profile names"

      assert {:error, message} =
               run_workflow(scope, "return 1", context: %{workflow_profiles: ["worker", 7]})

      assert message =~ "workflow_profiles must be a list of profile names"
    end
  end

  describe "the tool's permission checks" do
    test "refuses to run without a runtime handle" do
      assert {:error, message} = WorkflowTool.run(%{"script" => "return 1"}, %{})
      assert message =~ "no runtime handle"
    end

    test "refuses to run when the agent may not delegate" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})
      context = %{runtime: handle(scope, allow_delegation: false)}

      assert {:error, message} = WorkflowTool.run(%{"script" => "return 1"}, context)
      assert message =~ "not permitted"
    end

    test "requires a script or saved workflow name" do
      scope = start_scope(profiles: %{})
      context = %{runtime: handle(scope)}

      assert {:error, message} = WorkflowTool.run(%{}, context)
      assert message =~ "requires exactly one of script or workflow"
    end
  end

  describe "the workflow deadline" do
    test "is absent unless the host sets one explicitly" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :manual)})
      script = ~s|return tackle.await(tackle.spawn("worker", "go")).text|

      assert {:ok, ref} = Workflow.run(handle(scope), script)
      assert_receive {:agent_called, agent}, 1_000
      send(agent, {:respond, "done"})
      assert {:ok, ["done"]} = Workflow.await(ref, @workflow_timeout)
    end

    test "rejects a malformed explicit deadline" do
      scope = start_scope(profiles: %{})

      assert {:error, {:invalid_workflow_option, :timeout, "1s"}} =
               Workflow.run(handle(scope), "return 1", timeout: "1s")

      assert {:error, {:invalid_workflow_option, :timeout, 0}} =
               Workflow.run(handle(scope), "return 1", timeout: 0)

      assert {:ok, ref} = Workflow.run(handle(scope), "return 1", timeout: :infinity)
      assert {:ok, [1]} = Workflow.await(ref, @workflow_timeout)
    end
  end

  describe "the allowlist at the workflow seam" do
    test "bounds spawn and parallel when a host narrows it directly" do
      scope =
        start_scope(profiles: %{"scout" => agent_spec("scout"), "worker" => agent_spec("worker")})

      script = """
      local results = tackle.parallel({"scout", "worker"}, function(item)
        return item, "ask:" .. item
      end)
      return results[1].status, results[1].text, results[2].status, results[2].text
      """

      assert {:ok, ref} = Workflow.run(handle(scope), script, profiles: ["scout"])

      assert {:ok, ["ok", "ask:scout", "spawn_error", reason]} =
               Workflow.await(ref, @workflow_timeout)

      assert reason =~ "not allowlisted"
    end

    test "raises a catchable error for a spawn outside the allowlist" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

      script = """
      local ok, err = pcall(function() tackle.spawn("worker", "go") end)
      return ok, tostring(err)
      """

      assert {:ok, ref} = Workflow.run(handle(scope), script, profiles: ["scout"])
      assert {:ok, [false, message]} = Workflow.await(ref, @workflow_timeout)
      assert message =~ "not allowlisted"
    end

    test "an empty allowlist lets a workflow run but refuse every spawn" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

      script = ~s|return tackle.await(tackle.spawn("worker", "go")).text|

      assert {:ok, ref} = Workflow.run(handle(scope), script, profiles: [])

      assert {:error, %{message: message}} = Workflow.await(ref, @workflow_timeout)
      assert message =~ "not allowlisted"
    end

    test "rejects a malformed allowlist" do
      scope = start_scope(profiles: %{})

      assert {:error, {:invalid_workflow_option, :profiles, "worker"}} =
               Workflow.run(handle(scope), "return 1", profiles: "worker")

      assert {:error, {:invalid_workflow_option, :profiles, ["worker", ""]}} =
               Workflow.run(handle(scope), "return 1", profiles: ["worker", ""])
    end
  end

  describe "the workflow's owner" do
    test "cancels the workflow and its runs when the owner terminates" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :block)})
      test_pid = self()

      owner =
        spawn(fn ->
          script = ~s|return tackle.await(tackle.spawn("worker", "go")).text|
          {:ok, ref} = Workflow.run(handle(scope), script, owner: self())
          send(test_pid, {:workflow_started, ref})
          Process.sleep(:infinity)
        end)

      assert_receive {:workflow_started, ref}, 2_000
      assert_receive {:agent_called, agent_pid}, 2_000
      assert Process.alive?(agent_pid)

      Process.exit(owner, :kill)

      assert_eventually(fn -> not Process.alive?(agent_pid) end)
      assert_eventually(fn -> Workflow.await(ref) == {:error, :not_found} end, 400)
    end

    test "rejects an owner that is not a process" do
      scope = start_scope(profiles: %{})

      assert {:error, {:invalid_workflow_option, :owner, :nobody}} =
               Workflow.run(handle(scope), "return 1", owner: :nobody)
    end
  end
end
