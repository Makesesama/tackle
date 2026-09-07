defmodule Tackle.HookTest do
  use ExUnit.Case, async: false

  alias Tackle.Hook
  alias Tackle.State

  defmodule ObserverHook do
    @behaviour Tackle.Hook

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
    @behaviour Tackle.Hook

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
    @behaviour Tackle.Hook

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
        @behaviour Tackle.Hook

        @impl true
        def before_prompt(_state, _context), do: "unexpected"
      end

      state = State.new()

      assert {:error, error} = Hook.invoke([BadReturnHook], :before_prompt, [state], %{})
      assert error =~ "returned unexpected value"
    end
  end

  describe "Hook callbacks" do
    test "all callbacks are optional" do
      defmodule MinimalHook do
        @behaviour Tackle.Hook

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
