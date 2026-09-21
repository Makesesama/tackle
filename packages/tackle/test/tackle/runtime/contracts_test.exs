defmodule Tackle.Runtime.ContractsTest do
  use ExUnit.Case, async: true

  alias Tackle.Config
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Ref
  alias Tackle.Runtime.RunRef
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Runtime.WorkflowRef

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "contracts"

    @impl true
    def models, do: ["test"]

    @impl true
    def generate(_schema, _opts) do
      {:ok, %{data: %{"content" => "ok", "tool_calls" => []}, usage: nil, model: "test"}}
    end
  end

  describe "identifiers and references" do
    test "generates valid unique identifiers" do
      first = ID.generate()
      second = ID.generate()

      assert ID.valid?(first)
      assert ID.valid?(second)
      refute first == second
      refute ID.valid?("")
      refute ID.valid?(nil)
      refute ID.valid?(String.duplicate("a", 129))
    end

    test "builds and validates every reference type" do
      scope_id = ID.generate()
      agent_id = ID.generate()
      workflow_id = ID.generate()
      run_id = ID.generate()

      assert {:ok, %ScopeRef{scope_id: ^scope_id} = scope_ref} = ScopeRef.new(scope_id)
      assert {:ok, %AgentRef{} = agent_ref} = AgentRef.new(scope_id, agent_id)
      assert {:ok, %WorkflowRef{} = workflow_ref} = WorkflowRef.new(scope_id, workflow_id)
      assert {:ok, %RunRef{} = run_ref} = RunRef.new(scope_id, run_id)

      assert Ref.valid?(scope_ref)
      assert Ref.valid?(agent_ref)
      assert Ref.valid?(workflow_ref)
      assert Ref.valid?(run_ref)
      refute Ref.valid?(%{scope_id: scope_id})
      refute Ref.valid?("not-a-ref")
    end

    test "rejects invalid identifiers with explicit errors" do
      assert {:error, {:invalid_scope_id, nil}} = ScopeRef.new(nil)
      assert {:error, {:invalid_agent_id, ""}} = AgentRef.new("scope", "")
      assert {:error, {:invalid_workflow_id, 123}} = WorkflowRef.new("scope", 123)
      assert {:error, {:invalid_run_id, nil}} = RunRef.new("scope", nil)
    end

    test "derives a shared scope id and unique registry keys" do
      scope_id = ID.generate()
      agent_id = ID.generate()

      scope_ref = ScopeRef.new!(scope_id)
      agent_ref = AgentRef.new!(scope_id, agent_id)

      assert Ref.scope_id(agent_ref) == scope_id
      assert Ref.scope_ref(agent_ref) == scope_ref
      assert Ref.registry_key(scope_ref) == {:scope, scope_id}
      assert Ref.registry_key(agent_ref) == {:agent, scope_id, agent_id}

      assert Ref.registry_key(WorkflowRef.new!(scope_id, agent_id)) ==
               {:workflow, scope_id, agent_id}

      assert Ref.registry_key(RunRef.new!(scope_id, agent_id)) == {:run, scope_id, agent_id}
    end

    test "references compare structurally and never contain process identifiers" do
      ref = AgentRef.new!(ID.generate(), ID.generate())

      assert ref == AgentRef.new!(ref.scope_id, ref.agent_id)
      refute inspect(ref) =~ "#PID"
    end
  end

  describe "limits" do
    test "provides accepted defaults" do
      limits = Limits.default()

      assert limits.max_agents_per_fleet == 16
      assert limits.max_concurrent_turns == 8
      assert limits.max_spawn_depth == 3
      assert limits.max_children_per_agent == 4
      assert limits.max_pending_requests == 0
      assert limits.run_timeout > 0
      assert limits.workflow_timeout > 0
    end

    test "validates values and rejects unknown keys" do
      assert {:ok, %Limits{max_spawn_depth: 1}} = Limits.new(max_spawn_depth: 1)

      assert {:error, {:invalid_limit, :max_agents_per_fleet, 0}} =
               Limits.new(max_agents_per_fleet: 0)

      assert {:error, {:unknown_limits, [:nope]}} = Limits.new(nope: 1)
    end

    test "inheritance never widens a child" do
      parent = Limits.new!(max_agents_per_fleet: 4, max_spawn_depth: 2, run_timeout: 1_000)

      child =
        Limits.new!(
          max_agents_per_fleet: 100,
          max_spawn_depth: 9,
          max_children_per_agent: 1,
          run_timeout: 60_000
        )

      inherited = Limits.inherit(parent, child)

      assert inherited.max_agents_per_fleet == 4
      assert inherited.max_spawn_depth == 2
      assert inherited.max_children_per_agent == 1
      assert inherited.run_timeout == 1_000
    end
  end

  describe "agent spec and scope spec" do
    test "resolves named profiles from the trusted allowlist only" do
      spec = agent_spec("researcher")

      assert {:ok, %ScopeSpec{} = scope_spec} =
               ScopeSpec.new(root_spec: agent_spec("root"), profiles: %{"researcher" => spec})

      assert {:ok, ^spec} = ScopeSpec.resolve_profile(scope_spec, "researcher")

      assert {:error, {:unknown_profile, "missing"}} =
               ScopeSpec.resolve_profile(scope_spec, "missing")

      assert {:error, {:unknown_profile, "Elixir.String"}} =
               ScopeSpec.resolve_profile(scope_spec, "Elixir.String")
    end

    test "resolves function profiles and reports failures" do
      scope_spec =
        ScopeSpec.new!(
          root_spec: agent_spec("root"),
          profiles: %{
            "ok" => fn -> {:ok, agent_spec("ok")} end,
            "boom" => fn -> {:error, :nope} end,
            "bad" => fn -> :not_a_spec end
          }
        )

      assert {:ok, %AgentSpec{name: "ok"}} = ScopeSpec.resolve_profile(scope_spec, "ok")

      assert {:error, {:profile_failed, "boom", :nope}} =
               ScopeSpec.resolve_profile(scope_spec, "boom")

      assert {:error, {:invalid_profile_result, "bad", :not_a_spec}} =
               ScopeSpec.resolve_profile(scope_spec, "bad")
    end

    test "rejects invalid specs" do
      assert {:error, {:invalid_agent_name, ""}} = AgentSpec.new(name: "", config: config())
      assert {:error, {:invalid_agent_config, :nope}} = AgentSpec.new(name: "x", config: :nope)

      assert {:error, {:invalid_agent_timeout, 0}} =
               AgentSpec.new(name: "x", config: config(), timeout: 0)

      assert {:error, {:invalid_profile, "bad", :nope}} =
               ScopeSpec.new(root_spec: agent_spec("root"), profiles: %{"bad" => :nope})
    end
  end

  describe "outcomes" do
    test "projects library settlements into lib results" do
      state = Tackle.Lib.new(llm: config().llm, system_prompt: "x")

      assert {:ok, ^state} = Outcome.new(:ok, agent_state: state) |> Outcome.to_lib_result()
      assert {:error, ^state} = Outcome.new(:error, agent_state: state) |> Outcome.to_lib_result()

      assert {:cancelled, ^state} =
               Outcome.new(:cancelled, agent_state: state) |> Outcome.to_lib_result()
    end

    test "distinguishes runtime failures from library errors" do
      runtime = Outcome.new(:runtime_error, reason: :boom)
      timeout = Outcome.new(:timeout, reason: :slow)
      rejected = Outcome.new(:rejected, reason: :limit)

      refute Outcome.library?(runtime)
      refute Outcome.library?(timeout)
      refute Outcome.library?(rejected)

      assert {:error, {:runtime_error, :boom}} = Outcome.to_lib_result(runtime)
      assert {:error, {:timeout, :slow}} = Outcome.to_lib_result(timeout)
      assert {:error, {:rejected, :limit}} = Outcome.to_lib_result(rejected)
      assert Outcome.message(runtime) == "runtime_error: :boom"
    end

    test "requires an agent state for library settlements" do
      assert_raise ArgumentError, fn -> Outcome.new(:ok) end
    end
  end

  defp agent_spec(name) do
    AgentSpec.new!(name: name, config: config())
  end

  defp config do
    {:ok, config} =
      Config.new(
        adapters: [Adapter],
        model: "contracts/test",
        tools: [],
        system_prompt: "system"
      )

    config
  end
end
