defmodule Tackle.CLI.TUI.TerminalBackgroundTest do
  @moduledoc """
  Unit coverage for the OSC 11 reply parsing and the palette precedence.

  The query itself needs a controlling terminal, so it is only exercised by
  the pinned-theme short-circuit here; the reply classifier and the
  `Theme` precedence are pure and fully covered.
  """

  use ExUnit.Case, async: false

  alias Tackle.CLI.TUI.{TerminalBackground, Theme}

  test "classify/1 reads rgb and rgba replies with either terminator" do
    assert TerminalBackground.classify("\e]11;rgb:ffff/ffff/ffff\e\\") == :light
    assert TerminalBackground.classify("\e]11;rgb:0000/0000/0000\a") == :dark
    assert TerminalBackground.classify("\e]11;rgba:2b2b/2b2b/2b2b/ffff\e\\") == :dark
    assert TerminalBackground.classify("\e]11;rgb:fa/f6/e3\e\\") == :light
    # Other terminal reports may precede the reply.
    assert TerminalBackground.classify("\e[?1;2c\e]11;rgb:28/28/28\a") == :dark
  end

  test "classify/1 rejects incomplete or unrelated replies" do
    assert TerminalBackground.classify("") == nil
    assert TerminalBackground.classify("\e]11;rgb:ffff/ffff") == nil
    assert TerminalBackground.classify("hello") == nil
    assert TerminalBackground.classify("\e]10;rgb:ffff/ffff/ffff\e\\") == nil
  end

  test "detect/0 skips the query when the palette is pinned" do
    previous = System.get_env("TACKLE_THEME")
    System.put_env("TACKLE_THEME", "light")
    on_exit(fn -> restore("TACKLE_THEME", previous) end)

    assert TerminalBackground.detect() == :unknown
  end

  test "a remembered background feeds Theme.mode/0 behind the override" do
    previous = System.get_env("TACKLE_THEME")
    System.put_env("TACKLE_THEME", "")

    on_exit(fn ->
      restore("TACKLE_THEME", previous)
      :persistent_term.erase({Theme, :background})
    end)

    :ok = Theme.remember_background(:light)
    assert Theme.mode() == :light

    :ok = Theme.remember_background(:dark)
    assert Theme.mode() == :dark
  end

  defp restore(_key, nil), do: System.delete_env("TACKLE_THEME")
  defp restore(_key, value), do: System.put_env("TACKLE_THEME", value)
end
