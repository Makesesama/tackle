defmodule Tackle.Agents.DefaultTest do
  use ExUnit.Case, async: true

  alias Tackle.Agents.Default
  alias Tackle.Agents.Definition

  test "default agent modules implement the definition behaviour" do
    definitions = Default.definitions()

    assert Enum.map(definitions, & &1.name) == ["scout", "reviewer", "worker"]
    assert Enum.all?(definitions, &match?(%Definition{source: :builtin}, &1))
    assert Enum.all?(definitions, & &1.advertise)
    assert Enum.all?(definitions, &(not &1.allow_delegation))

    assert Enum.find(definitions, &(&1.name == "scout")).tools == ["read", "bash"]
    assert Enum.find(definitions, &(&1.name == "reviewer")).tools == ["read", "bash"]
    assert Enum.find(definitions, &(&1.name == "worker")).tools == nil
  end
end
