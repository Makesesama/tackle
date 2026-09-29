Code.require_file("../../../bench/support.exs", __DIR__)
Code.require_file("support.exs", __DIR__)

defmodule Tackle.Runtime.Bench.WorkflowStart do
  alias Tackle.AgentScope.Coordinator
  alias Tackle.Runtime.{AgentSpec, Limits, Registry, ScopeSpec}
  alias Tackle.Runtime.Bench

  def setup(count) do
    root = AgentSpec.new!(name: "root", config: %{}, allow_delegation: true)
    worker = AgentSpec.new!(name: "worker", config: Bench.input(10))
    limits = Limits.new!(max_agents_per_fleet: count + 3, max_children_per_agent: count + 3)

    spec =
      ScopeSpec.new!(
        backend: Tackle.Runtime.Bench.Backend,
        root_spec: root,
        profiles: %{"worker" => worker},
        limits: limits
      )

    {:ok, scope} = Tackle.Runtime.start_scope(spec)
    {:ok, coordinator} = Registry.coordinator(scope.scope_ref)

    # Pending reservations are enough to exercise the fleet snapshot without
    # starting N backend processes. Setup and cleanup are outside the timed job.
    for _ <- 1..count do
      {:ok, _admission} = Coordinator.admit_agent(coordinator, scope.root_agent_ref, worker)
    end

    scope
  end
end

alias Tackle.Runtime.Bench
alias Tackle.Runtime.Bench.WorkflowStart

Tackle.Bench.run(
  %{
    "workflow / start + await (fleet populated; cleanup excluded)" =>
      {&Bench.workflow/1,
       before_each: &WorkflowStart.setup/1, after_each: &Bench.finish_workflow/1}
  },
  inputs: Map.new([1, 100, 500], &{"#{&1} pending agents", &1}),
  memory_time: 0,
  reduction_time: 0
)
