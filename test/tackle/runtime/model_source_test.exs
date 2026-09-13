defmodule Tackle.Runtime.ModelSourceTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentSpec, Outcome}
  alias Tackle.Thinking

  test "model source is trusted, validated, and configured by default" do
    assert agent_spec("worker").model_source == :configured

    assert {:ok, %{model_source: :parent}} =
             AgentSpec.new(name: "worker", config: config(), model_source: :parent)

    assert {:error, {:invalid_model_source, "parent"}} =
             AgentSpec.new(name: "worker", config: config(), model_source: "parent")
  end

  test "parent selection is resolved per request without copying other parent options" do
    child = %{
      agent_spec("worker", tools: [Tackle.Tools.Read], context: %{child: true})
      | model_source: :parent
    }

    scope =
      start_scope(
        root: [allow_delegation: true, llm_opts: [content: "parent-only"]],
        profiles: %{"worker" => child}
      )

    assert {:ok, _snapshot} =
             Tackle.reconfigure(scope.root_agent_ref, model: "test/child", thinking: "high")

    assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, "worker", "inspect")
    assert %Outcome{status: :ok, agent_state: state} = Runtime.await(run, 5_000)
    assert state.llm.ref == "test/child"
    assert Thinking.from_llm_opts(state.llm_opts) == "high"
    assert Tackle.Lib.last_answer(state) == "answer"
    assert state.context.child
    assert state.tools == [Tackle.Tools.Read]
    refute state.context.runtime.allow_delegation

    assert {:ok, _snapshot} = Tackle.reconfigure(scope.root_agent_ref, thinking: "off")
    assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, "worker", "again")
    assert %Outcome{status: :ok, agent_state: state} = Runtime.await(run, 5_000)
    assert Thinking.from_llm_opts(state.llm_opts) == "off"
    refute Keyword.has_key?(state.llm_opts, :reasoning_effort)
  end

  test "configured profiles do not follow the parent" do
    child = agent_spec("fixed", model: "test/echo", llm_opts: [reasoning_effort: "low"])
    scope = start_scope(root: [allow_delegation: true], profiles: %{"fixed" => child})

    assert {:ok, _snapshot} =
             Tackle.reconfigure(scope.root_agent_ref, model: "test/child", thinking: "high")

    assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, "fixed", "inspect")
    assert %Outcome{status: :ok, agent_state: state} = Runtime.await(run, 5_000)
    assert state.llm.ref == "test/echo"
    assert Thinking.from_llm_opts(state.llm_opts) == "low"
  end

  test "unsupported parent model fails before admitting a child" do
    child = %{agent_spec("restricted") | model_source: :parent}
    child = %{child | config: %{child.config | adapters: []}}
    scope = start_scope(root: [allow_delegation: true], profiles: %{"restricted" => child})

    assert {:error, _reason} =
             Runtime.request_agent(scope.root_agent_ref, "restricted", "inspect")

    assert {:ok, %{agent_count: 1}} = Runtime.scope_snapshot(scope.scope_ref)
    refute_received {:adapter_called, _pid, _model, _opts}
  end

  test "already running children keep their selection" do
    child = %{agent_spec("worker", mode: :manual) | model_source: :parent}
    scope = start_scope(root: [allow_delegation: true], profiles: %{"worker" => child})
    assert {:ok, run} = Runtime.request_agent(scope.root_agent_ref, "worker", "inspect")
    assert_receive {:adapter_called, task, "echo", _opts}, 5_000

    assert {:ok, _snapshot} =
             Tackle.reconfigure(scope.root_agent_ref, model: "test/child", thinking: "high")

    send(task, {:respond, "done"})
    assert %Outcome{status: :ok, agent_state: state} = Runtime.await(run, 5_000)
    assert state.llm.ref == "test/echo"
    assert Thinking.from_llm_opts(state.llm_opts) == "off"
  end
end
