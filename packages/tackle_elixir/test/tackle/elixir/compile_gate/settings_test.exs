defmodule Tackle.Elixir.CompileGate.SettingsTest do
  use ExUnit.Case, async: true

  alias Tackle.Elixir.CompileGate.Settings

  test "nil gives the defaults" do
    assert {:ok,
            %Settings{
              enabled: true,
              max_rounds: 2,
              timeout_ms: 120_000,
              warnings: true,
              log_path: nil
            }} = Settings.new(nil)
  end

  test "false or enabled: false turns the gate off" do
    assert {:ok, nil} = Settings.new(false)
    assert {:ok, nil} = Settings.new(enabled: false)
    assert {:ok, nil} = Settings.new(%Settings{enabled: false})
  end

  test "accepts every option" do
    assert {:ok, settings} =
             Settings.new(
               max_rounds: 0,
               timeout_seconds: 1.5,
               warnings: false,
               log_path: "/tmp/gate.jsonl"
             )

    assert settings.max_rounds == 0
    assert settings.timeout_ms == 1_500
    refute settings.warnings
    assert settings.log_path == "/tmp/gate.jsonl"
  end

  test "rejects invalid values and unknown keys" do
    for opts <- [
          [max_rounds: -1],
          [max_rounds: 1.5],
          [timeout_seconds: 0],
          [timeout_seconds: "60"],
          [warnings: "yes"],
          [enabled: nil],
          [log_path: ""],
          [colour: true],
          [:not_keyword]
        ] do
      assert {:error, {:invalid_option, :compile_gate, _detail}} = Settings.new(opts),
             inspect(opts)
    end

    assert {:error, {:invalid_option, :compile_gate, "yes"}} = Settings.new("yes")
  end
end
