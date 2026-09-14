defmodule Tackle.CLI.InteractionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Tackle.CLI.Interaction
  alias Tackle.CLI.Output

  test "non-interactive progress runs without spinner output" do
    output = Output.new(format: :human, color: :never)
    refute output.interactive?

    captured =
      capture_io(fn ->
        assert {:ok, :done} ==
                 Interaction.progress(output, [label: "Waiting..."], fn -> {:ok, :done} end)
      end)

    assert captured == ""
  end
end
