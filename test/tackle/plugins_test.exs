defmodule Tackle.PluginsTest do
  use ExUnit.Case, async: false

  defmodule Adapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "plugged"

    @impl true
    def models, do: ["small", "large"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  setup do
    previous = Application.get_env(:tackle, :adapters)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:tackle, :adapters)
        value -> Application.put_env(:tackle, :adapters, value)
      end
    end)

    :ok
  end

  test "loads available adapters from root harness configuration" do
    Application.put_env(:tackle, :adapters, [Adapter])

    assert {:ok, [Adapter]} = Tackle.Plugins.available_adapters()
    assert {:ok, ["plugged/small", "plugged/large"]} = Tackle.available_models()
  end

  test "configuration loading uses root adapters while overrides only select the model" do
    Application.put_env(:tackle, :adapters, [Adapter])

    assert {:ok, config} = Tackle.load_config(overrides: [model: "plugged/small"], env: %{})
    assert config.adapters == [Adapter]
    assert config.model_ref == "plugged/small"
  end

  test "returns an explicit error when no adapters are configured" do
    Application.put_env(:tackle, :adapters, [])

    assert {:error, :no_adapters_configured} = Tackle.Plugins.available_adapters()

    assert {:error, :no_adapters_configured} =
             Tackle.load_config(overrides: [model: "none/test"], env: %{})
  end
end
