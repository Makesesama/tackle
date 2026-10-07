defmodule Tackle.Tools.ScriptToolTest do
  @moduledoc false

  # The script tool is optional: it lives in `tackle_script` and a host grants
  # it explicitly. These tests are the harness-side proof that the seam is
  # reachable: a real `Tackle.Coding` scope can hand the tool to its root agent,
  # and a durable session then runs a Lua workflow that delegates to the
  # session's own allowlisted profiles.

  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Coding
  alias Tackle.Script.Tool, as: ScriptTool

  setup do
    home = tmp_home()
    {:ok, home: home}
  end

  test "the script tool is opt-in, not part of the default tool set" do
    refute ScriptTool in Tackle.Tools.default()
  end

  test "a coding scope grants the script tool and narrows the profiles scripts may spawn", ctx do
    assert {:ok, spec} =
             Coding.scope_spec(
               [
                 available_adapters: [Tackle.Test.Adapter],
                 root_tools: [ScriptTool],
                 overrides: [
                   model: "test/echo",
                   context: %{script_profiles: ["worker"]}
                 ],
                 cwd: ctx.home,
                 env: %{"TACKLE_HOME" => ctx.home}
               ],
               nil
             )

    assert ScriptTool in spec.root_spec.config.tools
    assert spec.root_spec.allow_delegation
    assert spec.root_spec.config.context[:script_profiles] == ["worker"]
    assert "worker" in Map.keys(spec.profiles)
  end

  test "a durable session runs a scripted workflow and returns its answer", ctx do
    tool_call = %{
      "id" => "call_script",
      "name" => "run_script",
      "arguments" => %{
        "script" => """
        local findings = tackle.await(tackle.spawn("scout", "map the code paths"))
        local fix = tackle.await(tackle.spawn("worker", "implement: " .. findings.text))
        return fix.text
        """
      }
    }

    scope =
      start_durable_scope(
        home: ctx.home,
        root: [
          allow_delegation: true,
          tools: [ScriptTool],
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "final answer"]
        ],
        profiles: %{
          "scout" => agent_spec("scout", content: "scout finding"),
          "worker" => agent_spec("worker", content: "worker answer")
        }
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "run the workflow")

    assert_receive {:tackle_turn_finished, session_id, ^turn_id, {:ok, state}}, 5_000
    assert session_id == snapshot.session_id
    assert Tackle.Lib.last_answer(state) == "final answer"

    # The script's returned value is the tool result the model sees, and the
    # durable session recorded it next to the tool intent.
    assert "worker answer" in tool_results(state)

    # The worker's step received the previous step's answer, so the script — not
    # the root agent — composed the child prompts.
    assert "implement: scout finding" in sent_prompts()

    assert {:ok, stored} = Tackle.inspect_session(session_id, home: ctx.home)

    assert Enum.any?(
             stored.messages,
             &(&1["role"] == "tool" and &1["content"] == "worker answer")
           )
  end

  test "a session that narrows the allowlist refuses a profile the script may not spawn", ctx do
    tool_call = %{
      "id" => "call_script",
      "name" => "run_script",
      "arguments" => %{
        "script" => """
        local ok, err = pcall(function() tackle.spawn("worker", "go") end)
        if ok then return "spawned" end
        return tostring(err)
        """
      }
    }

    scope =
      start_durable_scope(
        home: ctx.home,
        root: [
          allow_delegation: true,
          tools: [ScriptTool],
          context: %{script_profiles: ["scout"]},
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "final answer"]
        ],
        profiles: %{
          "scout" => agent_spec("scout", content: "scout finding"),
          "worker" => agent_spec("worker", content: "worker answer")
        }
      )

    {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "run the workflow")

    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, state}}, 5_000
    assert Tackle.Lib.last_answer(state) == "final answer"

    assert [result] = tool_results(state)
    assert result =~ ~s|profile "worker" is not allowlisted for scripts|
  end

  test "cancelling the turn cancels the script and the run it started", ctx do
    tool_call = %{
      "id" => "call_script",
      "name" => "run_script",
      "arguments" => %{
        "script" => ~s|return tackle.await(tackle.spawn("worker", "go")).text|
      }
    }

    scope =
      start_durable_scope(
        home: ctx.home,
        root: [
          allow_delegation: true,
          tools: [ScriptTool],
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "final answer"]
        ],
        profiles: %{"worker" => agent_spec("worker", mode: :block, timeout: 60_000)}
      )

    {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "run the workflow")

    # The script is mid-flight: the run it spawned is blocked in its adapter.
    run = await_child_call("go")

    assert :ok = Tackle.cancel(scope.root_agent_ref)
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:cancelled, _state}}, 5_000

    # The tool call owns the script, so cancelling the turn cancels the script
    # and every run under it. Without that link the blocked run would idle for
    # its own 60-second window instead of ending promptly.
    assert_eventually(fn -> not Process.alive?(run) end)
  end

  # `Tackle.Test.Runtime.eventually/2` reports a timeout as `:timeout`.
  defp assert_eventually(fun, attempts \\ 300), do: assert(:ok = eventually(fun, attempts))

  defp tool_results(state) do
    state.messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map(& &1.content)
  end

  # The process answering `prompt` for a delegated run. The root agent's own
  # request is answered first, so the caller's prompt identifies its call.
  defp await_child_call(prompt) do
    receive do
      {:adapter_called, pid, _model, opts} ->
        if prompt in user_contents(opts), do: pid, else: await_child_call(prompt)
    after
      2_000 -> flunk("no delegated run was asked to answer #{inspect(prompt)}")
    end
  end

  # Every user message the deterministic test adapter was asked to answer, in
  # mailbox order.
  defp sent_prompts do
    receive do
      {:adapter_called, _pid, _model, opts} -> user_contents(opts) ++ sent_prompts()
    after
      0 -> []
    end
  end

  defp user_contents(opts) do
    opts
    |> Keyword.get(:messages, [])
    |> Enum.filter(&(Map.get(&1, :role) == :user))
    |> Enum.map(&Map.get(&1, :content))
  end
end
