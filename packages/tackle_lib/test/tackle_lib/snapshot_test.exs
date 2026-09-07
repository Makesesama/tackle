defmodule Tackle.Lib.SnapshotTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Snapshot
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Registry

  defmodule SnapshotTestTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "snapshot_test"

    @impl true
    def description, do: "A test tool for snapshot tests."

    @impl true
    def parameters_schema, do: [query: [type: :string, required: true]]

    @impl true
    def execute(_args, _context), do: {:ok, %{ok: true}}
  end

  describe "capture/1" do
    test "captures a snapshot from agent state" do
      state =
        State.new(
          model: "test/model",
          system_prompt: "You are a test agent.",
          tools: [SnapshotTestTool],
          hooks: [],
          llm_opts: [temperature: 0.5],
          context: %{user_id: 1}
        )

      snapshot = Snapshot.capture(state)

      assert snapshot.turn_id =~ state.session_id
      assert snapshot.system_prompt == "You are a test agent."
      assert snapshot.model == "test/model"
      assert snapshot.tools == [SnapshotTestTool]
      assert snapshot.tools_version_id == Snapshot.tools_version_id([SnapshotTestTool])
      assert snapshot.hooks == []
      assert snapshot.llm_opts == [temperature: 0.5]
      refute is_nil(snapshot.captured_at)

      # Tool registry is frozen
      assert %Registry{} = snapshot.tool_registry
      [def] = Registry.definitions(snapshot.tool_registry)
      assert def.name == "snapshot_test"
    end

    test "computes system_prompt_version_id" do
      state = State.new(system_prompt: "You are helpful.")

      snap1 = Snapshot.capture(state)
      snap2 = Snapshot.capture(state)

      assert snap1.system_prompt_version_id == snap2.system_prompt_version_id
      assert is_binary(snap1.system_prompt_version_id)
      assert String.length(snap1.system_prompt_version_id) == 16
    end

    test "system_prompt_version_id is nil when prompt is nil" do
      state = State.new()
      snapshot = Snapshot.capture(state)
      assert snapshot.system_prompt_version_id == nil
    end

    test "different prompts produce different version ids" do
      snap1 = Snapshot.capture(State.new(system_prompt: "Prompt A"))
      snap2 = Snapshot.capture(State.new(system_prompt: "Prompt B"))

      assert snap1.system_prompt_version_id != snap2.system_prompt_version_id
    end

    test "snapshot is isolated from state mutation" do
      state =
        State.new(
          system_prompt: "Original",
          tools: [SnapshotTestTool]
        )

      snapshot = Snapshot.capture(state)

      # Mutate the original state
      _mutated_state = %{state | system_prompt: "Changed", tools: []}

      # Snapshot is unaffected
      assert snapshot.system_prompt == "Original"
      assert snapshot.tools == [SnapshotTestTool]
    end
  end

  describe "system_prompt_version_id/1" do
    test "returns nil for nil" do
      assert Snapshot.system_prompt_version_id(nil) == nil
    end

    test "is deterministic" do
      id1 = Snapshot.system_prompt_version_id("hello")
      id2 = Snapshot.system_prompt_version_id("hello")
      assert id1 == id2
    end

    test "produces 16-char hex string" do
      id = Snapshot.system_prompt_version_id("hello")
      assert is_binary(id)
      assert String.length(id) == 16
    end
  end

  describe "tools_version_id/1" do
    test "is deterministic for same tool list" do
      id1 = Snapshot.tools_version_id([SnapshotTestTool])
      id2 = Snapshot.tools_version_id([SnapshotTestTool])
      assert id1 == id2
    end

    test "changes when tool list changes" do
      id1 = Snapshot.tools_version_id([SnapshotTestTool])
      id2 = Snapshot.tools_version_id([])
      assert id1 != id2
    end
  end

  describe "immutability" do
    test "snapshot struct fields cannot affect the original state" do
      state = State.new(system_prompt: "Original")
      snapshot = Snapshot.capture(state)
      snapshot = %{snapshot | system_prompt: "Hacked"}

      # The original state is unaffected
      assert state.system_prompt == "Original"
      # But the snapshot copy was changed (structs are value types)
      assert snapshot.system_prompt == "Hacked"
    end

    test "tool_registry/1 returns the frozen registry" do
      state = State.new(tools: [SnapshotTestTool])
      snapshot = Snapshot.capture(state)

      registry = Snapshot.tool_registry(snapshot)
      assert %Registry{} = registry
      [def] = Registry.definitions(registry)
      assert def.name == "snapshot_test"
    end

    test "hooks/1 returns the frozen hooks list" do
      defmodule ImmutableTestHook do
        @behaviour Tackle.Lib.Hook

        @impl true
        def after_turn(_state, _context), do: :ok
      end

      state = State.new(hooks: [ImmutableTestHook])
      snapshot = Snapshot.capture(state, hooks: [ImmutableTestHook])

      assert Snapshot.hooks(snapshot) == [ImmutableTestHook]
    end
  end
end
