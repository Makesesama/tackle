defmodule Tackle.CLI.WorkflowScriptTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.WorkflowScript

  test "outlines literal spawns in source order, ignoring comments" do
    script = """
    -- tackle.spawn("commented", "never runs")
    --[[ tackle.spawn("blocked", "never runs") ]]
    local a = tackle.await(tackle.spawn("scout", "map"))
    local b = tackle.await(tackle.spawn('worker', "fix"))
    local c = tackle.await(tackle.spawn("scout", "again"))
    """

    assert WorkflowScript.outline(script) == %{
             profiles: ["scout", "worker"],
             fan_out?: false,
             lines: 5
           }
  end

  test "parallel callbacks contribute the profiles they return" do
    script = """
    local first = tackle.spawn("planner", "plan")
    local answers = tackle.parallel(items, function(item)
      return "reviewer", "Review " .. item
    end, {limit = 2})
    """

    assert %{profiles: ["planner", "reviewer"], fan_out?: true} =
             WorkflowScript.outline(script)

    # Without tackle.parallel a returned string pair is not a profile.
    assert %{profiles: [], fan_out?: false} =
             WorkflowScript.outline(~s(return "done", "ok"))
  end

  test "summaries chain profiles, count the overflow, and mark fan-out" do
    outline = %{profiles: ~w(a b c d e f), fan_out?: true, lines: 1}
    assert WorkflowScript.summary(outline) == "a → b → c → d +2 more · fan-out"
    assert WorkflowScript.summary(%{outline | profiles: ["a"], fan_out?: false}) == "a"
    assert WorkflowScript.summary(%{outline | profiles: []}) == "fan-out"
    assert WorkflowScript.summary(%{outline | profiles: [], fan_out?: false}) == ""
    assert WorkflowScript.summary(nil) == ""
    assert WorkflowScript.outline(nil) == nil
    assert WorkflowScript.outline("") == nil
  end

  test "reads the line a workflow error names" do
    assert WorkflowScript.error_line("the workflow failed at line 7: boom") == 7
    assert WorkflowScript.error_line("the workflow exceeded its deadline") == nil
    assert WorkflowScript.error_line(nil) == nil
  end
end
