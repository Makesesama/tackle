defmodule Tackle.Workflow.MeterTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Tackle.Workflow.TestSupport

  alias Tackle.Lib.Event
  alias Tackle.Workflow
  alias Tackle.Workflow.Meter
  alias Tackle.Workflow.Tool, as: WorkflowTool

  @workflow_timeout 5_000

  # One settled model call, the way the loop reports it: the provider's usage
  # (streamed while the call runs), then the step it settled.
  defp usage(total) do
    [Event.usage(%{total_tokens: total}), step_end(%{total_tokens: total})]
  end

  defp step_end(usage), do: Event.new(:step_end, %{iteration: 1, usage: usage})
  defp tool_end, do: Event.new(:tool_end, %{tool_call_id: "call", name: "bash"})
  defp tool_error, do: Event.new(:tool_error, %{tool_call_id: "call", name: "bash"})

  defp run(scope, script, opts \\ []) do
    {:ok, ref} = Workflow.run(handle(scope), script, opts)
    Workflow.await(ref, @workflow_timeout)
  end

  describe "run facts" do
    test "an awaited outcome carries the tokens and tool calls its run reported" do
      events = usage(100) ++ [tool_end(), tool_error()] ++ usage(50) ++ [tool_end()]

      scope =
        start_scope(
          profiles: %{
            "worker" => agent_spec("worker", events: events),
            "idle" => agent_spec("idle")
          }
        )

      script = """
      local busy = tackle.await(tackle.spawn("worker", "work"))
      local idle = tackle.await(tackle.spawn("idle", "rest"))
      return busy.tokens, busy.tool_calls, busy.failed_tool_calls,
        idle.tokens, idle.tool_calls, idle.failed_tool_calls
      """

      assert {:ok, [150, 3, 1, 0, 0, 0]} = run(scope, script)
    end

    test "fan-out results carry the facts of their own run" do
      scope =
        start_scope(
          profiles: %{
            "small" => agent_spec("small", events: usage(10) ++ [tool_end()]),
            "large" => agent_spec("large", events: usage(300) ++ [tool_error(), tool_error()])
          }
        )

      script = """
      local results = tackle.parallel({"small", "large", "small"}, function(profile)
        return profile, "go"
      end)
      local out = {}
      for _, r in ipairs(results) do
        out[#out + 1] = r.tokens .. "/" .. r.tool_calls .. "/" .. r.failed_tool_calls
      end
      return table.concat(out, " ")
      """

      assert {:ok, ["10/1/0 300/2/2 10/1/0"]} = run(scope, script)
    end

    test "a failed run still reports the tokens it spent" do
      scope =
        start_scope(
          profiles: %{"worker" => agent_spec("worker", mode: :error, events: usage(70))}
        )

      script = """
      local failed = tackle.await(tackle.spawn("worker", "work"))
      return failed.ok, failed.tokens, tackle.budget().used
      """

      assert {:ok, [false, 70, 70]} = run(scope, script)
    end

    test "an observed workflow both meters and forwards its runs' events" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", events: usage(30))})
      test_pid = self()
      observer = fn event -> send(test_pid, {:progress, event}) end

      script = ~s{return tackle.await(tackle.spawn("worker", "w")).tokens}
      assert {:ok, [30]} = run(scope, script, on_event: observer)

      assert_received {:progress,
                       %{type: :run_event, profile: "worker", event: %Event{type: :step_end}}}
    end

    test "provider usage without a total is counted from its token buckets" do
      events = [step_end(%{input_tokens: 40, output_tokens: 2})]
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", events: events)})

      assert {:ok, [42]} = run(scope, ~s{return tackle.await(tackle.spawn("worker", "w")).tokens})
    end

    test "a streamed model call is counted once, however often it reports usage" do
      events = [
        Event.usage(%{total_tokens: 90}),
        Event.usage(%{total_tokens: 100}),
        step_end(%{total_tokens: 100}),
        # A step whose settlement carries no usage falls back to the streamed one.
        Event.usage(%{total_tokens: 7}),
        step_end(nil)
      ]

      scope = start_scope(profiles: %{"worker" => agent_spec("worker", events: events)})

      script = ~s{return tackle.await(tackle.spawn("worker", "w")).tokens, tackle.budget().used}
      assert {:ok, [107, 107]} = run(scope, script)
    end

    test "a malformed usage event neither counts nor breaks the run" do
      events = [Event.new(:usage, %{usage: 12}), step_end("lots"), tool_end()]
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", events: events)})

      script = """
      local r = tackle.await(tackle.spawn("worker", "w"))
      return r.ok, r.tokens, r.tool_calls
      """

      assert {:ok, [true, 0, 1]} = run(scope, script)
    end
  end

  describe "token budget" do
    test "without a budget the workflow reports only what it used" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", events: usage(25))})

      script = """
      tackle.await(tackle.spawn("worker", "a"))
      tackle.await(tackle.spawn("worker", "b"))
      local budget = tackle.budget()
      return budget.used, budget.limit, budget.remaining
      """

      assert {:ok, [50, nil, nil]} = run(scope, script)
    end

    test "an exhausted budget refuses new spawns with a catchable error" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", events: usage(60))})

      script = """
      local first = tackle.await(tackle.spawn("worker", "a"))
      local before = tackle.budget()
      local second = tackle.await(tackle.spawn("worker", "b"))
      local after = tackle.budget()
      local ok, err = pcall(tackle.spawn, "worker", "c")
      return before.remaining, after.used, after.remaining, ok, err
      """

      assert {:ok, [40, 120, 0, false, message]} = run(scope, script, token_budget: 100)
      assert message =~ "token budget exhausted (used 120 of 100 tokens)"
    end

    test "a fan-out reports items it could not start once the budget is used up" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", events: usage(80))})

      script = """
      local results = tackle.parallel({"a", "b", "c"}, function(item)
        return "worker", item
      end, {limit = 1})
      local out = {}
      for _, r in ipairs(results) do
        out[#out + 1] = r.status .. ":" .. r.tokens
      end
      return table.concat(out, " "), results[3].text
      """

      assert {:ok, ["ok:80 ok:80 budget_exhausted:0", text]} =
               run(scope, script, token_budget: 150)

      assert text =~ "token budget exhausted"
    end

    test "an invalid budget is rejected before the workflow starts" do
      scope = start_scope(profiles: %{})

      for budget <- [0, -1, 1.5, "100"] do
        assert {:error, {:invalid_workflow_option, :token_budget, ^budget}} =
                 Workflow.run(handle(scope), "return 1", token_budget: budget)
      end
    end
  end

  describe "the run_workflow tool budget" do
    defp run_tool(scope, script, opts) do
      args = Map.merge(%{"script" => script}, Keyword.get(opts, :args, %{}))
      context = opts |> Keyword.get(:context, %{}) |> Map.put_new(:runtime, handle(scope))
      WorkflowTool.run(args, context)
    end

    @budget_script "return tackle.budget().limit"

    test "a requested budget can only narrow the host's ceiling" do
      scope = start_scope(profiles: %{})
      context = %{workflow_token_budget: 1_000}

      assert {:ok, "1000"} = run_tool(scope, @budget_script, context: context)

      assert {:ok, "400"} =
               run_tool(scope, @budget_script,
                 context: context,
                 args: %{"token_budget" => 400}
               )

      assert {:ok, "1000"} =
               run_tool(scope, @budget_script,
                 context: context,
                 args: %{"token_budget" => 5_000}
               )

      assert {:ok, "250"} = run_tool(scope, @budget_script, args: %{"token_budget" => 250})
      assert {:ok, "nil"} = run_tool(scope, @budget_script, [])
    end

    test "malformed budgets are reported instead of guessed" do
      scope = start_scope(profiles: %{})

      assert {:error, "token_budget must be a positive integer"} =
               run_tool(scope, @budget_script, args: %{"token_budget" => 0})

      assert {:error, "workflow_token_budget must be a positive integer"} =
               run_tool(scope, @budget_script, context: %{workflow_token_budget: "lots"})
    end
  end

  describe "Meter" do
    test "ignores events without accountable facts" do
      meter = Meter.new()
      Meter.record(meter, "run", Event.new(:message_delta, %{delta: "hi"}))
      Meter.record(meter, "run", Event.usage(nil))
      Meter.record(meter, "run", Event.usage(%{total_tokens: 5}))
      Meter.record(meter, "run", :not_an_event)

      assert Meter.run_facts(meter, "run") == %{
               "tokens" => 0,
               "tool_calls" => 0,
               "failed_tool_calls" => 0
             }
    end

    test "drops events that arrive after the workflow's table is gone" do
      parent = self()

      spawn(fn -> send(parent, {:meter, Meter.new(10)}) end)
      assert_receive {:meter, meter}

      assert_eventually(fn -> :ets.info(meter.table) == :undefined end)
      assert :ok = Meter.record(meter, "run", step_end(%{total_tokens: 5}))
    end
  end
end
