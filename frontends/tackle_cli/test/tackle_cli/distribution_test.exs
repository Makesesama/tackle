defmodule Tackle.CLI.DistributionTest do
  use ExUnit.Case, async: false

  alias Tackle.CLI.Distribution

  setup do
    previous_adapters = Application.get_env(:tackle, :adapters)

    on_exit(fn ->
      if is_nil(previous_adapters) do
        Application.delete_env(:tackle, :adapters)
      else
        Application.put_env(:tackle, :adapters, previous_adapters)
      end
    end)

    :ok
  end

  test "bundles Codex and DeepSeek as the default adapters" do
    assert Distribution.default_adapters() == [
             Tackle.Plugins.Codex,
             Tackle.Plugins.DeepSeek
           ]
  end

  test "registers both bundled adapters with the harness" do
    Application.delete_env(:tackle, :adapters)

    assert :ok = Distribution.configure()

    assert Application.fetch_env!(:tackle, :adapters) == [
             Tackle.Plugins.Codex,
             Tackle.Plugins.DeepSeek
           ]
  end
end
