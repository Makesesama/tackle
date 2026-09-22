defmodule Tackle.Tools.BashTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Event
  alias Tackle.Tools.Bash

  test "emits correlated output chunks while retaining the canonical result" do
    test_pid = self()

    context = %{
      tool_call_id: "bash-one",
      event_callback: fn event -> send(test_pid, {:event, event}) end
    }

    assert {:ok, "firstsecond"} =
             Bash.run(
               %{"command" => "printf first; sleep 0.05; printf second"},
               context
             )

    events = collect_progress([])
    assert events != []

    assert Enum.all?(events, fn event ->
             match?(
               %Event{
                 type: :tool_progress,
                 data: %{tool_call_id: "bash-one", name: "bash", delta: delta}
               }
               when is_binary(delta),
               event
             )
           end)

    assert Enum.map_join(events, & &1.data.delta) == "firstsecond"
  end

  test "preserves a multibyte character split across port chunks" do
    test_pid = self()

    context = %{
      tool_call_id: "utf8",
      event_callback: fn event -> send(test_pid, {:event, event}) end
    }

    assert {:ok, "€"} =
             Bash.run(
               %{"command" => "printf '\\342\\202'; sleep 0.05; printf '\\254'"},
               context
             )

    assert collect_progress([]) |> Enum.map_join(& &1.data.delta) == "€"
  end

  test "runs a non-login shell without an event callback" do
    assert {:ok, "quiet"} =
             Bash.run(%{"command" => "shopt -q login_shell && exit 1; printf quiet"}, %{})
  end

  defp collect_progress(events) do
    receive do
      {:event, %Event{type: :tool_progress} = event} -> collect_progress([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
