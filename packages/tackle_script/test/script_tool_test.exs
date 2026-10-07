defmodule Tackle.Script.ToolTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Tackle.Script.TestSupport

  alias Tackle.Lib.Tool
  alias Tackle.Runtime
  alias Tackle.Script
  alias Tackle.Script.Tool, as: ScriptTool

  @script_timeout 5_000

  # Runs the tool the way a session does: a script argument, plus the host's
  # context (the runtime handle and optional script configuration).
  defp run_script(scope, script, opts \\ []) do
    args = Map.merge(%{"script" => script}, Keyword.get(opts, :args, %{}))
    context = opts |> Keyword.get(:context, %{}) |> Map.put_new(:runtime, handle(scope))

    ScriptTool.run(args, context)
  end

  describe "the run_script tool" do
    test "is a valid Tackle tool" do
      assert ScriptTool.name() == "run_script"
      assert %Tool.Registry{} = Tool.Registry.new([ScriptTool])
    end

    test "runs a workflow and returns the value the script produced" do
      scope =
        start_scope(profiles: %{"scout" => agent_spec("scout"), "worker" => agent_spec("worker")})

      script = """
      local findings = tackle.await(tackle.spawn("scout", "map the code"))
      return tackle.await(tackle.spawn("worker", "implement: " .. findings.text)).text
      """

      assert {:ok, "implement: map the code"} = run_script(scope, script)
    end

    test "returns every value the script produced" do
      scope = start_scope(profiles: %{})

      assert {:ok, "one\ntwo\n3"} = run_script(scope, ~s|return "one", "two", 3|)
      assert {:ok, "nil"} = run_script(scope, "return nil")
      assert {:ok, "(the script returned no values)"} = run_script(scope, "local _ = 1")
    end

    test "reports a script error for a rejected spawn" do
      scope = start_scope(profiles: %{})

      assert {:error, message} = run_script(scope, ~s|return tackle.spawn("ghost", "go")|)
      assert message =~ ~s|the script failed:|
      assert message =~ "unknown_profile"
    end

    test "reports a script that fails to compile" do
      scope = start_scope(profiles: %{})

      assert {:error, message} = run_script(scope, "local = broken")
      assert message =~ "does not compile"
    end

    test "reports a script that exceeds its deadline" do
      limits = Runtime.Limits.new!(workflow_timeout: 150)

      scope =
        start_scope(
          profiles: %{"worker" => agent_spec("worker", mode: :block)},
          limits: limits
        )

      script = ~s|return tackle.await(tackle.spawn("worker", "go")).text|

      # `timeout_ms` may only narrow the scope's own workflow deadline.
      assert {:error, message} =
               run_script(scope, script, args: %{"timeout_ms" => 60_000})

      assert message == "the script exceeded its deadline"
    end

    test "reports a malformed timeout instead of guessing" do
      scope = start_scope(profiles: %{})

      assert {:error, message} = run_script(scope, "return 1", args: %{"timeout_ms" => 0})
      assert message =~ "timeout_ms must be a positive integer"
    end
  end

  describe "the script profile allowlist" do
    test "narrows the profiles a script may spawn" do
      scope =
        start_scope(profiles: %{"scout" => agent_spec("scout"), "worker" => agent_spec("worker")})

      context = %{script_profiles: ["scout"]}

      assert {:ok, "ask"} =
               run_script(
                 scope,
                 ~s|return tackle.await(tackle.spawn("scout", "ask")).text|,
                 context: context
               )

      assert {:error, message} =
               run_script(
                 scope,
                 ~s|return tackle.await(tackle.spawn("worker", "go")).text|,
                 context: context
               )

      assert message =~ ~s|profile "worker" is not allowlisted for scripts|
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
          "for scripts"

      assert {:ok, ^expected} = run_script(scope, script, context: %{script_profiles: ["scout"]})
    end

    test "leaves the decision to the scope when the host does not narrow it" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

      assert {:ok, "go"} =
               run_script(scope, ~s|return tackle.await(tackle.spawn("worker", "go")).text|)
    end

    test "rejects a malformed allowlist instead of guessing" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

      assert {:error, message} = run_script(scope, "return 1", context: %{script_profiles: "w"})
      assert message =~ "script_profiles must be a list of profile names"

      assert {:error, message} =
               run_script(scope, "return 1", context: %{script_profiles: ["worker", 7]})

      assert message =~ "script_profiles must be a list of profile names"
    end
  end

  describe "the tool's permission checks" do
    test "refuses to run without a runtime handle" do
      assert {:error, message} = ScriptTool.run(%{"script" => "return 1"}, %{})
      assert message =~ "no runtime handle"
    end

    test "refuses to run when the agent may not delegate" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})
      context = %{runtime: handle(scope, allow_delegation: false)}

      assert {:error, message} = ScriptTool.run(%{"script" => "return 1"}, context)
      assert message =~ "not permitted"
    end

    test "requires a script argument" do
      scope = start_scope(profiles: %{})
      context = %{runtime: handle(scope)}

      assert {:error, message} = ScriptTool.run(%{}, context)
      assert message =~ "requires a Lua script"
    end
  end

  describe "the script deadline" do
    test "an explicit deadline may only narrow the inherited one" do
      limits = Runtime.Limits.new!(workflow_timeout: 150)

      scope =
        start_scope(
          profiles: %{"worker" => agent_spec("worker", mode: :block)},
          limits: limits
        )

      script = ~s|return tackle.await(tackle.spawn("worker", "go")).text|

      assert {:ok, wider} = Script.run(handle(scope), script, timeout: 60_000)
      assert {:error, {:cancelled, :script_timeout}} = Script.await(wider, @script_timeout)

      assert {:ok, unbounded} = Script.run(handle(scope), script, timeout: :infinity)
      assert {:error, {:cancelled, :script_timeout}} = Script.await(unbounded, @script_timeout)
    end

    test "defaults to the inherited deadline and rejects a malformed one" do
      limits = Runtime.Limits.new!(workflow_timeout: 150)
      scope = start_scope(profiles: %{}, limits: limits)

      assert {:error, {:invalid_script_option, :timeout, "1s"}} =
               Script.run(handle(scope), "return 1", timeout: "1s")

      assert {:error, {:invalid_script_option, :timeout, 0}} =
               Script.run(handle(scope), "return 1", timeout: 0)

      # Without the option the script takes the parent's own deadline.
      assert {:ok, ref} = Script.run(handle(scope), "return 1")
      assert {:ok, [1]} = Script.await(ref, @script_timeout)
    end
  end

  describe "the allowlist at the script seam" do
    test "bounds spawn and parallel when a host narrows it directly" do
      scope =
        start_scope(profiles: %{"scout" => agent_spec("scout"), "worker" => agent_spec("worker")})

      script = """
      local results = tackle.parallel({"scout", "worker"}, function(item)
        return item, "ask:" .. item
      end)
      return results[1].status, results[1].text, results[2].status, results[2].text
      """

      assert {:ok, ref} = Script.run(handle(scope), script, profiles: ["scout"])

      assert {:ok, ["ok", "ask:scout", "spawn_error", reason]} =
               Script.await(ref, @script_timeout)

      assert reason =~ "not allowlisted"
    end

    test "raises a catchable error for a spawn outside the allowlist" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

      script = """
      local ok, err = pcall(function() tackle.spawn("worker", "go") end)
      return ok, tostring(err)
      """

      assert {:ok, ref} = Script.run(handle(scope), script, profiles: ["scout"])
      assert {:ok, [false, message]} = Script.await(ref, @script_timeout)
      assert message =~ "not allowlisted"
    end

    test "an empty allowlist lets a script run but refuse every spawn" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker")})

      script = ~s|return tackle.await(tackle.spawn("worker", "go")).text|

      assert {:ok, ref} = Script.run(handle(scope), script, profiles: [])

      assert {:error, %{message: message}} = Script.await(ref, @script_timeout)
      assert message =~ "not allowlisted"
    end

    test "rejects a malformed allowlist" do
      scope = start_scope(profiles: %{})

      assert {:error, {:invalid_script_option, :profiles, "worker"}} =
               Script.run(handle(scope), "return 1", profiles: "worker")

      assert {:error, {:invalid_script_option, :profiles, ["worker", ""]}} =
               Script.run(handle(scope), "return 1", profiles: ["worker", ""])
    end
  end

  describe "the script's owner" do
    test "cancels the script and its runs when the owner terminates" do
      scope = start_scope(profiles: %{"worker" => agent_spec("worker", mode: :block)})
      test_pid = self()

      owner =
        spawn(fn ->
          script = ~s|return tackle.await(tackle.spawn("worker", "go")).text|
          {:ok, ref} = Script.run(handle(scope), script, owner: self())
          send(test_pid, {:script_started, ref})
          Process.sleep(:infinity)
        end)

      assert_receive {:script_started, ref}, 2_000
      assert_receive {:agent_called, agent_pid}, 2_000
      assert Process.alive?(agent_pid)

      Process.exit(owner, :kill)

      assert_eventually(fn -> not Process.alive?(agent_pid) end)
      assert_eventually(fn -> Script.await(ref) == {:error, :not_found} end, 400)
    end

    test "rejects an owner that is not a process" do
      scope = start_scope(profiles: %{})

      assert {:error, {:invalid_script_option, :owner, :nobody}} =
               Script.run(handle(scope), "return 1", owner: :nobody)
    end
  end
end
