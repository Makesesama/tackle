defmodule Tackle.Runtime.PackageTest do
  use ExUnit.Case, async: true

  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ScopeSpec

  defmodule Backend do
    @behaviour Tackle.Runtime.AgentBackend

    def validate_spec(%AgentSpec{config: %{value: _value}}), do: :ok
    def validate_spec(%AgentSpec{config: config}), do: {:error, {:invalid_config, config}}
    def child_spec(_spec, _context), do: {Task, fn -> :ok end}
    def call(_pid, _operation, _args), do: :ok
  end

  test "scope specs validate opaque agent configuration through the host backend" do
    root = AgentSpec.new!(name: "root", config: %{value: :root})
    child = AgentSpec.new!(name: "child", config: %{value: :child})

    assert {:ok, scope} =
             ScopeSpec.new(
               backend: Backend,
               root_spec: root,
               profiles: %{"child" => child}
             )

    assert scope.backend == Backend
    assert {:ok, ^child} = ScopeSpec.resolve_profile(scope, "child")
  end

  test "backend validation failures are explicit" do
    root = AgentSpec.new!(name: "root", config: %{bad: true})

    assert {:error, {:invalid_config, %{bad: true}}} =
             ScopeSpec.new(backend: Backend, root_spec: root)
  end
end
