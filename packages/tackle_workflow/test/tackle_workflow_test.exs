defmodule Tackle.WorkflowTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Tackle.Workflow.TestSupport

  alias Tackle.Runtime
  alias Tackle.Workflow

  @workflow_timeout 5_000

  test "a sequential flow feeds each outcome into the next request" do
    scope =
      start_scope(
        profiles: %{
          "scout" => agent_spec("scout"),
          "planner" => agent_spec("planner"),
          "worker" => agent_spec("worker")
        }
      )

    script = """
    local findings = tackle.await(tackle.spawn("scout", "map the code"))
    local plan = tackle.await(tackle.spawn("planner", "plan: " .. findings.text))
    return tackle.await(tackle.spawn("worker", "implement: " .. plan.text)).text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)
    assert {:ok, ["implement: plan: map the code"]} = Workflow.await(ref, @workflow_timeout)
  end

  test "spawned runs overlap and results correlate regardless of completion order" do
    scope =
      start_scope(profiles: %{"researcher" => agent_spec("researcher", mode: :manual)})

    script = """
    local a = tackle.spawn("researcher", "topic a")
    local b = tackle.spawn("researcher", "topic b")
    local first = tackle.await(a)
    local second = tackle.await(b)
    return first.text .. "|" .. second.text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    assert_receive {:agent_called, first_agent}, 2_000
    assert_receive {:agent_called, second_agent}, 2_000

    # Answer out of launch order; correlation must still be unambiguous.
    send(second_agent, {:respond, "second"})
    send(first_agent, {:respond, "first"})

    assert {:ok, ["first|second"]} = Workflow.await(ref, @workflow_timeout)
  end

  test "a fan-out runs one agent per item and reports results in input order" do
    scope = start_scope(profiles: %{"researcher" => agent_spec("researcher")})

    script = """
    local results = tackle.parallel({"alpha", "beta", "gamma"}, function(item, index)
      return "researcher", index .. ":" .. item
    end)
    local out = {}
    for i, result in ipairs(results) do
      out[i] = result.index .. "/" .. result.status .. "/" .. result.text
    end
    return table.concat(out, " | ")
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    assert {:ok, ["1/ok/1:alpha | 2/ok/2:beta | 3/ok/3:gamma"]} =
             Workflow.await(ref, @workflow_timeout)
  end

  test "a fan-out defaults to the scope ceiling and reuses a freed slot" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :manual)})

    script = """
    local results = tackle.parallel({"a", "b", "c", "d", "e"}, function(item, index)
      return "worker", tostring(index)
    end)
    return #results
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    # The default scope limits allow four children, so four runs may overlap.
    called =
      for _ <- 1..4 do
        assert_receive {:agent_called, pid}, 2_000
        pid
      end

    refute_receive {:agent_called, _fifth}, 150

    [first | rest] = called
    send(first, {:respond, "done"})
    assert_receive {:agent_called, fifth}, 2_000

    Enum.each(rest ++ [fifth], &send(&1, {:respond, "done"}))

    assert {:ok, [5]} = Workflow.await(ref, @workflow_timeout)
  end

  test "a fan-out reuses the slot of any settled run, not only the oldest" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :manual)})

    script = """
    local results = tackle.parallel({"a", "b", "c"}, function(item, index)
      return "worker", tostring(index)
    end, {limit = 2})
    local statuses = {}
    for i, result in ipairs(results) do statuses[i] = result.status end
    return table.concat(statuses, ",")
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    assert_receive {:agent_called, oldest}, 2_000
    assert_receive {:agent_called, younger}, 2_000
    refute_receive {:agent_called, _third}, 150

    # The younger run settling is enough for the waiting item: the oldest is
    # still working.
    send(younger, {:respond, "younger"})
    assert_receive {:agent_called, third}, 2_000
    assert Process.alive?(oldest)

    send(oldest, {:respond, "oldest"})
    send(third, {:respond, "third"})

    assert {:ok, ["ok,ok,ok"]} = Workflow.await(ref, @workflow_timeout)
  end

  test "a fan-out reports its item when the scope stays at capacity" do
    limits = Runtime.Limits.new!(max_children_per_agent: 1, max_concurrent_turns: 8)

    scope =
      start_scope(
        profiles: %{
          "holder" => agent_spec("holder", mode: :block),
          "worker" => agent_spec("worker")
        },
        limits: limits
      )

    # The holder occupies the scope's only child slot for the whole fan-out, so
    # nothing the batch itself holds can free the capacity it needs.
    script = """
    local held = tackle.spawn("holder", "hold")
    local results = tackle.parallel({"a"}, function(item) return "worker", item end)
    tackle.cancel(held)
    return results[1].status, results[1].text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    assert {:ok, [status, reason]} = Workflow.await(ref, @workflow_timeout)
    assert status == "capacity"
    assert reason =~ "max_children_per_agent"
  end

  test "a requested fan-out limit is clamped to the scope's own ceiling" do
    limits = Runtime.Limits.new!(max_children_per_agent: 2, max_concurrent_turns: 8)

    scope =
      start_scope(
        profiles: %{"worker" => agent_spec("worker", mode: :manual)},
        limits: limits
      )

    script = """
    local results = tackle.parallel({"a", "b", "c"}, function(item, index)
      return "worker", tostring(index)
    end, {limit = 5})
    return #results
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    assert_receive {:agent_called, first}, 2_000
    assert_receive {:agent_called, second}, 2_000
    refute_receive {:agent_called, _third}, 150

    # Settling a run frees its child slot for the item still waiting, and the
    # runtime's capacity refusal is waited out rather than reported.
    send(first, {:respond, "one"})
    assert_receive {:agent_called, third}, 2_000

    send(second, {:respond, "two"})
    send(third, {:respond, "three"})

    assert {:ok, [3]} = Workflow.await(ref, @workflow_timeout)
  end

  test "a fan-out reports per-item failures instead of raising" do
    scope =
      start_scope(
        profiles: %{
          "worker" => agent_spec("worker", mode: :error),
          "researcher" => agent_spec("researcher")
        }
      )

    script = """
    local results = tackle.parallel({"ok", "failed", "missing", "raised", "not a request"}, function(item)
      if item == "failed" then return "worker", "go" end
      if item == "missing" then return "nope", "go" end
      if item == "raised" then error("callback exploded") end
      if item == "not a request" then return {"profile"} end
      return "researcher", "ask:" .. item
    end)
    local out = {}
    for i, result in ipairs(results) do
      out[i] = result.index .. "/" .. tostring(result.ok) .. "/" .. result.status
    end
    return table.concat(out, " | "), results[4].text, results[5].text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    assert {:ok, [summary, callback_error, bad_request]} = Workflow.await(ref, @workflow_timeout)

    assert summary ==
             "1/true/ok | 2/false/error | 3/false/spawn_error | 4/false/callback_error | " <>
               "5/false/callback_error"

    assert callback_error =~ "callback exploded"

    assert bad_request =~
             "expected two strings and an optional options table (profile, prompt, opts?), got (table)"
  end

  test "a fan-out hands each item to the callback untouched" do
    scope = start_scope(profiles: %{"researcher" => agent_spec("researcher")})

    script = """
    local items = {{name = "alpha"}, {name = "beta"}}
    local identity = 0
    local results = tackle.parallel(items, function(item, index)
      if item == items[index] then identity = identity + 1 end
      return "researcher", item.name
    end)
    return identity, results[1].text, results[2].text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)
    assert {:ok, [2, "alpha", "beta"]} = Workflow.await(ref, @workflow_timeout)
  end

  test "an empty item sequence runs nothing and returns no results" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :manual)})

    script = """
    local results = tackle.parallel({}, function(item) return "worker", item end)
    return #results
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)
    assert {:ok, [0]} = Workflow.await(ref, @workflow_timeout)
    refute_received {:agent_called, _pid}
  end

  test "invalid fan-out arguments raise catchable Lua errors" do
    scope = start_scope(profiles: %{})

    script = """
    local function rejects(fn)
      local ok, err = pcall(fn)
      if ok then return "accepted" end
      return tostring(err)
    end

    local request = function() return "profile", "prompt" end

    return rejects(function() tackle.parallel({alpha = 1}, request) end),
           rejects(function() tackle.parallel({alpha = 1, "item"}, request) end),
           rejects(function() tackle.parallel({[1] = "a", [3] = "c"}, request) end),
           rejects(function() tackle.parallel("alpha", request) end),
           rejects(function() tackle.parallel({"alpha"}, "not a function") end),
           rejects(function() tackle.parallel({"alpha"}, request, {limit = 0}) end),
           rejects(function() tackle.parallel({"alpha"}, request, {limits = 2}) end)
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    assert {:ok, [keyed, mixed, holey, not_a_table, not_a_function, bad_limit, unknown_option]} =
             Workflow.await(ref, @workflow_timeout)

    assert keyed =~ "1..n sequence table"
    assert mixed =~ "1..n sequence table"
    assert holey =~ "1..n sequence table"
    assert not_a_table =~ "1..n sequence table"
    assert not_a_function =~ "requires a function"
    assert bad_limit =~ "positive integer"
    assert unknown_option =~ "unknown tackle.parallel options"
  end

  test "a nested fan-out inside a callback leaves the outer batch intact" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

    script = """
    local results = tackle.parallel({"a", "b"}, function(item)
      if item == "a" then
        local nested = tackle.parallel({"x"}, function() return "worker", "nested" end)
        return "worker", "a:" .. nested[1].text
      end
      return "worker", "b:" .. item
    end)
    return results[1].status, results[1].text, results[2].status, results[2].text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)
    assert {:ok, ["ok", "a:nested", "ok", "b:b"]} = Workflow.await(ref, @workflow_timeout)
  end

  test "cancelling a workflow cancels every run a fan-out started" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :manual)})

    script = """
    return #tackle.parallel({"a", "b"}, function(item)
      return "worker", item
    end, {limit = 2})
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    assert_receive {:agent_called, first}, 2_000
    assert_receive {:agent_called, second}, 2_000

    assert :ok = Workflow.cancel(ref, :user_cancelled)
    assert {:error, {:cancelled, :user_cancelled}} = Workflow.await(ref, @workflow_timeout)

    assert_eventually(fn -> not Process.alive?(first) and not Process.alive?(second) end)
  end

  test "failed runs return outcome tables so workflows own the failure policy" do
    scope =
      start_scope(
        profiles: %{
          "worker" => agent_spec("worker", mode: :error),
          "reviewer" => agent_spec("reviewer")
        }
      )

    script = """
    local outcome = tackle.await(tackle.spawn("worker", "go"))
    if not outcome.ok then
      return "recovered from: " .. outcome.status
    end
    return outcome.text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)
    assert {:ok, ["recovered from: error"]} = Workflow.await(ref, @workflow_timeout)
  end

  test "rejected spawns raise catchable Lua errors with source lines" do
    scope = start_scope(profiles: %{})

    script = """
    local ok, err = pcall(function()
      tackle.spawn("missing", "go")
    end)
    if not ok then
      return "caught: " .. tostring(err)
    end
    return "not reached"
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)
    assert {:ok, [message]} = Workflow.await(ref, @workflow_timeout)
    assert message =~ "caught:"
    assert message =~ "unknown_profile"
  end

  test "an uncaught error settles with the failing source line" do
    scope = start_scope(profiles: %{})

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, ~s|tackle.spawn("missing", "go")|)

    assert {:error, %{message: message}} = Workflow.await(ref, @workflow_timeout)
    assert message =~ "unknown_profile"
  end

  test "cancelling a workflow cancels the worker and its outstanding runs" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :block)})

    script = """
    local run = tackle.spawn("worker", "go")
    return tackle.await(run).text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)

    assert_receive {:agent_called, agent_pid}, 2_000

    assert :ok = Workflow.cancel(ref, :user_cancelled)
    assert {:error, {:cancelled, :user_cancelled}} = Workflow.await(ref, @workflow_timeout)

    assert_eventually(fn -> not Process.alive?(agent_pid) end)
  end

  test "the workflow deadline bounds a blocked flow" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :block)})

    script = """
    return tackle.await(tackle.spawn("worker", "go")).text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script, timeout: 100)
    assert {:error, {:cancelled, :workflow_timeout}} = Workflow.await(ref, @workflow_timeout)
  end

  test "the instruction budget stops spin loops that never await" do
    scope = start_scope(profiles: %{})

    assert {:ok, ref} =
             Workflow.run(scope.root_agent_ref, "while true do end", max_instructions: 10_000)

    assert {:error, %{message: message}} = Workflow.await(ref, @workflow_timeout)
    assert message =~ "instruction budget exceeded"
  end

  test "syntax errors settle as compile errors" do
    scope = start_scope(profiles: %{})

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, "local = broken")
    assert {:error, {:workflow_compile_error, message}} = Workflow.await(ref, @workflow_timeout)
    assert message =~ "Failed to compile Lua"
  end

  test "sandboxed stdlib functions are unavailable in a workflow" do
    scope = start_scope(profiles: %{})

    script = """
    local ok, err = pcall(function()
      os.execute("touch /tmp/tackle-workflow-escape")
    end)
    return ok
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)
    assert {:ok, [false]} = Workflow.await(ref, @workflow_timeout)
    refute File.exists?("/tmp/tackle-workflow-escape")
  end

  test "progress logs reach the host's log callback" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker")})
    test_pid = self()

    script = """
    tackle.log("phase one")
    local outcome = tackle.await(tackle.spawn("worker", "go"))
    tackle.log("phase two: " .. outcome.text)
    return outcome.text
    """

    assert {:ok, ref} =
             Workflow.run(scope.root_agent_ref, script,
               log: fn message -> send(test_pid, {:log, message}) end
             )

    assert {:ok, ["go"]} = Workflow.await(ref, @workflow_timeout)

    assert_received {:log, "phase one"}
    assert_received {:log, "phase two: go"}
  end

  test "a completed workflow releases its registry entry" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

    script = """
    return tackle.await(tackle.spawn("worker", "go")).text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)
    assert {:ok, ["go"]} = Workflow.await(ref, @workflow_timeout)

    assert_eventually(fn -> Workflow.await(ref) == {:error, :not_found} end)
  end

  test "stopping the scope tears down a running workflow and its runs" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :block)})

    script = """
    return tackle.await(tackle.spawn("worker", "go")).text
    """

    assert {:ok, ref} = Workflow.run(scope.root_agent_ref, script)
    assert_receive {:agent_called, agent_pid}, 2_000

    :ok = Runtime.stop_scope(scope.scope_ref)

    assert_eventually(fn -> not Process.alive?(agent_pid) end)
    assert {:error, :not_found} = Workflow.await(ref)
  end
end
