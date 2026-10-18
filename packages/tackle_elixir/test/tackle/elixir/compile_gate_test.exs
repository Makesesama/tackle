defmodule Tackle.Elixir.CompileGateTest do
  use ExUnit.Case, async: true

  alias Tackle.Elixir.CompileGate
  alias Tackle.Elixir.CompileGate.Settings
  alias Tackle.Elixir.Test.Projects
  alias Tackle.Executor
  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Call

  # Real project nodes through the local executor: about a second to start
  # one per project, then fast compiles.
  @moduletag timeout: 120_000

  @ok "defmodule A do\n  def a, do: :a\nend\n"
  @old_warning "defmodule Old do\n  def f(y), do: :ok\nend\n"

  setup do
    root = Projects.new(%{"lib/a.ex" => @ok, "lib/old.ex" => @old_warning})
    %{root: root, state: State.new(session_id: "session-1")}
  end

  defp context(root, settings \\ []) do
    {:ok, settings} = Settings.new(settings)
    %{cwd: root, executor: Executor.local(), compile_gate: settings}
  end

  defp edit(path, name \\ "edit"), do: %Call{id: "c1", name: name, arguments: %{"path" => path}}

  defp before_edit(state, context, path) do
    case CompileGate.before_tool_call(state, edit(path), context) do
      {:ok, context} -> context
      :ok -> context
    end
  end

  describe "tracking changes" do
    test "ignores other tools and files that cannot change the compile", ctx do
      context = context(ctx.root)

      for call <- [
            edit("README.md"),
            edit("test/a_test.exs"),
            edit("deps/x/lib/x.ex"),
            %Call{id: "c", name: "bash", arguments: %{"command" => "touch lib/a.ex"}},
            %Call{id: "c", name: "edit", arguments: %{}}
          ] do
        assert CompileGate.before_tool_call(ctx.state, call, context) == :ok
      end

      assert CompileGate.before_turn_end(ctx.state, context) == :ok
    end

    test "takes one baseline per project and turn", ctx do
      context = before_edit(ctx.state, context(ctx.root), "lib/a.ex")
      assert %{projects: %{} = projects, rounds: 0} = context.compile_gate_turn
      assert [{root, baseline}] = Map.to_list(projects)
      assert root == ctx.root
      assert %MapSet{} = baseline
      assert MapSet.size(baseline) == 1

      assert ^context = before_edit(ctx.state, context, "lib/b.ex")
    end

    test "does nothing without settings or when disabled", ctx do
      for context <- [
            %{cwd: ctx.root, executor: Executor.local()},
            context(ctx.root, enabled: false)
          ] do
        assert CompileGate.before_tool_call(ctx.state, edit("lib/a.ex"), context) == :ok
        assert CompileGate.before_turn_end(ctx.state, context) == :ok
      end
    end
  end

  describe "checking at the end of the turn" do
    test "passes when the change adds nothing new", ctx do
      context = before_edit(ctx.state, context(ctx.root), "lib/a.ex")
      Projects.write(ctx.root, "lib/a.ex", "defmodule A do\n  def a, do: :changed\nend\n")

      assert CompileGate.before_turn_end(ctx.state, context) == :ok
    end

    test "continues the turn with new errors and warnings", ctx do
      context = before_edit(ctx.state, context(ctx.root), "lib/a.ex")

      # The existing warning moves to another line; it is still not new.
      Projects.write(ctx.root, "lib/old.ex", "\n\n" <> @old_warning)

      Projects.write(ctx.root, "lib/a.ex", """
      defmodule A do
        def a(z), do: :a
        def b, do: missing()
      end
      """)

      assert {:continue, [message], context} = CompileGate.before_turn_end(ctx.state, context)

      assert message =~ "Compile check: `mix compile` reports problems"
      assert message =~ "In the project: 1 new error, 1 new warning"
      assert message =~ "error: undefined function missing/0"
      assert message =~ "└─ lib/a.ex:3:"
      assert message =~ ~s(warning: variable "z" is unused)
      refute message =~ ~s(variable "y")
      refute message =~ "errors have been logged"
      assert :binary.match(message, "error:") < :binary.match(message, "warning:")
      assert context.compile_gate_turn.rounds == 1

      Projects.write(ctx.root, "lib/a.ex", @ok)
      assert CompileGate.before_turn_end(ctx.state, context) == :ok
    end

    test "reports only errors when warnings are off", ctx do
      context = before_edit(ctx.state, context(ctx.root, warnings: false), "lib/a.ex")
      Projects.write(ctx.root, "lib/a.ex", "defmodule A do\n  def a(z), do: :a\nend\n")

      assert CompileGate.before_turn_end(ctx.state, context) == :ok
    end

    test "stops continuing after max_rounds, and max_rounds 0 only checks", ctx do
      broken = "defmodule A do\n  def a, do: missing()\nend\n"

      context = before_edit(ctx.state, context(ctx.root, max_rounds: 1), "lib/a.ex")
      Projects.write(ctx.root, "lib/a.ex", broken)
      assert {:continue, [_message], context} = CompileGate.before_turn_end(ctx.state, context)
      assert CompileGate.before_turn_end(ctx.state, context) == :ok

      Projects.write(ctx.root, "lib/a.ex", @ok)
      context = before_edit(ctx.state, context(ctx.root, max_rounds: 0), "lib/a.ex")
      Projects.write(ctx.root, "lib/a.ex", broken)
      assert CompileGate.before_turn_end(ctx.state, context) == :ok
    end

    test "without a baseline only errors are reported", ctx do
      # The first compile of this module outlasts the gate's timeout, so the
      # baseline is missing; the node finishes it in the background.
      Projects.write(ctx.root, "lib/slow.ex", "defmodule Slow do\n  Process.sleep(1_500)\nend\n")
      context = before_edit(ctx.state, context(ctx.root, timeout_seconds: 0.2), "lib/a.ex")
      assert Map.values(context.compile_gate_turn.projects) == [:unavailable]
      Process.sleep(1_500)

      Projects.write(ctx.root, "lib/a.ex", """
      defmodule A do
        def a(z), do: missing()
      end
      """)

      context = %{context | compile_gate: %{context.compile_gate | timeout_ms: 60_000}}
      assert {:continue, [message], _context} = CompileGate.before_turn_end(ctx.state, context)
      assert message =~ "1 new error"
      refute message =~ "warning:"
    end

    test "skips a check that takes too long", ctx do
      context = before_edit(ctx.state, context(ctx.root), "lib/a.ex")

      Projects.write(ctx.root, "lib/a.ex", """
      defmodule A do
        Process.sleep(1_500)
        def a, do: missing()
      end
      """)

      context = %{context | compile_gate: %{context.compile_gate | timeout_ms: 200}}
      assert CompileGate.before_turn_end(ctx.state, context) == :ok
    end

    test "a cancelled turn stops waiting", ctx do
      signal = Cancellation.new_signal()
      context = ctx.root |> context() |> Map.put(:cancellation_signal, signal)
      context = before_edit(ctx.state, context, "lib/a.ex")

      Projects.write(ctx.root, "lib/a.ex", "defmodule A do\n  def a, do: missing()\nend\n")
      Cancellation.cancel(signal, "stop")
      assert CompileGate.before_turn_end(ctx.state, context) == :ok
    end

    test "a file outside any Mix project is not checked", ctx do
      dir =
        Path.join(System.tmp_dir!(), "tackle-gate-loose-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert CompileGate.before_tool_call(ctx.state, edit("loose.ex"), context(dir)) == :ok
    end
  end

  test "after_turn clears the turn's state", ctx do
    context = before_edit(ctx.state, context(ctx.root), "lib/a.ex")

    assert {:ok, cleared} = CompileGate.after_turn(ctx.state, context)
    refute Map.has_key?(cleared, :compile_gate_turn)
    assert CompileGate.after_turn(ctx.state, cleared) == :ok
  end

  test "logs baselines and checks as JSON lines", ctx do
    log_path = Path.join(ctx.root, "gate-log/gate.jsonl")
    context = before_edit(ctx.state, context(ctx.root, log_path: log_path), "lib/a.ex")

    Projects.write(ctx.root, "lib/a.ex", "defmodule A do\n  def a, do: missing()\nend\n")
    assert {:continue, _messages, context} = CompileGate.before_turn_end(ctx.state, context)
    Projects.write(ctx.root, "lib/a.ex", @ok)
    assert :ok = CompileGate.before_turn_end(ctx.state, context)

    entries =
      log_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [
             %{"event" => "baseline", "outcome" => "ok", "errors" => 0, "warnings" => 1},
             %{"event" => "check", "outcome" => "blocked", "round" => 0, "errors" => 1},
             %{"event" => "check", "outcome" => "passed", "round" => 1, "errors" => 0}
           ] = entries

    for entry <- entries do
      assert entry["session_id"] == "session-1"
      assert entry["project"] == ctx.root
      assert is_integer(entry["duration_ms"])
      assert is_binary(entry["at"])
    end
  end
end
