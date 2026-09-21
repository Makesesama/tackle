defmodule Tackle.CLI.ClipboardTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Clipboard

  test "encodes clipboard content as OSC 52" do
    assert Clipboard.osc52("hello ✓") == "\e]52;c;#{Base.encode64("hello ✓")}\a"
  end
end
