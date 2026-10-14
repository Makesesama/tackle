Code.require_file("../bench/support.exs", __DIR__)

defmodule Tackle.Runtime.DelegationLimitsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Bench
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.ScopeSpec

  test "a delegating agent gets its scope's limits" do
    limits = Limits.new!(max_children_per_agent: 3, run_timeout: 1_234)
    scope = start_scope(allow_delegation: true, limits: limits)

    assert {:ok, ^limits} = Runtime.delegation_limits(scope.root_agent_ref)
  end

  test "an agent without delegation is refused" do
    scope = start_scope(allow_delegation: false)

    assert {:error, :delegation_not_allowed} = Runtime.delegation_limits(scope.root_agent_ref)
  end

  test "an unknown agent is reported, not granted" do
    scope = start_scope(allow_delegation: true)
    stranger = AgentRef.new!(scope.root_agent_ref.scope_id, ID.generate())

    assert {:error, _reason} = Runtime.delegation_limits(stranger)
  end

  test "an agent of a stopped scope is reported, not granted" do
    scope = start_scope(allow_delegation: true)
    :ok = Runtime.stop_scope(scope.scope_ref)

    assert {:error, _reason} = Runtime.delegation_limits(scope.root_agent_ref)
  end

  test "the agent reference is read from either context key" do
    ref = AgentRef.new!(ID.generate(), ID.generate())

    assert AgentRef.from_context(%{runtime: ref}) == ref
    assert AgentRef.from_context(%{"runtime" => ref}) == ref
    assert AgentRef.from_context(%{runtime: :other}) == nil
    assert AgentRef.from_context(%{}) == nil
    assert AgentRef.from_context(nil) == nil
  end

  defp start_scope(opts) do
    root =
      AgentSpec.new!(
        name: "root",
        config: %{},
        allow_delegation: Keyword.fetch!(opts, :allow_delegation)
      )

    spec =
      ScopeSpec.new!(
        backend: Bench.Backend,
        root_spec: root,
        limits: Keyword.get(opts, :limits, Limits.default())
      )

    {:ok, scope} = Runtime.start_scope(spec)
    on_exit(fn -> Bench.teardown(scope) end)
    scope
  end
end
