defmodule Tackle.Tools.BashTest do
  alias Tackle.Test.Executors

  use ExUnit.Case, async: true, parameterize: Executors.parameters()

  import Executors, only: [start_executor: 1]

  alias Tackle.Lib.{Cancellation, Event}
  alias Tackle.Tools.Bash

  setup :start_executor

  test "emits correlated output chunks while retaining the canonical result", %{
    executor: executor
  } do
    test_pid = self()

    context = %{
      tool_call_id: "bash-one",
      event_callback: fn event -> send(test_pid, {:event, event}) end
    }

    assert {:ok, "firstsecond"} =
             bash(
               executor,
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

  test "preserves a multibyte character split across port chunks", %{executor: executor} do
    test_pid = self()

    context = %{
      tool_call_id: "utf8",
      event_callback: fn event -> send(test_pid, {:event, event}) end
    }

    assert {:ok, "€"} =
             bash(
               executor,
               %{"command" => "printf '\\342\\202'; sleep 0.05; printf '\\254'"},
               context
             )

    assert collect_progress([]) |> Enum.map_join(& &1.data.delta) == "€"
  end

  test "spools large multi-line output without losing the tail or line counts", %{
    executor: executor
  } do
    command = "for i in {1..3000}; do printf 'line %s\\n' \"$i\"; done"
    assert {:ok, output} = bash(executor, %{"command" => command}, %{})
    assert [_, path] = Regex.run(~r/Full output: ([^\]]+)\]\z/, output)
    on_exit(fn -> File.rm(path) end)

    assert output =~ "[Showing lines 1001-3000 of 3000. Full output: "
    assert String.starts_with?(output, "line 1001\n")
    assert File.read!(path) =~ "line 1\nline 2\n"
    assert String.ends_with?(File.read!(path), "line 3000\n")
  end

  test "spools sanitized UTF-8 across chunk boundaries", %{executor: executor} do
    command = "printf '\\342\\202'; sleep 0.05; printf '\\254'; printf 'x%.0s' {1..52000}"
    assert {:ok, output} = bash(executor, %{"command" => command}, %{})
    assert [_, path] = Regex.run(~r/Full output: ([^\]]+)\]\z/, output)
    on_exit(fn -> File.rm(path) end)
    assert File.read!(path) == "€" <> String.duplicate("x", 52_000)
  end

  test "checks the deadline after receiving output, without an unbounded subprocess", %{
    executor: executor
  } do
    # Output arrives well before the deadline; the slow callback then outlasts it.
    assert {:error, "output\n\nCommand timed out"} =
             bash(
               executor,
               %{"command" => "printf output; sleep 5", "timeout" => 0.5},
               %{event_callback: fn _event -> Process.sleep(600) end}
             )
  end

  test "preserves a valid character following invalid bytes across chunks", %{executor: executor} do
    assert {:ok, "�€"} =
             bash(
               executor,
               %{"command" => "printf '\\377\\342\\202'; sleep 0.05; printf '\\254'"},
               %{}
             )
  end

  test "retains the valid tail of an oversized line ending in a newline", %{executor: executor} do
    assert {:ok, output} =
             bash(executor, %{"command" => "printf 'x%.0s' {1..205000}; printf '\\n'"}, %{})

    assert String.starts_with?(output, String.duplicate("x", 100))
    assert output =~ "[Showing lines 1-1 of 1. Full output: "
    assert [_, path] = Regex.run(~r/Full output: ([^\]]+)\]\z/, output)
    on_exit(fn -> File.rm(path) end)
    assert File.read!(path) == String.duplicate("x", 205_000) <> "\n"
  end

  test "cancellation retains partial output and its full-output log", %{executor: executor} do
    signal = Cancellation.new_signal()
    on_exit(fn -> Cancellation.delete(signal) end)
    parent = self()

    task =
      Task.async(fn ->
        bash(
          executor,
          %{"command" => "printf 'x%.0s' {1..60000}; printf ready; sleep 5"},
          %{
            cancellation_signal: signal,
            event_callback: fn event ->
              if event.data.delta =~ "ready", do: send(parent, :ready)
            end
          }
        )
      end)

    assert_receive :ready, 2_000
    assert :ok = Cancellation.cancel(signal, :test)
    assert {:error, output} = Task.await(task, 2_000)
    assert String.ends_with?(output, "Command aborted")
    assert [_, path] = Regex.run(~r/Full output: ([^\]]+)\]/, output)
    on_exit(fn -> File.rm(path) end)
    assert File.read!(path) == String.duplicate("x", 60_000) <> "ready"
  end

  test "callback failures after spilling clean up the command file", %{executor: executor} do
    parent = self()

    context = %{
      event_callback: fn event ->
        if event.data.delta =~ "marker" do
          paths = Path.wildcard(Path.join(System.tmp_dir!(), "tackle-bash-*.log"))

          path =
            Enum.find(paths, fn path ->
              case File.read(path) do
                {:ok, data} -> String.starts_with?(data, "callback-cleanup-")
                _ -> false
              end
            end)

          send(parent, {:spill, path})
          raise "callback failed"
        end
      end
    }

    assert_raise RuntimeError, "callback failed", fn ->
      bash(
        executor,
        %{
          "command" =>
            "printf callback-cleanup-; printf 'x%.0s' {1..60000}; sleep 0.05; printf marker"
        },
        context
      )
    end

    assert_receive {:spill, path} when is_binary(path)
    refute File.exists?(path)
  end

  test "runs a non-login shell without an event callback", %{executor: executor} do
    assert {:ok, "quiet"} =
             bash(executor, %{"command" => "shopt -q login_shell && exit 1; printf quiet"}, %{})
  end

  defp bash(executor, args, context), do: Bash.run(args, Map.put(context, :executor, executor))

  defp collect_progress(events) do
    receive do
      {:event, %Event{type: :tool_progress} = event} -> collect_progress([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
