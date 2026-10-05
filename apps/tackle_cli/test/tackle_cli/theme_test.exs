defmodule Tackle.CLI.TUI.ThemeTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.Theme

  test "explicit palettes override detection" do
    assert Theme.resolve("light", "15;0") == :light
    assert Theme.resolve("dark", "0;15") == :dark
  end

  test "auto uses the final COLORFGBG background, including 256-color indices" do
    for override <- [nil, "auto", "unknown"] do
      for value <- ["0;15", "0;default;7", "0;255", "0;231"] do
        assert Theme.resolve(override, value) == :light
      end

      for value <- [
            nil,
            "",
            "garbage",
            "0;",
            "0;256",
            "0;-1",
            "0;15junk",
            "15;0",
            "15;8",
            "15;232",
            "15;16",
            "15;21"
          ] do
        assert Theme.resolve(override, value) == :dark
      end
    end
  end

  test "every painted surface supplies foreground and background in both palettes" do
    for mode <- [:light, :dark],
        tone <- [
          :surface,
          :surface_raised,
          :user_surface,
          :code_surface,
          :selection_surface,
          :error_surface,
          :diff_add_inline,
          :diff_del_inline
        ] do
      style = Theme.style(tone, mode)
      assert style.fg != nil
      assert style.bg != nil
      refute style.fg == style.bg
    end

    assert Theme.style(:text, :light) == %ExRatatui.Style{}
    assert Theme.style(:unknown, :light) == %ExRatatui.Style{}
    assert Theme.code_theme(:light) == :base16_ocean_light
    assert Theme.code_theme(:dark) == :base16_ocean_dark
  end

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
