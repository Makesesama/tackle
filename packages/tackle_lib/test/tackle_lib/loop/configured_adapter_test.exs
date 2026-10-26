defmodule Tackle.Lib.Loop.ConfiguredAdapterTest do
  # A state without an LLM selection uses the application's configured
  # adapter (`config :tackle_lib, llm: Adapter`). These tests change that
  # global configuration, so they cannot run concurrently with others; every
  # other loop test selects its adapter per state.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Loop
  alias Tackle.Lib.State

  defmodule ReplacementAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :replacement_adapter_called)
      {:ok, %{data: %{"content" => "replacement"}, usage: nil, model: "replacement"}}
    end
  end

  defmodule SnapshotAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :snapshot_adapter_called)
      {:ok, %{data: %{"content" => "snapshot"}, usage: nil, model: "snapshot"}}
    end
  end

  defmodule SwapAdapterConfigHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def before_prompt(_state, context) do
      Application.put_env(:tackle_lib, :llm, ReplacementAdapter)
      send(Map.fetch!(context, :test_pid), :adapter_config_swapped)
      :ok
    end
  end

  setup do
    previous_llm = Application.get_env(:tackle_lib, :llm)

    on_exit(fn ->
      if previous_llm do
        Application.put_env(:tackle_lib, :llm, previous_llm)
      else
        Application.delete_env(:tackle_lib, :llm)
      end
    end)
  end

  test "snapshot freezes the LLM adapter for the turn" do
    Application.put_env(:tackle_lib, :llm, SnapshotAdapter)
    Process.put(:test_pid, self())

    state =
      State.new(
        model: "test/model",
        hooks: [SwapAdapterConfigHook],
        context: %{test_pid: self()}
      )

    assert {:ok, state} = Loop.run(state, "test snapshot adapter")
    assert state.status == :completed

    assert_receive :adapter_config_swapped
    assert_receive :snapshot_adapter_called
    refute_receive :replacement_adapter_called, 20
  end
end
