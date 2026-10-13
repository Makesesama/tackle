defmodule Tackle.Config.NarrationTest do
  use ExUnit.Case, async: true

  alias Tackle.Config.Narration

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "local"

    @impl true
    def models, do: ["small"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  test "is off unless configured" do
    assert {:ok, nil} = Narration.new(nil, [Adapter])
    assert {:ok, nil} = Narration.new(false, [Adapter])
    assert {:ok, nil} = Narration.new([model: "local/small", enabled: false], [Adapter])
  end

  test "resolves the chat model and applies defaults" do
    assert {:ok, %Narration{} = config} = Narration.new([model: "local/small"], [Adapter])
    assert config.model_ref == "local/small"
    assert config.selection.adapter == Adapter
    assert config.interval_seconds == 5
    assert config.first_after_seconds == 5

    # A validated config round-trips, for example through Config.new/1.
    assert {:ok, ^config} = Narration.new(config, [Adapter])
  end

  test "rejects unknown options and invalid shapes" do
    assert {:error, {:invalid_option, :narration, [:threshold]}} =
             Narration.new([model: "local/small", threshold: 1], [Adapter])

    assert {:error, {:invalid_option, :narration, "on"}} = Narration.new("on", [Adapter])
    assert {:error, {:invalid_option, :narration, [1]}} = Narration.new([1], [Adapter])

    assert {:error, {:invalid_option, :narration, interval_seconds: -1}} =
             Narration.new([model: "local/small", interval_seconds: -1], [Adapter])
  end
end
