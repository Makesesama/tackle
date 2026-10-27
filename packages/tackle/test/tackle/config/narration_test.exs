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
  end

  test "rejects unknown options and invalid shapes" do
    assert {:error, {:invalid_option, :narration, [:threshold]}} =
             Narration.new([model: "local/small", threshold: 1], [Adapter])

    assert {:error, {:invalid_option, :narration, "on"}} = Narration.new("on", [Adapter])
    assert {:error, {:invalid_option, :narration, [1]}} = Narration.new([1], [Adapter])

    assert {:error, {:invalid_option, :narration, interval_seconds: -1}} =
             Narration.new([model: "local/small", interval_seconds: -1], [Adapter])
  end

  test "every interval fits the longest Erlang timer" do
    for key <- [:interval_seconds, :first_after_seconds],
        seconds <- [1.0e308, 4_294_968, 4_294_967.296] do
      assert {:error, {:invalid_option, :narration, [{^key, ^seconds}]}} =
               Narration.new([{:model, "local/small"}, {key, seconds}], [Adapter])
    end

    assert {:ok, config} =
             Narration.new(
               [
                 model: "local/small",
                 interval_seconds: 4_294_967.295,
                 first_after_seconds: 0.001
               ],
               [Adapter]
             )

    assert Narration.interval_ms(config) == 4_294_967_295
    assert Narration.first_after_ms(config) == 1
    assert is_reference(Process.send_after(self(), :never, Narration.interval_ms(config)))
  end
end
