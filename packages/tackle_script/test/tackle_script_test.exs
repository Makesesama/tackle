defmodule Tackle.ScriptTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Tackle.Script.TestSupport

  alias Tackle.Runtime
  alias Tackle.Script

  @script_timeout 5_000

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

    assert {:ok, ref} = Script.run(handle(scope), script)
    assert {:ok, ["implement: plan: map the code"]} = Script.await(ref, @script_timeout)
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

    assert {:ok, ref} = Script.run(handle(scope), script)

    assert_receive {:agent_called, first_agent}, 2_000
    assert_receive {:agent_called, second_agent}, 2_000

    # Answer out of launch order; correlation must still be unambiguous.
    send(second_agent, {:respond, "second"})
    send(first_agent, {:respond, "first"})

    assert {:ok, ["first|second"]} = Script.await(ref, @script_timeout)
  end

  test "failed runs return outcome tables so scripts own the failure policy" do
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

    assert {:ok, ref} = Script.run(handle(scope), script)
    assert {:ok, ["recovered from: error"]} = Script.await(ref, @script_timeout)
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

    assert {:ok, ref} = Script.run(handle(scope), script)
    assert {:ok, [message]} = Script.await(ref, @script_timeout)
    assert message =~ "caught:"
    assert message =~ "unknown_profile"
  end

  test "an uncaught script error settles with the failing source line" do
    scope = start_scope(profiles: %{})

    assert {:ok, ref} = Script.run(handle(scope), ~s|tackle.spawn("missing", "go")|)

    assert {:error, %{message: message}} = Script.await(ref, @script_timeout)
    assert message =~ "unknown_profile"
  end

  test "cancelling a script cancels the worker and its outstanding runs" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :block)})

    script = """
    local run = tackle.spawn("worker", "go")
    return tackle.await(run).text
    """

    assert {:ok, ref} = Script.run(handle(scope), script)

    assert_receive {:agent_called, agent_pid}, 2_000

    assert :ok = Script.cancel(ref, :user_cancelled)
    assert {:error, {:cancelled, :user_cancelled}} = Script.await(ref, @script_timeout)

    assert_eventually(fn -> not Process.alive?(agent_pid) end)
  end

  test "the script deadline bounds a blocked flow" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :block)})

    script = """
    return tackle.await(tackle.spawn("worker", "go")).text
    """

    assert {:ok, ref} = Script.run(handle(scope), script, timeout: 100)
    assert {:error, {:cancelled, :script_timeout}} = Script.await(ref, @script_timeout)
  end

  test "the instruction budget stops spin loops that never await" do
    scope = start_scope(profiles: %{})

    assert {:ok, ref} = Script.run(handle(scope), "while true do end", max_instructions: 10_000)

    assert {:error, %{message: message}} = Script.await(ref, @script_timeout)
    assert message =~ "instruction budget exceeded"
  end

  test "script syntax errors settle as compile errors" do
    scope = start_scope(profiles: %{})

    assert {:ok, ref} = Script.run(handle(scope), "local = broken")
    assert {:error, {:script_compile_error, message}} = Script.await(ref, @script_timeout)
    assert message =~ "Failed to compile Lua"
  end

  test "sandboxed stdlib functions are unavailable to scripts" do
    scope = start_scope(profiles: %{})

    script = """
    local ok, err = pcall(function()
      os.execute("touch /tmp/tackle-script-escape")
    end)
    return ok
    """

    assert {:ok, ref} = Script.run(handle(scope), script)
    assert {:ok, [false]} = Script.await(ref, @script_timeout)
    refute File.exists?("/tmp/tackle-script-escape")
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
             Script.run(handle(scope), script,
               log: fn message -> send(test_pid, {:log, message}) end
             )

    assert {:ok, ["go"]} = Script.await(ref, @script_timeout)

    assert_received {:log, "phase one"}
    assert_received {:log, "phase two: go"}
  end

  test "a completed script releases its registry entry" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

    script = """
    return tackle.await(tackle.spawn("worker", "go")).text
    """

    assert {:ok, ref} = Script.run(handle(scope), script)
    assert {:ok, ["go"]} = Script.await(ref, @script_timeout)

    assert_eventually(fn -> Script.await(ref) == {:error, :not_found} end)
  end

  test "stopping the scope tears down a running script and its runs" do
    scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :block)})

    script = """
    return tackle.await(tackle.spawn("worker", "go")).text
    """

    assert {:ok, ref} = Script.run(handle(scope), script)
    assert_receive {:agent_called, agent_pid}, 2_000

    :ok = Runtime.stop_scope(scope.scope_ref)

    assert_eventually(fn -> not Process.alive?(agent_pid) end)
    assert {:error, :not_found} = Script.await(ref)
  end
end
