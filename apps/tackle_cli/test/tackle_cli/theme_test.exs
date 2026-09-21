defmodule Tackle.CLI.TUI.ThemeTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.Theme

  test "overlays share a neutral border while warning titles remain distinct" do
    menu = Theme.panel_block(" Model ", :cyan)
    confirm = Theme.panel_block(" Confirm quit ", :yellow)

    assert menu.borders == [:all]
    assert menu.border_type == :rounded
    assert menu.border_style == Theme.style(:subtle)
    assert confirm.border_style == menu.border_style
    assert menu.title_style == Theme.style(:accent_soft)
    assert confirm.title_style == Theme.style(:warning)
    refute confirm.title_style == menu.title_style
  end
end
