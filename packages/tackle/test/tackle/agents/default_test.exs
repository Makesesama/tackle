defmodule Tackle.Agents.DefaultTest do
  use ExUnit.Case, async: true

  alias Tackle.Agents.Default
  alias Tackle.Agents.Definition

  test "ships scout, reviewer, worker, and the review stages as built-in definitions" do
    definitions = Default.definitions()

    assert Enum.map(definitions, & &1.name) ==
             ["scout", "reviewer", "worker", "review-detector", "review-verifier"]

    assert Enum.all?(definitions, &match?(%Definition{source: :builtin}, &1))
    assert Enum.all?(definitions, &(not &1.allow_delegation))

    {review, general} = Enum.split_with(definitions, &String.starts_with?(&1.name, "review-"))
    assert Enum.all?(general, & &1.advertise)
    assert Enum.all?(general, &(&1.max_iterations == :infinity))

    assert Enum.find(definitions, &(&1.name == "scout")).tools == ["read", "bash"]
    assert Enum.find(definitions, &(&1.name == "reviewer")).tools == ["read", "bash"]
    assert Enum.find(definitions, &(&1.name == "worker")).tools == nil

    # The review stages run only through Tackle.Review, with bounded loops.
    refute Enum.any?(review, & &1.advertise)
    assert Enum.all?(review, &is_integer(&1.max_iterations))

    assert Enum.find(review, &(&1.name == "review-detector")).tools ==
             ["read", "bash", "report_findings"]

    assert Enum.find(review, &(&1.name == "review-verifier")).tools ==
             ["read", "bash", "report_verdict"]
  end
end
