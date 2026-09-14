defmodule Tackle.Runtime.MessagingTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.Limits

  test "in-scope messages queue while a child is busy and join its next turn" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        limits: Limits.new!(max_concurrent_turns: 3, max_agents_per_fleet: 3),
        profiles: %{
          "worker" =>
            agent_spec("worker",
              allow_delegation: true,
              mode: :manual,
              content: "first"
            )
        }
      )

    {:ok, child} =
      Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "start",
        retention: :until_collected,
        owner: :parent
      )

    assert_receive {:adapter_called, child_task, "echo", _opts}, 2_000
    assert :ok = Tackle.Runtime.tell(scope.root_agent_ref, child.agent_ref, "new facts")
    assert [%{from: from, message: "new facts"}] = inbox(child.agent_ref)
    assert from == scope.root_agent_ref

    send(child_task, {:respond, "first"})

    assert_eventually(fn ->
      Tackle.Runtime.session_pid(child.agent_ref) == {:error, :not_found}
    end)
  end

  test "messages reject cross-scope routing and bound a recipient inbox" do
    first = start_scope()
    second = start_scope()

    assert {:error, :scope_mismatch} =
             Tackle.Runtime.tell(first.root_agent_ref, second.root_agent_ref, "nope")

    for i <- 1..32 do
      assert :ok = Tackle.Runtime.tell(first.root_agent_ref, first.root_agent_ref, "message #{i}")
    end

    assert {:error, :inbox_full} =
             Tackle.Runtime.tell(first.root_agent_ref, first.root_agent_ref, "overflow")
  end

  defp inbox(agent_ref) do
    {:ok, session} = Tackle.Runtime.session_pid(agent_ref)
    Tackle.Session.inbox(session)
  end

  defp assert_eventually(fun), do: assert(:ok = eventually(fun))
end
