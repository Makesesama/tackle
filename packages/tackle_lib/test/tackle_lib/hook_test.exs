defmodule Tackle.Lib.HookTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Hook
  alias Tackle.Lib.State

  defmodule ObserverHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def before_prompt(_state, context) do
      send(Process.get(:test_pid), {:hook, :before_prompt, context})
      :ok
    end

    @impl true
    def after_prompt(_state, _response, _context) do
      send(Process.get(:test_pid), {:hook, :after_prompt})
      :ok
    end

    @impl true
    def before_tool_call(_state, _call, _context) do
      send(Process.get(:test_pid), {:hook, :before_tool_call})
      :ok
    end

    @impl true
    def after_tool_call(_state, _result, _context) do
      send(Process.get(:test_pid), {:hook, :after_tool_call})
      :ok
    end

    @impl true
    def after_turn(_state, _context) do
      send(Process.get(:test_pid), {:hook, :after_turn})
      :ok
    end
  end

  defmodule MutatorHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def before_prompt(_state, context) do
      {:ok, Map.put(context, :mutated_by, :before_prompt)}
    end

    @impl true
    def after_tool_call(_state, _result, context) do
      count = Map.get(context, :tool_call_count, 0)
      {:ok, Map.put(context, :tool_call_count, count + 1)}
    end
  end

  defmodule AbortingHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def before_prompt(_state, _context) do
      {:error, "access denied"}
    end
  end

  describe "Hook.invoke/4" do
    test "invokes observer hook and returns unchanged context" do
      Process.put(:test_pid, self())

      state = State.new()
      context = %{user_id: 1}

      assert {:ok, ^context} = Hook.invoke([ObserverHook], :before_prompt, [state], context)

      assert_receive {:hook, :before_prompt, ^context}
    end

    test "invokes mutator hook and returns updated context" do
      state = State.new()
      context = %{user_id: 1}

      assert {:ok, updated} = Hook.invoke([MutatorHook], :before_prompt, [state], context)
      assert updated.mutated_by == :before_prompt
      assert updated.user_id == 1
    end

    test "stops on abort and returns error" do
      state = State.new()

      assert {:error, "access denied"} =
               Hook.invoke([AbortingHook], :before_prompt, [state], %{})
    end

    test "invokes multiple hooks in order, chaining context mutations" do
      state = State.new()

      assert {:ok, context} =
               Hook.invoke([MutatorHook, MutatorHook], :before_prompt, [state], %{})

      # Second hook overwrites the same key
      assert context.mutated_by == :before_prompt
    end

    test "skips hooks that do not implement the event" do
      Process.put(:test_pid, self())

      state = State.new()

      assert {:ok, %{}} = Hook.invoke([ObserverHook], :after_turn, [state], %{})
      assert_receive {:hook, :after_turn}

      # ObserverHook does not implement a non-existent event; invoke should skip silently
      assert {:ok, %{}} = Hook.invoke([ObserverHook], :nonexistent_event, [state], %{})
      refute_receive {:hook, :nonexistent_event}
    end

    test "handles empty hooks list" do
      state = State.new()
      assert {:ok, %{}} = Hook.invoke([], :before_prompt, [state], %{})
    end

    test "returns error for unexpected return value" do
      defmodule BadReturnHook do
        @behaviour Tackle.Lib.Hook

        @impl true
        def before_prompt(_state, _context), do: "unexpected"
      end

      state = State.new()

      assert {:error, error} = Hook.invoke([BadReturnHook], :before_prompt, [state], %{})
      assert error =~ "returned unexpected value"
    end
  end

  describe "Hook.invoke_before_turn_end/3" do
    defmodule ContinueHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_turn_end(_state, context) do
        rounds = Map.get(context, :rounds, 0) + 1
        {:continue, ["round #{rounds}"], Map.put(context, :rounds, rounds)}
      end
    end

    defmodule ResultHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_turn_end(_state, context) do
        send(Process.get(:test_pid), {:result_hook, context})
        Map.fetch!(context, :result)
      end
    end

    test "returns the context and no messages without hooks or implementations" do
      state = State.new()

      assert {:ok, %{a: 1}, []} = Hook.invoke_before_turn_end([], state, %{a: 1})
      assert {:ok, %{a: 1}, []} = Hook.invoke_before_turn_end([MutatorHook], state, %{a: 1})
    end

    test "accepts observer, mutator, and empty continue results" do
      Process.put(:test_pid, self())
      state = State.new()

      assert {:ok, %{result: :ok}, []} =
               Hook.invoke_before_turn_end([ResultHook], state, %{result: :ok})

      assert {:ok, %{changed: true}, []} =
               Hook.invoke_before_turn_end([ResultHook], state, %{result: {:ok, %{changed: true}}})

      assert {:ok, %{result: {:continue, []}}, []} =
               Hook.invoke_before_turn_end([ResultHook], state, %{result: {:continue, []}})
    end

    test "collects messages in hook order and threads the context" do
      state = State.new()

      assert {:ok, %{rounds: 2}, ["round 1", "round 2"]} =
               Hook.invoke_before_turn_end([ContinueHook, ContinueHook], state, %{})
    end

    test "stops at an error without running later hooks" do
      Process.put(:test_pid, self())
      state = State.new()

      assert {:error, :failed} =
               Hook.invoke_before_turn_end(
                 [ResultHook, ContinueHook],
                 state,
                 %{result: {:error, :failed}}
               )

      assert_receive {:result_hook, %{result: {:error, :failed}}}

      assert {:error, :failed} =
               Hook.invoke_before_turn_end([ContinueHook, ResultHook, ResultHook], state, %{
                 result: {:error, :failed}
               })

      assert_receive {:result_hook, %{rounds: 1}}
      refute_receive {:result_hook, _}, 20
    end

    test "rejects invalid messages and unexpected values" do
      Process.put(:test_pid, self())
      state = State.new()

      for messages <- [[""], [:atom], "not a list"] do
        assert {:error, error} =
                 Hook.invoke_before_turn_end([ResultHook], state, %{
                   result: {:continue, messages}
                 })

        assert error =~ "returned invalid messages"
      end

      for result <- ["unexpected", {:continue, ["ok"], :not_a_map}, {:ok, :not_a_map}] do
        assert {:error, error} =
                 Hook.invoke_before_turn_end([ResultHook], state, %{result: result})

        assert error =~ "before_turn_end/2 returned unexpected value"
      end
    end
  end

  describe "Hook callbacks" do
    test "a hook module that is not loaded yet still runs" do
      module = Tackle.Lib.HookTest.NotYetLoadedHook
      tmp_dir = Path.join(System.tmp_dir!(), "tackle-hook-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      [{^module, binary}] =
        Code.compile_string("""
        defmodule #{inspect(module)} do
          @behaviour Tackle.Lib.Hook
          def before_prompt(_state, context), do: {:ok, Map.put(context, :ran, true)}
          def before_turn_end(_state, context), do: {:continue, ["checked"], context}
        end
        """)

      File.write!(Path.join(tmp_dir, "#{module}.beam"), binary)
      Code.prepend_path(tmp_dir)

      on_exit(fn ->
        Code.delete_path(tmp_dir)
        :code.purge(module)
        :code.delete(module)
        File.rm_rf!(tmp_dir)
      end)

      unload = fn ->
        :code.purge(module)
        :code.delete(module)
        refute :code.is_loaded(module)
      end

      state = State.new()

      unload.()
      assert {:ok, %{ran: true}} = Hook.invoke([module], :before_prompt, [state], %{})

      unload.()
      assert {:ok, %{}, ["checked"]} = Hook.invoke_before_turn_end([module], state, %{})
    end

    test "all callbacks are optional" do
      defmodule MinimalHook do
        @behaviour Tackle.Lib.Hook

        @impl true
        def after_turn(_state, _context), do: :ok
      end

      state = State.new()

      # Only after_turn is implemented; others should be skipped
      assert {:ok, %{}} = Hook.invoke([MinimalHook], :after_turn, [state], %{})
      assert {:ok, %{}} = Hook.invoke([MinimalHook], :before_prompt, [state], %{})
    end
  end
end
